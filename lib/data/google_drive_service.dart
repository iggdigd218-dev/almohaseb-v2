import 'dart:convert';
import 'dart:io' as io;

import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import 'sync/google_auth_service.dart' show createUnifiedGoogleSignIn;

/// معلومات تعريفية للحساب المرتبط فقط.
class GoogleAccountInfo {
  final String id;
  final String email;
  final String? displayName;
  final String? photoUrl;

  const GoogleAccountInfo({
    required this.id,
    required this.email,
    this.displayName,
    this.photoUrl,
  });
}

/// بيانات نسخة محفوظة في Drive.
class GoogleDriveBackupInfo {
  final String id;
  final String name;
  final DateTime? modifiedTime;
  final int? sizeBytes;

  const GoogleDriveBackupInfo({
    this.id = '',
    required this.name,
    this.modifiedTime,
    this.sizeBytes,
  });

  String get sizeLabel {
    final size = sizeBytes;
    if (size == null || size <= 0) return '';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)} KB';
    }
    return '${(size / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

class GoogleDriveException implements Exception {
  final String message;
  const GoogleDriveException(this.message);

  @override
  String toString() => message;
}

class GoogleDriveBackupNotFoundException extends GoogleDriveException {
  const GoogleDriveBackupNotFoundException()
      : super('لا توجد نسخة احتياطية لتطبيق المحاسب في حساب Google المرتبط.');
}

class _DriveFile {
  final String id;
  final String name;
  final DateTime? modifiedTime;
  final int? sizeBytes;

  const _DriveFile({
    required this.id,
    required this.name,
    this.modifiedTime,
    this.sizeBytes,
  });

  GoogleDriveBackupInfo toPublicInfo() => GoogleDriveBackupInfo(
        id: id,
        name: name,
        modifiedTime: modifiedTime,
        sizeBytes: sizeBytes,
      );
}

/// عميل Google Sign-In و Google Drive.
class GoogleDriveService {
  GoogleDriveService._();
  static final GoogleDriveService instance = GoogleDriveService._();

  static const String backupFileName = 'nexora-backup-latest.nexora';
  static const List<String> appBackupPrefixes = <String>[
    'MyAccounts_',
    'nexora-',
    'Nexora_',
    'backup_',
  ];
  static const String _driveHost = 'www.googleapis.com';
  static const String _driveBasePath = '/drive/v3';
  static const String _uploadBasePath = '/upload/drive/v3';
  static const String _mimeType = 'application/octet-stream';
  static const String _fileFields =
      'id,name,mimeType,modifiedTime,size,appProperties';

  /// خطافات اختبارية لواجهة استعراض النسخ (Drive Backup Picker).
  Future<List<GoogleDriveBackupInfo>> Function()? debugListBackupsOverride;
  Future<io.File> Function(
    String fileId,
    io.File target,
  )? debugDownloadBackupByIdOverride;

  /// التحقق مما إذا كان اسم الملف يطابق بادئة نسخ التطبيق.
  static bool matchesAppBackupPrefix(String fileName) {
    final trimmed = fileName.trim();
    if (trimmed.isEmpty) return false;
    final lower = trimmed.toLowerCase();
    if (lower.endsWith('.nexora')) return true;
    for (final prefix in appBackupPrefixes) {
      if (lower.startsWith(prefix.toLowerCase())) return true;
    }
    return false;
  }

  /// توليد اسم نسخة احتياطية قياسي لـ Google Drive مع التاريخ والوقت بدقة:
  /// مثل: `MyAccounts_Auto_V2_11-Oct-2026 07:38:25.nexora`
  static String formatDriveBackupFileName({
    bool auto = false,
    DateTime? timestamp,
  }) {
    final dt = (timestamp ?? DateTime.now()).toLocal();
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    String two(int n) => n.toString().padLeft(2, '0');
    final day = two(dt.day);
    final mon = months[(dt.month - 1).clamp(0, 11)];
    final year = dt.year;
    final time = '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
    final kind = auto ? 'Auto' : 'Backup';
    return 'MyAccounts_${kind}_V2_$day-$mon-$year $time.nexora';
  }

  // (SSO) لا مثال GoogleSignIn خاص بهذه الخدمة ولا معرّف عميل منفصل:
  // تستخدم المثال الموحّد الوحيد في التطبيق، فتُمنح صلاحية النسخ
  // (drive.appdata) ضمن تسجيل الدخول الأساسي نفسه — تسجيل واحد
  // يفعّل المزامنة والنسخ الاحتياطي معاً.
  GoogleSignIn? _signInCached;
  bool _signInResolved = false;
  GoogleSignIn? get _signIn {
    if (_signInResolved) return _signInCached;
    _signInResolved = true;
    return _signInCached = createUnifiedGoogleSignIn(forDrive: true);
  }

  /// يستعيد جلسة Google السابقة بصمت إن كانت موجودة.
  Future<GoogleAccountInfo?> restoreSession() async {
    try {
      final signIn = _signIn;
      if (signIn == null) return null;
      final account = signIn.currentUser ??
          await signIn.signInSilently(suppressErrors: true);
      return account == null ? null : _toAccountInfo(account);
    } catch (e) {
      return null;
    }
  }

  /// يفتح OAuth للمستخدم عند الحاجة، ثم يعيد بيانات الحساب التعريفية فقط.
  Future<GoogleAccountInfo?> signIn() async {
    try {
      final signIn = _signIn;
      if (signIn == null) {
        throw const GoogleDriveException(
          'تسجيل الدخول إلى Google غير متاح على هذا الجهاز (سطح المكتب). استخدم خيار الرفع عبر تطبيق Drive.',
        );
      }
      final account = signIn.currentUser ?? await signIn.signIn();
      return account == null ? null : _toAccountInfo(account);
    } catch (e) {
      final str = e.toString();
      if (str.contains('10') ||
          str.contains('DEVELOPER_ERROR') ||
          str.contains('sign_in_failed')) {
        throw const GoogleDriveException(
          'تعذّر تسجيل الدخول التلقائي عبر Google Sign-In المباشر. يمكنك استخدام خيار "رفع إلى Google Drive عبر تطبيق Drive" في الأسفل.',
        );
      }
      throw GoogleDriveException('تعذّر ربط حساب Google: $e');
    }
  }

  /// تسجيل خروج محلي من جلسة Google.
  Future<void> signOut() async {
    try {
      await _signIn?.signOut();
    } catch (e) {
      throw GoogleDriveException('تعذّر تسجيل الخروج من Google: $e');
    }
  }

  /// فصل الحساب وإلغاء المنح السابقة.
  Future<void> disconnect() async {
    try {
      await _signIn?.disconnect();
    } catch (e) {
      throw GoogleDriveException('تعذّر فصل حساب Google: $e');
    }
  }

  Future<GoogleDriveBackupInfo?> latestBackup() async {
    if (debugListBackupsOverride != null) {
      final list = await debugListBackupsOverride!();
      return list.isEmpty ? null : list.first;
    }
    return _withDrive((client, headers) async {
      final files = await _listMatchingBackups(client, headers, pageSize: 10);
      if (files.isNotEmpty) return files.first.toPublicInfo();
      final file = await _findBackup(client, headers);
      return file?.toPublicInfo();
    });
  }

  /// جلب قائمة النسخ الاحتياطية الحديثة المطابقة لبادئة التطبيق من Google Drive
  /// مرتبة من الأحدث إلى الأقدم لعرضها في نافذة الاستعراض المدمجة (Drive Backup Picker).
  Future<List<GoogleDriveBackupInfo>> listBackups({int pageSize = 50}) async {
    if (debugListBackupsOverride != null) {
      final list = await debugListBackupsOverride!();
      return list
          .where((item) => matchesAppBackupPrefix(item.name))
          .toList();
    }
    return _withDrive((client, headers) async {
      final files =
          await _listMatchingBackups(client, headers, pageSize: pageSize);
      return files.map((f) => f.toPublicInfo()).toList();
    });
  }

  /// يرفع نسخة احتياطية جديدة باسم مؤرخ دقيق (أو يحدّث النسخة) على Google Drive.
  Future<GoogleDriveBackupInfo> uploadLatest(
    io.File localFile, {
    bool auto = false,
    String? customFileName,
  }) async {
    if (!await localFile.exists()) {
      throw const GoogleDriveException('ملف النسخة المحلي غير موجود.');
    }
    final bytes = await localFile.readAsBytes();
    final targetName =
        customFileName ?? formatDriveBackupFileName(auto: auto);
    return _withDrive((client, headers) async {
      String? newlyCreatedId;
      try {
        final created = await _createMetadata(
          client,
          headers,
          fileName: targetName,
        );
        newlyCreatedId = created.id;
        final updated = await _uploadContent(client, headers, created, bytes);
        return updated.toPublicInfo();
      } catch (_) {
        if (newlyCreatedId != null) {
          try {
            await client.delete(
              _fileUri('/files/$newlyCreatedId'),
              headers: headers,
            );
          } catch (_) {}
        }
        rethrow;
      }
    });
  }

  /// يرفع ملف نسخة احتياطية باسم مخصص أو مؤرخ إلى Google Drive.
  Future<GoogleDriveBackupInfo> uploadBackupFile(
    io.File localFile, {
    String? fileName,
    bool auto = false,
  }) =>
      uploadLatest(
        localFile,
        auto: auto,
        customFileName: fileName,
      );

  /// ينزّل نسخة محددة بمعرّفها (أو أحدث نسخة إن كان المعرّف فارغاً) إلى ملف مؤقت.
  Future<GoogleDriveBackupInfo> downloadBackupById(
    String fileId,
    io.File target,
  ) async {
    if (debugDownloadBackupByIdOverride != null) {
      final f = await debugDownloadBackupByIdOverride!(fileId, target);
      return GoogleDriveBackupInfo(
        id: fileId,
        name: f.uri.pathSegments.isNotEmpty
            ? f.uri.pathSegments.last
            : backupFileName,
        modifiedTime: DateTime.now(),
        sizeBytes: f.existsSync() ? f.lengthSync() : 0,
      );
    }
    if (fileId.trim().isEmpty) {
      return downloadLatestTo(target);
    }
    return _withDrive((client, headers) async {
      final response = await client.get(
        _fileUri('/files/${Uri.encodeComponent(fileId)}', {'alt': 'media'}),
        headers: headers,
      );
      _ensureSuccess(response, 'تنزيل النسخة');
      final parent = target.parent;
      if (!await parent.exists()) await parent.create(recursive: true);
      await target.writeAsBytes(response.bodyBytes, flush: true);
      return GoogleDriveBackupInfo(
        id: fileId,
        name: target.uri.pathSegments.isNotEmpty
            ? target.uri.pathSegments.last
            : backupFileName,
        modifiedTime: DateTime.now(),
        sizeBytes: response.bodyBytes.length,
      );
    });
  }

  /// ينزّل أحدث نسخة إلى ملف مؤقت يحدده المستدعي.
  Future<GoogleDriveBackupInfo> downloadLatestTo(io.File target) async {
    if (debugDownloadBackupByIdOverride != null) {
      final f = await debugDownloadBackupByIdOverride!('', target);
      return GoogleDriveBackupInfo(
        id: '',
        name: f.uri.pathSegments.isNotEmpty
            ? f.uri.pathSegments.last
            : backupFileName,
        modifiedTime: DateTime.now(),
        sizeBytes: f.existsSync() ? f.lengthSync() : 0,
      );
    }
    return _withDrive((client, headers) async {
      final files = await _listMatchingBackups(client, headers, pageSize: 5);
      final file =
          files.isNotEmpty ? files.first : await _findBackup(client, headers);
      if (file == null) throw const GoogleDriveBackupNotFoundException();
      final response = await client.get(
        _fileUri('/files/${Uri.encodeComponent(file.id)}', {'alt': 'media'}),
        headers: headers,
      );
      _ensureSuccess(response, 'تنزيل النسخة');
      final parent = target.parent;
      if (!await parent.exists()) await parent.create(recursive: true);
      await target.writeAsBytes(response.bodyBytes, flush: true);
      return file.toPublicInfo();
    });
  }

  Future<List<_DriveFile>> _listMatchingBackups(
    http.Client client,
    Map<String, String> headers, {
    int pageSize = 50,
  }) async {
    final byId = <String, _DriveFile>{};
    const query =
        "(name contains 'MyAccounts_' or name contains 'nexora' or name contains 'Nexora' or name contains 'backup_') and trashed = false";

    // 1. البحث في مجلد التطبيق appDataFolder
    try {
      final response = await client.get(
        _fileUri('/files', {
          'spaces': 'appDataFolder',
          'q': query,
          'orderBy': 'modifiedTime desc',
          'pageSize': '$pageSize',
          'fields': 'files($_fileFields)',
        }),
        headers: headers,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['files'] is List) {
          for (final raw in (decoded['files'] as List)) {
            if (raw is Map && raw['id'] is String) {
              final f = _driveFileFromJson(raw);
              if (matchesAppBackupPrefix(f.name)) {
                byId[f.id] = f;
              }
            }
          }
        }
      }
    } catch (_) {}

    // 2. البحث في المساحة العادية لـ Drive
    try {
      final response = await client.get(
        _fileUri('/files', {
          'q': query,
          'orderBy': 'modifiedTime desc',
          'pageSize': '$pageSize',
          'fields': 'files($_fileFields)',
        }),
        headers: headers,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['files'] is List) {
          for (final raw in (decoded['files'] as List)) {
            if (raw is Map && raw['id'] is String) {
              final f = _driveFileFromJson(raw);
              if (matchesAppBackupPrefix(f.name)) {
                byId.putIfAbsent(f.id, () => f);
              }
            }
          }
        }
      }
    } catch (_) {}

    final sorted = byId.values.toList()
      ..sort((a, b) {
        final ta = a.modifiedTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        final tb = b.modifiedTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        return tb.compareTo(ta);
      });
    return sorted;
  }

  Future<_DriveFile?> _findBackup(
    http.Client client,
    Map<String, String> headers,
  ) async {
    // 1. البحث في مجلد التطبيق appDataFolder
    try {
      final response = await client.get(
        _fileUri('/files', {
          'spaces': 'appDataFolder',
          'q': "name = '$backupFileName' and trashed = false",
          'orderBy': 'modifiedTime desc',
          'pageSize': '10',
          'fields': 'files($_fileFields)',
        }),
        headers: headers,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map &&
            decoded['files'] is List &&
            (decoded['files'] as List).isNotEmpty) {
          final first = (decoded['files'] as List).first;
          if (first is Map && first['id'] is String) {
            return _driveFileFromJson(first);
          }
        }
      }
    } catch (_) {}

    // 2. البحث العام في المساحة العادية للـ Drive
    try {
      final response = await client.get(
        _fileUri('/files', {
          'q': "name = '$backupFileName' and trashed = false",
          'orderBy': 'modifiedTime desc',
          'pageSize': '10',
          'fields': 'files($_fileFields)',
        }),
        headers: headers,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map &&
            decoded['files'] is List &&
            (decoded['files'] as List).isNotEmpty) {
          final first = (decoded['files'] as List).first;
          if (first is Map && first['id'] is String) {
            return _driveFileFromJson(first);
          }
        }
      }
    } catch (_) {}

    return null;
  }

  Future<_DriveFile> _createMetadata(
    http.Client client,
    Map<String, String> headers, {
    String fileName = backupFileName,
  }) async {
    // محاولة الإنشاء داخل appDataFolder أولاً
    var response = await client.post(
      _fileUri('/files', {'fields': _fileFields}),
      headers: {...headers, 'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode({
        'name': fileName,
        'mimeType': _mimeType,
        'parents': ['appDataFolder'],
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      // إنشاء بدون تحديد مجلد خاص
      response = await client.post(
        _fileUri('/files', {'fields': _fileFields}),
        headers: {
          ...headers,
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: jsonEncode({'name': fileName, 'mimeType': _mimeType}),
      );
    }

    _ensureSuccess(response, 'إنشاء ملف النسخة');
    return _parseFileResponse(response, 'إنشاء ملف النسخة');
  }

  Future<_DriveFile> _uploadContent(
    http.Client client,
    Map<String, String> headers,
    _DriveFile file,
    List<int> bytes,
  ) async {
    final response = await client.patch(
      _fileUri(
          '/files/${Uri.encodeComponent(file.id)}',
          {
            'uploadType': 'media',
            'fields': _fileFields,
          },
          true),
      headers: {...headers, 'Content-Type': _mimeType},
      body: bytes,
    );
    _ensureSuccess(response, 'رفع محتوى النسخة');
    return _parseFileResponse(response, 'رفع محتوى النسخة');
  }

  _DriveFile _parseFileResponse(http.Response response, String operation) {
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['id'] is! String) {
      throw GoogleDriveException(
        'استجابة Google Drive غير صالحة بعد $operation.',
      );
    }
    return _driveFileFromJson(decoded);
  }

  _DriveFile _driveFileFromJson(Map<dynamic, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const GoogleDriveException('معرّف ملف Google Drive مفقود.');
    }
    final modified = json['modifiedTime'];
    return _DriveFile(
      id: id,
      name: json['name'] is String ? json['name'] as String : backupFileName,
      modifiedTime:
          modified is String ? DateTime.tryParse(modified)?.toLocal() : null,
      sizeBytes: int.tryParse('${json['size'] ?? ''}'),
    );
  }

  Future<T> _withDrive<T>(
    Future<T> Function(http.Client client, Map<String, String> headers)
        operation,
  ) async {
    final signIn = _signIn;
    GoogleSignInAccount? account = signIn?.currentUser;
    account ??= await signIn?.signInSilently(suppressErrors: true);
    if (account == null) {
      throw const GoogleDriveException(
        'تسجيل الدخول إلى Google غير متاح على هذا الجهاز.',
      );
    }
    final signedIn = account;
    final headers = await signedIn.authHeaders;
    final client = http.Client();
    try {
      return await operation(client, headers);
    } on GoogleDriveException {
      rethrow;
    } catch (e) {
      throw GoogleDriveException('تعذّرت عملية Google Drive: $e');
    } finally {
      client.close();
    }
  }

  Uri _fileUri(String path, [Map<String, String>? query, bool upload = false]) {
    final base = upload ? _uploadBasePath : _driveBasePath;
    return Uri.https(_driveHost, '$base$path', query);
  }

  void _ensureSuccess(http.Response response, String operation) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    var detail = response.body.trim();
    if (detail.length > 300) detail = '${detail.substring(0, 300)}…';
    throw GoogleDriveException(
      '$operation فشل (HTTP ${response.statusCode})${detail.isEmpty ? '' : ': $detail'}',
    );
  }

  GoogleAccountInfo _toAccountInfo(GoogleSignInAccount account) =>
      GoogleAccountInfo(
        id: account.id,
        email: account.email,
        displayName: account.displayName,
        photoUrl: account.photoUrl,
      );
}
