// محرك المزامنة الخلفية.
//   - معالجة الصفوف PENDING من sync_queue.
//   - استدعاء transports المسجلة (Cloud/LAN).
//   - إعادة المحاولة مع backoff.
//   - سحب العمليات من الـ Cloud تلقائيًا عند التهيئة.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../../core/database.dart';
import '../../core/token_cipher.dart';
import 'account_workspace.dart';
import 'auto_backup.dart';
import '../providers.dart' show rootNavigatorKey;
import '../repository.dart';
import '../../ui/onboarding_screen.dart' show OnboardingScreen;
import 'catalog_sync_guard.dart';
import 'cloud_firebase_transport.dart';
import 'cloud_join.dart';
import 'conflict_resolver.dart';
import 'device_id.dart';
import 'firebase_auth_service.dart';
import 'google_auth_service.dart';
import 'operation.dart';
import 'recorder.dart';
import 'subscription_guard.dart';
import 'sync_activity.dart';
import 'sync_queue.dart';
import 'sync_diagnostics.dart';
import 'workspace_service.dart';
import '../../core/cloud_config.dart';

abstract class SyncTransport {
  String get targetId; // 'cloud' or 'device:xxx'
  Future<void> push(SyncOperation op);
}

class SyncEngine {
  final Repo repo;
  final Future<Database> Function() dbProvider;
  final List<SyncTransport> _transports = [];
  SyncQueueOps? _queue;
  Timer? _timer;
  Timer? _maintenanceTimer;
  Timer? _cloudPullTimer;
  bool _cloudPulling = false;
  bool _needsRepull = false;
  int _generation = 0;
  bool _running = false;
  bool _started = false;
  bool get hasStarted => _started;
  bool get isCloudSyncActive => _started && _cloudTransport != null;

  /// «نافذة الخطر»: تُستدعى عندما يكتشف المحرك عرقلة حقيقية تمنع المزامنة
  /// (مثل رفض الصلاحيات/القواعد أو تعارض البيانات أو خطأ برمجي/بنيوي)،
  /// ولا تظهر أبداً أثناء ضعف أو انقطاع الإنترنت.
  /// الوسيط رسالة عربية توضح المشكلة. null = زالت الحالة (أمان).
  static void Function(String? message)? onSyncDanger;

  /// آخر رسالة خطر مبثوثة (لتجنب التكرار) — '' تعني لا خطر.
  String _lastDangerMsg = '';

  /// يُستدعى أي نشاط مزامنة (وصول عملية/تغيّر صلاحيات) لتنبيه الواجهة للتحديث.
  static void Function()? onSyncActivity = SyncActivityBus.instance.ping;

  /// (3.71.0 — إخطار الصلاحيات) يُستدعى على جهاز العضو لحظة تطبيق سحب
  /// غيّر دوره/صلاحياته المنتدبة — بدور العضو الجديد («محاسب»...) لتعرض
  /// الواجهة إشعاراً فورياً بلا إعادة تشغيل ولا إغلاق للتطبيق.
  static void Function(String roleLabel)? onPermissionsChanged;
  static void Function()? onSelfRevoked;
  String? _cloudUrl;
  CloudFirebaseTransport? _cloudTransport;

  SyncEngine({required this.repo, required this.dbProvider});

  Future<Database> get _db async {
    final db = await dbProvider();
    try {
      if (!db.isOpen) return await repo.database;
    } catch (_) {}
    return db;
  }

  Future<SyncQueueOps> _ensureQueue() async {
    final db = await _db;
    bool isClosed = false;
    try {
      isClosed = !(_queue?.db.isOpen ?? true);
    } catch (_) {
      isClosed = false;
    }
    if (_queue == null || !identical(_queue!.db, db) || isClosed) {
      _queue = SyncQueueOps(db);
    }
    return _queue!;
  }

  void registerTransport(SyncTransport t) {
    if (_transports.any((x) => x.targetId == t.targetId)) return;
    _transports.add(t);
  }

  /// اللقب الموحد للجهاز بحسب دور مستخدمه: «المدير (اسم الجهاز)»،
  /// «الكاشير (…)»، «مدخل البيانات (…)»، «الشريك / الوكيل (…)».
  /// يُستخدم في كل تنبيهات المزامنة وحالات الأقران.
  Future<String> roleDisplayNameOf(
      String deviceId, String fallbackName) async {
    var name = fallbackName.trim();
    var role = '';
    var isOwner = false;
    try {
      final db = await _db;
      final rows = await db.rawQuery('''
        SELECT d.name, d.is_owner, COALESCE(u.role, '') AS role
        FROM devices d LEFT JOIN users u ON u.id = d.user_id
        WHERE d.id = ? LIMIT 1
      ''', [deviceId]);
      if (rows.isNotEmpty) {
        final r = rows.first;
        final dbName = (r['name'] as String?)?.trim() ?? '';
        if (dbName.isNotEmpty) name = dbName;
        role = (r['role'] as String?) ?? '';
        isOwner = ((r['is_owner'] as int?) ?? 0) == 1;
      }
    } catch (_) {}
    if (name.isEmpty) name = 'جهاز';
    final label = isOwner
        ? 'المدير'
        : switch (role) {
            'admin' || 'manager' => 'المدير',
            'agent' => 'الشريك / الوكيل',
            'accountant' => 'الكاشير',
            'dataentry' => 'مدخل البيانات',
            _ => '',
          };
    return label.isEmpty ? name : '$label ($name)';
  }

  /// حارس تباين السجلات («نافذة الخطر»): يفحص دورياً وجود عرقلة حقيقية
  /// منعت مزامنة عملية مالية (خلل قواعد/صلاحيات أو تعارض بيانات أو خطأ تطبيقي).
  /// لا يظهر التحذير أبداً أثناء ضعف أو انقطاع الإنترنت، بل يظهر فقط عند وجود خلل حقيقي.
  Future<void> _checkDangerState() async {
    if (onSyncDanger == null) return;
    try {
      final mode = await repo.workspaceMode();
      if (mode == 'standalone') {
        _clearDanger();
        return;
      }
      final st = await repo.settings();
      if ((st['account.type'] ?? '') == 'individual') {
        _clearDanger();
        return;
      }
      final db = await _db;
      final rows = await db.rawQuery(
        "SELECT q.operation_id, q.status, q.attempts, q.last_error, q.created_at, "
        "o.entity_type, o.op_type, o.payload, o.timestamp AS op_ts "
        "FROM sync_queue q JOIN operations o ON o.id = q.operation_id "
        "WHERE q.status IN ('failed','pending','syncing') "
        "AND o.entity_type NOT IN ${SyncQueueOps.silentEntities} "
        "ORDER BY CASE WHEN q.status = 'failed' THEN 0 ELSE 1 END, q.attempts DESC",
      );
      if (rows.isEmpty) {
        _clearDanger();
        return;
      }

      // ترشيح العمليات التي تواجه عرقلة حقيقية (خلل غير شبكي):
      // تجاهل أخطاء ضعف/انقطاع الإنترنت (SocketException, TimeoutException, failed host lookup...)
      // وتجاهل العمليات الحديثة التي لم تستنفد محاولات كافية.
      final now = DateTime.now();
      final realFaultRows = <Map<String, Object?>>[];
      for (final r in rows) {
        final err = ('${r['last_error'] ?? ''}').trim();
        if (err.isEmpty) continue;
        final lowerErr = err.toLowerCase();
        final isInternetOutage = lowerErr.contains('socketexception') ||
            lowerErr.contains('timeoutexception') ||
            lowerErr.contains('handshakeexception') ||
            lowerErr.contains('tlsexception') ||
            lowerErr.contains('clientexception') ||
            lowerErr.contains('failed host lookup') ||
            lowerErr.contains('network is unreachable') ||
            lowerErr.contains('connection refused') ||
            lowerErr.contains('connection reset') ||
            lowerErr.contains('connection timed out') ||
            lowerErr.contains('no address associated with hostname') ||
            lowerErr.contains('software caused connection abort');
        if (isInternetOutage) continue;

        final tsStr = '${r['op_ts'] ?? r['created_at'] ?? ''}'.trim();
        final createdAt = DateTime.tryParse(tsStr) ?? now;
        final age = now.difference(createdAt);
        final attempts = (r['attempts'] as int?) ??
            int.tryParse('${r['attempts'] ?? 0}') ??
            0;
        final isImmediateHardError = lowerErr.contains('permission') ||
            lowerErr.contains('401') ||
            lowerErr.contains('403') ||
            lowerErr.contains('constraint');
        if (!isImmediateHardError &&
            (age < const Duration(minutes: 5) || attempts < 3)) {
          continue;
        }
        realFaultRows.add(r);
      }

      if (realFaultRows.isEmpty) {
        _clearDanger();
        return;
      }

      final firstFault = realFaultRows.first;
      final count = realFaultRows.map((r) => '${r['operation_id']}').toSet().length;
      final entityType = '${firstFault['entity_type'] ?? ''}';
      final entityAr = switch (entityType) {
        'tx' || 'transaction' => 'حركة مالية',
        'voucher' => 'سند مالي',
        'account' => 'حساب',
        'item' => 'صنف مخزني',
        'section' => 'قسم',
        'item_category' || 'category' => 'فئة أصناف',
        'currency' => 'عملة',
        'user' || 'user_permission' => 'صلاحية مستخدم',
        _ => 'عملية',
      };
      String itemTitle = '';
      try {
        final rawPayload = '${firstFault['payload'] ?? ''}';
        if (rawPayload.isNotEmpty) {
          final decoded = jsonDecode(rawPayload);
          if (decoded is Map) {
            itemTitle = '${decoded['name'] ?? decoded['description'] ?? decoded['note'] ?? decoded['title'] ?? ''}'.trim();
          }
        }
      } catch (_) {}
      final labelPart = itemTitle.isNotEmpty ? ' ($entityAr: $itemTitle)' : ' ($entityAr)';
      final msg =
          'تنبيه خطير — احتمال تباين الأرصدة والعمليات: توجد $count عملية عالقة$labelPart بسبب خلل يتطلب المعالجة — اضغط لعرض التفاصيل.';
      if (msg != _lastDangerMsg) {
        _lastDangerMsg = msg;
      }
      try {
        onSyncDanger?.call(msg);
      } catch (_) {}
    } catch (_) {}
  }

  /// للاختبارات: تشغيل فحص الخطر مباشرة بلا انتظار المؤقّت الدوري.
  @visibleForTesting
  Future<void> debugCheckDangerState() => _checkDangerState();

  /// فحص فوري عام لواجهة المستخدم (زر «إعادة المحاولة» في بانر الخطر):
  /// يعيد تقييم الحالة حالاً — نجاح يبثّ null، وبقاء الخطر يبثّ الرسالة.
  Future<void> recheckDangerNow() => _checkDangerState();

  void _clearDanger() {
    if (_lastDangerMsg.isNotEmpty) {
      _lastDangerMsg = '';
      try {
        onSyncDanger?.call(null);
      } catch (_) {}
    }
  }

  /// (دفعة 58) إعادة تهيئة شاملة = السحابة فقط — لا طبقة LAN بعد اليوم.
  Future<void> reconfigureAll() async {
    try {
      await reconfigureCloud();
    } catch (_) {}
  }

  /// يُعاد تهيئة الـ Cloud transport بعد تغيير الإعدادات.
  Future<void> reconfigureCloud() async {
    try {
      _cloudUrl = null;
      _transports.removeWhere((t) => t.targetId == SyncTarget.cloud);
      await _cloudTransport?.stopListening();
      _cloudTransport = null;
      await _ensureCloudTransport();
      if (_cloudTransport != null) {
        try {
          await _cloudTransport!.pull(resolver: ConflictResolver());
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _ensureCloudTransport() async {
    final st = await repo.settings();
    final url = effectiveBackendUrl(st['cloudBackendUrl']);
    final isReadyForCloud = await SubscriptionGuard.isWorkspaceCloudReady(repo);
    final autoSync = kCloudAutoSyncAlways && isReadyForCloud;
    if (!autoSync || url.isEmpty) {
      _transports.removeWhere((t) => t.targetId == SyncTarget.cloud);
      unawaited(_cloudTransport?.stopListening() ?? Future.value());
      _cloudTransport = null;
      _cloudUrl = null;
      // تنظيف: صفوف cloud القديمة العالقة بلا خادم سحابي مهيأ — كانت تبقى
      // «بانتظار الإرسال» للأبد وتظهر كمزامنات معلقة. نُعلمها synced.
      try {
        final db = await _db;
        await db.update(
          'sync_queue',
          {
            'status': 'synced',
            'last_error': '',
            'next_try_at': '',
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: "target = ? AND status IN ('pending','syncing','failed')",
          whereArgs: [SyncTarget.cloud],
        );
      } catch (_) {}
      return;
    }
    final db = await _db;
    // ══ (2026-09-22 — توجيه العمليات) ══
    // الربط المحلي قد يشير لمساحة قديمة/مكرّرة بينما يسجلنا السحاب في
    // أخرى: تذهب عملياتنا لمسار لا يقرأه المدير (أو العكس) — «الأسهم
    // خضراء ولا شيء ينتقل». السحابة هي الحكم: نثبّت المحلي على المساحة
    // التي يضعنا سجلها (roster) فيها قبل بناء أي نقل.
    try {
      await CloudJoin.reconcileWorkspaceBinding(repo, backendUrl: url);
    } catch (_) {}
    // (2026-09-22) صف صلاحيات فعّال للمالك بعد كل مواءمة ربط: جهاز
    // استُرجع أو انتقلت إليه الملكية يعود مديراً فوراً بلا شارة حمراء.
    try {
      await repo.ensureSelfPermissionRow();
    } catch (_) {}
    // Workspace الحالي — يُقرأ من الجدول في كل استدعاء: الربط يستبدل
    // الجدول بلقطة المجموعة، ونقلٌ بُني بالمعرّف القديم يظل يدفع ويسحب من
    // مسار خاطئ فتموت المزامنة بصمت.
    // (3.71.0 — ربط حتمي) نفس حلّ المستودع: الربط الصريح في الإعدادات
    // أولاً ثم أحدث صف — النقل لا يرتبط أبداً بمساحة شخصية ميتة.
    final wsId = await ensureWorkspace(db, repo: repo);
    await AppDatabase.ensureWorkspaceRow(db, wsId);
    try {
      await repo.purgeNonEmailWorkspaces();
    } catch (_) {}
    if (url == _cloudUrl &&
        _cloudTransport != null &&
        _cloudTransport!.workspaceId == wsId) {
      return;
    }
    // العنوان أو المساحة تغيّرت: تقاعد النقل القديم قبل بناء الجديد حتى لا
    // يبقى استماعه القديم (SSE) نشطاً على مسار بائد.
    if (_cloudTransport != null) {
      _transports.removeWhere((t) => t.targetId == SyncTarget.cloud);
      try {
        await _cloudTransport!.stopListening();
      } catch (_) {}
      _cloudTransport = null;
    }
    _cloudTransport = CloudFirebaseTransport.validated(
      repo: repo,
      dbProvider: dbProvider,
      backendUrl: url,
      workspaceId: wsId,
      idTokenProvider: () async {
        try {
          final d = await _db;
          final r = await d.query('google_auth', where: 'id = 1', limit: 1);
          if (r.isEmpty) return null;
          final stored = r.first['id_token'] as String?;
          if (stored == null || stored.isEmpty) return null;
          // مخزّن معمّى (enc1:) أو نص صريح قديم — reveal يتعامل مع الحالتين.
          final tok = await TokenCipher.reveal(stored);
          return tok.isEmpty ? null : tok;
        } catch (_) {
          return null;
        }
      },
    );
    registerTransport(_cloudTransport!);
    _cloudUrl = url;
    // استماع فوري SSE: أي عملية يكتبها جهاز آخر في السحابة تصلنا لحظياً
    // (السحب الدوري كل 45 ثانية يبقى شبكة أمان لو انقطعت القناة).
    _cloudTransport!.onCloudChanged = () {
      if (_cloudPulling) {
        _needsRepull = true;
        return;
      }
      Future(() async {
        if (_cloudPulling) {
          _needsRepull = true;
          return;
        }
        _cloudPulling = true;
        try {
          // (3.71.0) تشخيص: دفعة SSE تُطلق دورة سحب مسجَّلة بدورها.
          SyncDiagnostics.instance.pullStarted();
          final applied =
              await _cloudTransport?.pull(resolver: ConflictResolver()) ?? 0;
          SyncDiagnostics.instance.pullFinished(
            ok: true,
            applied: applied,
            context: 'SSE → transport.pull',
          );
          if (applied > 0) {
            try {
              onSyncActivity?.call();
            } catch (_) {}
          }
          await _checkMemberPermissions();
        } catch (e) {
          SyncDiagnostics.instance.pullFinished(
            ok: false,
            error: e,
            context: 'SSE → transport.pull',
          );
        } finally {
          _cloudPulling = false;
          SyncDiagnostics.instance.pullIdle();
          if (_needsRepull && _started) {
            _needsRepull = false;
            Future.delayed(
              const Duration(milliseconds: 120),
              () => _cloudTransport?.onCloudChanged?.call(),
            );
          }
        }
      });
    };
    unawaited(_cloudTransport!.startListening());
  }

  Future<void> start() async {
    if (_started) return;
    // (3.70) الحساب الفردي يعمل محلياً بالكامل: لا محرك ولا شبكة ولا طابور.
    // التبديل لاحقاً إلى «مؤسسة» يسمح باستدعاء start() مجدداً (_started لم يُرفع).
    try {
      final st0 = await repo.settings();
      if ((st0['account.type'] ?? '') == 'individual') return;
    } catch (_) {}
    _started = true;
    final generation = ++_generation;
    _queue = await _ensureQueue();
    await _queue!.recoverInterrupted();
    // إنقاذ سحابي: عمليات سُجّلت قبل تهيئة السحابة (لا صف cloud لها) —
    // تُدرج الآن لتصعد للسحابة فتصل الأجهزة المرتبطة سحابياً.
    try {
      await _backfillMissedCloudOps();
    } catch (_) {}
    // (دفعة 58) هجرة تنظيف: أي صفوف lan تاريخية متبقية من إصدارات ما قبل
    // اجتثاث LAN تُغلق نهائياً حتى لا تسد الطابور أو تُظهر بانر الخطأ.
    try {
      final db0 = await _db;
      await db0.update(
        'sync_queue',
        {
          'status': 'synced',
          'last_error': '',
          'next_try_at': '',
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: "target = 'lan' AND status IN ('pending','syncing','failed')",
      );
      await _queue!.resumeBackoff();
    } catch (_) {}
    if (!_started || generation != _generation) return;
    // ربط callback لتحفيز push فوري بعد تسجيل أي عملية جديدة.
    SyncRecorder.onOperationRecorded = notifyNewOperation;
    // أي فشل في تهيئة المزامنة (سواء سحابة أو شبكة محلية) لا يجب أن يمنع
    // التطبيق من الإقلاع أو تعطيل الحفظ المحلي — محلي أولًا دائماً.
    try {
      await _ensureCloudTransport();
    } catch (_) {}
    if (!_started || generation != _generation) return;
    _timer ??= Timer.periodic(
      const Duration(seconds: 12),
      (_) async {
        await processQueue();
        await _checkDangerState();
      },
    );

    Future(() async {
      if (!_started || generation != _generation) return;
      try {
        await _ensureCloudTransport();
        if (_cloudTransport != null) {
          await _periodicCloudPull();
        }
      } catch (_) {}
      await _checkExpulsionAndAutoPurge();
      await processQueue();
    });
    // تفقد دوري كل 6 ساعات: هل طرأ طرد لنا، أو هناك أجهزة خاملة لنطرَدها تلقائياً.
    _maintenanceTimer ??= Timer.periodic(
      const Duration(hours: 6),
      (_) async {
        await _checkExpulsionAndAutoPurge();
        try {
          await _pruneOperationPayloads();
        } catch (_) {}
        // (دفعة 58) رسائل الدردشة تُحذف نهائياً بعد 24 ساعة (محلي).
        try {
          await repo.purgeExpiredChatMessages();
        } catch (_) {}
        // (2026-09-24) النمط الفردي: تقليم سجل العمليات المحلي (بلا ناقل
        // سحابي يستهلكه) حتى لا تتضخّم القاعدة بلا حد.
        try {
          await repo.pruneIndividualOperations();
        } catch (_) {}
        // (3.70) النسخ الاحتياطي التلقائي الموحّد: المجدول (محلي/Drive/سحابي)
        // أو الصامت القديم — فشل أي مسار يُبتلع ويُعاد في الدورة القادمة.
        try {
          await AutoBackupService.maybeRun(repo);
        } catch (_) {}
      },
    );
    // دورة نسخ عند الإقلاع إن كانت مستحقة (خلفية، لا تعطل الواجهة).
    Future(() async {
      try {
        await AutoBackupService.maybeRun(repo);
      } catch (_) {}
    });
    // تقليم فوري عند الإقلاع (خلفية، لا يعطل الواجهة) + جلب المرفقات
    // الناقصة من الأقران (عمليات وصلت بالمزامنة بلا ملفاتها).
    Future(() async {
      try {
        await _pruneOperationPayloads();
      } catch (_) {}
      // (دفعة 58) تنظيف الدردشة المنتهية عمرها فور الإقلاع أيضاً.
      try {
        await repo.purgeExpiredChatMessages();
      } catch (_) {}
      // (2026-09-24) تقليم سجل العمليات عند الإقلاع أيضاً (النمط الفردي).
      try {
        await repo.pruneIndividualOperations();
      } catch (_) {}
    });
    // سحب سحابي دوري متوازن (كل 20 ثانية) كاحتياط لقناة SSE اللحظية:
    // يمنع استنزاف المعالج والبطارية وارتفاع حرارة الجهاز مع بقاء SSE الفوري نشطاً.
    _cloudPullTimer ??= Timer.periodic(
      const Duration(seconds: 20),
      (_) => _periodicCloudPull(),
    );
  }

  DateTime _lastHeavyMaintenanceCheck = DateTime.fromMillisecondsSinceEpoch(0);

  /// (3.71.0) بصمة صلاحيات العضو المنتدب — أي تغيّر فيها يُخطر فوراً.
  String? _memberPermsSig;

  Future<void> _checkMemberPermissions() async {
    try {
      final mode = await repo.workspaceMode();
      if (mode != 'member') {
        _memberPermsSig = null;
        return;
      }
      final me = await repo.deviceAssignedUser();
      final sig = me == null
          ? ''
          : '${me.role.code}|'
              '${me.permissions.entries.where((e) => e.value).map((e) => e.key).join(',')}|'
              '${me.active}';
      if (_memberPermsSig == null) {
        _memberPermsSig = sig; // خط أساس عند الإقلاع — لا إخطار بأثر رجعي.
      } else if (sig != _memberPermsSig && sig.isNotEmpty) {
        _memberPermsSig = sig;
        try {
          onPermissionsChanged?.call(me?.role.label ?? '');
        } catch (_) {}
      }

      // فحص هل تمت الموافقة على مغادرة العضو أو طرده من السجل السحابي أو محلياً
      try {
        final st = await repo.settings();
        final url = effectiveBackendUrl(st['cloudBackendUrl']);
        final t = _cloudTransport;
        final ourId = await ensureDeviceId(repo);
        final isExpelledLocally = await repo.amIExpelled();
        final wsToCheck = t?.workspaceId ?? (await repo.activeWorkspaceId());
        final approved = isExpelledLocally ||
            (url.isNotEmpty &&
                wsToCheck.isNotEmpty &&
                await CloudJoin.checkLeaveOrEvicted(
                  backendUrl: url,
                  workspaceId: wsToCheck,
                  deviceId: ourId,
                  // (PR-5) لا تُنفَّذ التصفية إلا بشاهد طرد أحدث من آخر
                  // انضمام ناجح — الأثر الأقدم يُتجاهل ويُمسح ذاتياً.
                  joinedAtMs: int.tryParse(st['sync.joinedAtMs'] ?? ''),
                ));
        if (approved) {
          final oldWs = await repo.activeWorkspaceId();
          stop();
          await repo.resetToStandaloneAfterExpulsion();
          await AccountWorkspace.removeWorkspaceFromLocalRegistry(
            oldWs,
            deleteDbFile: true,
          );
          await FirebaseAuthRest.clearSession(repo);
          await FirebaseAuthRest.purgeAllSessionPrefs(
            clearWorkspacesList: false,
          );
          try {
            final db = await repo.database;
            await GoogleAuthService(db).signOut();
          } catch (_) {}
          try {
            onSelfRevoked?.call();
          } catch (_) {}
          rootNavigatorKey.currentState?.pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => const OnboardingScreen(
                initialNotice:
                    'تم إنهاء ارتباط هذا الجهاز بالمجموعة من قِبل المدير (تم طرد الجهاز أو حظره أو اعتماد مغادرته). تم تصفير بيانات المجموعة والعودة إلى شاشة البداية.',
              ),
            ),
            (route) => false,
          );
          return;
        }

        if (url.isNotEmpty && t != null) {
          // تثبيت وجود العضو في السجل السحابي حتى لا يختفي أو ينفصل
          try {
            final db = await repo.database;
            final own = await db.query('devices',
                where: 'id = ?', whereArgs: [ourId], limit: 1);
            if (own.isNotEmpty) {
              await CloudJoin.ensureMemberRosterPresence(
                backendUrl: url,
                workspaceId: t.workspaceId,
                deviceId: ourId,
                deviceRow: own.first,
              );
            }
          } catch (_) {}
        }
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> _periodicCloudPull() async {
    if (_cloudPulling || !_started) return;
    if (_cloudTransport == null) {
      try {
        await _ensureCloudTransport();
      } catch (_) {}
    }
    if (_cloudTransport == null) return;
    // 🔒 انتهاء التجربة يوقف السحب السحابي الدوري أيضاً.
    if (await _trialBlocked()) {
      if (!SyncDiagnostics.instance.snapshot.lastPullOk &&
          !SyncDiagnostics.instance.snapshot.downloadFaulted) {
        SyncDiagnostics.instance.pullFinished(
          ok: true,
          applied: 0,
          context: '_periodicCloudPull → trial check ok',
        );
      }
      return;
    }

    // 🔒 التحقق الصارم من صلاحيات العضو ومساحة العمل قبل السحب
    try {
      final q = await _ensureQueue();
      final activeWs = await repo.activeWorkspaceId();
      final t = _cloudTransport!;
      final isExpelled = await repo.amIExpelled();
      final user = await repo.deviceAssignedUser();
      final access = await q.verifyMemberAccess(
        activeWorkspaceId: activeWs,
        expectedWorkspaceId: t.workspaceId,
        userRole: user?.role.code,
        userPermissions: user?.permissions.entries
            .where((e) => e.value)
            .map((e) => e.key)
            .toList(),
        isExpelledOrRevoked: isExpelled,
        isPushOperation: false,
      );
      if (access['allowed'] != true) {
        if (isExpelled) {
          unawaited(_checkMemberPermissions());
        }
        SyncDiagnostics.instance.pullFinished(
          ok: false,
          error: access['message'] ?? 'المزامنة متوقفة: المستخدم أو المنشأة غير مصرح بها.',
          context: '_periodicCloudPull → verifyMemberAccess',
        );
        return;
      }
    } catch (_) {}

    _cloudPulling = true;
    try {
      // (3.71.0) تشخيص: سهم الاستقبال يومض أثناء الدورة وتُسجَّل نتيجتها.
      SyncDiagnostics.instance.pullStarted();
      await AppDatabase.ensureWorkspaceRow(
          await _db, _cloudTransport!.workspaceId);
      final applied = await _cloudTransport!.pull(resolver: ConflictResolver());
      SyncDiagnostics.instance.pullFinished(
        ok: true,
        applied: applied,
        context: '_periodicCloudPull → transport.pull',
      );
      if (applied > 0) {
        try {
          onSyncActivity?.call();
        } catch (_) {}
      }
      // (3.71.0) الصلاحيات المنتدبة تُفحص كل دورة (5 ثوانٍ): تعديل المدير
      // يُنفذ على جهاز العضو فوراً ويُخطر به بدون إغلاق التطبيق وفتحه.
      await _checkMemberPermissions();
      // سجل الأجهزة السحابي: يرى المدير أجهزة الأعضاء البعيدة (المنضمة عبر
      // السحابة) ويعيّن لها مستخدمين، وتصل التعيينات/الحظر/الطرد للأعضاء.
      try {
        final t = _cloudTransport!;
        final db = await _db;
        await AppDatabase.ensureWorkspaceRow(db, t.workspaceId);
        final changed = await CloudJoin.syncRoster(
          repo,
          db,
          backendUrl: t.backendUrl,
          workspaceId: t.workspaceId,
        );
        if (changed) {
          await _checkMemberPermissions();
          try {
            onSyncActivity?.call();
          } catch (_) {}
        }
        final healed = await CatalogSyncGuard.healStubEntities(
          repo: repo,
          backendUrl: t.backendUrl,
          workspaceId: t.workspaceId,
        );
        if (healed > 0) {
          try {
            onSyncActivity?.call();
          } catch (_) {}
        }
      } catch (_) {}

      // (1) فحص تطابق الكتالوج محلياً دون إسقاط المؤشر أو سحب الشجرة كاملة (No Full Dumps)
      // وتطهير الإشعارات القديمة بفاصل زمني هادئ (كل 3 دقائق).
      final now = DateTime.now();
      if (now.difference(_lastHeavyMaintenanceCheck) >=
          const Duration(minutes: 3)) {
        _lastHeavyMaintenanceCheck = now;
        try {
          final t = _cloudTransport!;
          await CatalogSyncGuard.verifyAndPublish(repo: repo, transport: t);
        } catch (_) {}

        try {
          await repo.purgeOldNotifications();
        } catch (_) {}
      }
    } catch (e) {
      // شبكة غائبة/خادم بعيد — المحاولة القادمة بعد الدورة التالية.
      // (3.71.0) تشخيص: استثناء السحب يُصنَّف (كود/سحابة/شبكة) ويُعرض.
      SyncDiagnostics.instance.pullFinished(
        ok: false,
        error: e,
        context: '_periodicCloudPull → transport.pull',
      );
    } finally {
      _cloudPulling = false;
      SyncDiagnostics.instance.pullIdle();
      if (_needsRepull && _started) {
        _needsRepull = false;
        unawaited(_periodicCloudPull());
      }
    }
  }


  /// إنقاذ سحابي: كل عملية محلية غير متزامنة (`is_synced == 0`) لم يُدرج لها هدف
  /// cloud (سُجّلت قبل ضبط السحابة أو أثناء تعطيلها) تُدرج pending الآن.
  Future<void> _backfillMissedCloudOps() async {
    final db = await _db;
    final st = await repo.settings();
    final cloudOn =
        effectiveBackendUrl(st['cloudBackendUrl']).isNotEmpty &&
            kCloudAutoSyncAlways;
    if (!cloudOn) return;
    final ourId = st['sync.deviceId'] ?? '';
    if (ourId.isEmpty) return;
    final now = DateTime.now().toIso8601String();
    try {
      await db.rawInsert('''
        INSERT OR IGNORE INTO sync_queue
          (operation_id, status, target, attempts, last_error, next_try_at,
           created_at, updated_at)
        SELECT o.id, 'pending', 'cloud', 0, '', '', ?, ?
        FROM operations o
        WHERE o.device_id = ?
          AND COALESCE(o.is_synced, o.synced, 0) = 0
          AND NOT EXISTS (
            SELECT 1 FROM sync_queue q
            WHERE q.operation_id = o.id AND q.target = 'cloud'
          )
      ''', [now, now, ourId]);
    } catch (_) {
      await db.rawInsert('''
        INSERT OR IGNORE INTO sync_queue
          (operation_id, status, target, attempts, last_error, next_try_at,
           created_at, updated_at)
        SELECT o.id, 'pending', 'cloud', 0, '', '', ?, ?
        FROM operations o
        WHERE o.device_id = ?
          AND COALESCE(o.synced, 0) = 0
          AND o.id NOT IN (
            SELECT operation_id FROM sync_queue
            WHERE status IN ('pending', 'syncing')
          )
          AND NOT EXISTS (
            SELECT 1 FROM sync_queue q
            WHERE q.operation_id = o.id AND q.target = 'cloud'
          )
      ''', [now, now, ourId]);
    }
  }

  /// صيانة تخزين جدول العمليات (تعمل عند الإقلاع وكل 6 ساعات):
  /// 1) تجريد حمولات base64 الضخمة (مرفقات الدردشة/الفواتير) من العمليات المحليّة
  ///    لضمان خلو عقد operations من أي وسائط ثقيلة.
  /// 2) حذف عمليات الدردشة القديمة (أقدم من 14 يوماً) المستلمة من الجميع
  ///    والمرفوعة للسحابة — الرسائل نفسها باقية في جدول messages.
  /// مدخل للاختبارات فقط — يشغّل صيانة تخزين العمليات مباشرة.
  @visibleForTesting
  Future<void> pruneOperationPayloadsForTesting() =>
      _pruneOperationPayloads();

  Future<void> _pruneOperationPayloads() async {
    final db = await _db;
    final ourId = (await repo.settings())['sync.deviceId'] ?? '';
    if (ourId.isEmpty) return;
    // (1) تجريد base64 من العمليات المتزامنة فقط مع حماية العمليات المعلقة:
    // AND op_id NOT IN (SELECT op_id FROM sync_queue WHERE status IN ('pending', 'syncing'))
    final fat = await db.rawQuery('''
      SELECT id, payload FROM operations
      WHERE payload LIKE '%"file_b64"%'
        AND id NOT IN (SELECT operation_id FROM sync_queue WHERE status IN ('pending', 'syncing'))
      LIMIT 200
    ''');
    for (final r in fat) {
      try {
        final decoded =
            jsonDecode((r['payload'] as String?) ?? '{}') as Map;
        final slim = Map<String, Object?>.from(decoded)
          ..remove('file_b64')
          ..['file_pruned'] = 1;
        await db.update('operations', {'payload': jsonEncode(slim)},
            where: 'id = ?', whereArgs: [r['id']]);
      } catch (_) {}
    }
    // (2) حذف عمليات الرسائل القديمة كلياً بعد فترة الاحتفاظ.
    final cutoff = DateTime.now()
        .subtract(const Duration(days: 14))
        .toIso8601String();
    try {
      await db.rawDelete('''
        DELETE FROM operations
        WHERE entity_type = 'message'
          AND COALESCE(is_synced, synced, 0) = 1
          AND timestamp < ?
          AND id NOT IN (
            SELECT operation_id FROM sync_queue
            WHERE status IN ('pending', 'syncing')
          )
      ''', [cutoff]);
    } catch (_) {}
    // (3) تقليم عام (Compaction): العمليات المتجاوَزة — synced، مسلَّمة لكل
    // الأقران النشطين، أقدم من 14 يوماً، وليست أحدث نسخة لكيانها.
    // الإبقاء على أحدث نسخة لكل كيان يحفظ اتساق تسلسل الإصدارات
    // (nextVersion يقرأ MAX(version)) ويُبقي حاجز idempotency ضد إعادة
    // تطبيق نسخ قديمة تصل من سحب سحابي كامل.
    try {
      await db.transaction((txn) async {
        await txn.rawDelete('''
          DELETE FROM operations
          WHERE synced = 1 AND timestamp < ?
            AND entity_type <> 'message'
            AND EXISTS (
              SELECT 1 FROM operations n
              WHERE n.entity_type = operations.entity_type
                AND n.entity_id = operations.entity_id
                AND n.version > operations.version
            )
            AND NOT EXISTS (
              SELECT 1 FROM sync_queue q
              WHERE q.operation_id = operations.id
                AND q.status IN ('pending', 'syncing')
            )
        ''', [cutoff]);
        // صفوف الطابور التاريخية (synced) الأقدم من فترة الاحتفاظ.
        await txn.rawDelete(
          "DELETE FROM sync_queue WHERE status = 'synced' AND updated_at < ?",
          [cutoff],
        );
      });
    } catch (_) {}
  }

  Future<void> _checkExpulsionAndAutoPurge() async {
    try {
      if (await repo.isWorkspaceOwner()) {
        // ⛔️ الطرد التلقائي للأجهزة الخاملة مُلغى نهائياً بقرار المستخدم —
        // لا يُطرد أي جهاز إلا يدوياً من شاشة الأجهزة بيد المدير.
        // (دفعة 57) صيانة سحابية للمدير في نفس الدورة:
        //  1) تقليم شواهد الطرد المنتهية (TTL 7 أيام) — لا ركام أبدياً.
        //  2) ضغط سجل العمليات السحابي (أقدم من 30 يوماً ومغطاة باللقطة).
        try {
          final st = await repo.settings();
          final url = effectiveBackendUrl(st['cloudBackendUrl']);
          if (url.isNotEmpty) {
            final ws = _cloudTransport?.workspaceId ?? 'default';
            // (تنظيف مؤجل) طلبات الانضمام التي سُوّي أمرها وانقضت مهلتها
            // (10 دقائق) تُقلَّم هنا — بلا حذف فوري يُعلّق العضو.
            try {
              await CloudJoin.pruneStaleJoinRequests(
                  backendUrl: url, workspaceId: ws);
            } catch (_) {}
            // (أ-2) مفاتيح فهرس الدعوات المنتهية على الجذر.
            try {
              await CloudJoin.pruneExpiredInviteIndex(backendUrl: url);
            } catch (_) {}
            try {
              await compactCloudOperations(backendUrl: url, workspaceId: ws);
            } catch (_) {}
            // (دفعة 58) عمليات الدردشة الأقدم من 24 ساعة تُطهَّر سحابياً.
            try {
              await CloudJoin.purgeOldChatOperations(
                  backendUrl: url, workspaceId: ws);
            } catch (_) {}
            // 3) زوال اللقطة: دعوة منتهية بلا أخرى حية → حذف joinSnapshot.
            try {
              await CloudJoin.purgeStaleInviteArtifacts(
                  backendUrl: url, workspaceId: ws);
            } catch (_) {}
          }
        } catch (_) {}
        return;
      }
      await _checkMemberPermissions();
    } catch (_) {}
  }

  /// (دفعة 53) المعالجة المركزية للطرد الذاتي — تُنفَّذ مرة واحدة فقط:
  void stop() {
    _started = false;
    _generation++;
    _queue = null;
    _timer?.cancel();
    _maintenanceTimer?.cancel();
    _cloudPullTimer?.cancel();
    _cloudPullTimer = null;
    unawaited(_cloudTransport?.stopListening() ?? Future.value());
    _cloudTransport = null;
    _cloudUrl = null;
    _transports.removeWhere((t) => t.targetId == SyncTarget.cloud);
    _immediate?.cancel();
    _timer = null;
    _maintenanceTimer = null;
    _immediate = null;
    if (SyncRecorder.onOperationRecorded == notifyNewOperation) {
      SyncRecorder.onOperationRecorded = null;
    }
  }

  /// مزامنة فورية صريحة مع معالجة توفيقية للأحدث (Last-Write-Wins).
  Future<void> forceSyncNow({bool deepReconcile = false}) async {
    if (_cloudTransport == null) {
      try {
        await _ensureCloudTransport();
      } catch (_) {}
    }
    final q = await _ensureQueue();
    await q.retryFailed();
    await processQueue();
    if (deepReconcile && _cloudTransport != null) {
      SyncDiagnostics.instance.pullStarted();
      try {
        final applied = await _cloudTransport!.pull(
          resolver: ConflictResolver(),
          forceFullSync: true,
        );
        SyncDiagnostics.instance.pullFinished(
          ok: true,
          applied: applied,
          context: 'forceSyncNow → transport.pull',
        );
        if (applied > 0) {
          try {
            onSyncActivity?.call();
          } catch (_) {}
        }
      } catch (e) {
        SyncDiagnostics.instance.pullFinished(
          ok: false,
          error: e,
          context: 'forceSyncNow → transport.pull',
        );
      } finally {
        SyncDiagnostics.instance.pullIdle();
      }
    }
    // (3.71.0) «إعادة المحاولة والفحص الآن» = دفع + سحب معاً: دورة سحب
    // فورية تحدّث سهم الاستقبال وورقة التشخيص في نفس اللحظة.
    await _periodicCloudPull();
    // إذا كان الجهاز مستعداً للسحابة ولم يسبق تسجيل فشل، نحدّث مؤشر السحب عند نجاح تهيئة النقل
    if (_cloudTransport != null &&
        !SyncDiagnostics.instance.snapshot.lastPullOk &&
        !SyncDiagnostics.instance.snapshot.downloadFaulted) {
      SyncDiagnostics.instance.pullFinished(
        ok: true,
        applied: 0,
        context: 'forceSyncNow → verified ready',
      );
    }
    // إعادة تقييم «نافذة الخطر» فوراً: إن نجح الدفع يُبث null فيختفي
    // البانر في نفس اللحظة دون انتظار الدورة (8 ثوانٍ).
    await _checkDangerState();
  }

  /// مزامنة توفيقية ذكية للأحدث بين جميع الأجهزة بدون توقف.
  Future<void> reconcileAndSyncNow() => forceSyncNow(deepReconcile: false);

  /// زر «إعادة المحاولة والمزامنة فوراً» في بانر الخطر: نفس forceSyncNow
  /// باسم صريح — يصفّر backoff ويعيد المحاولة ويدفع كل المعلّق حالاً
  /// ثم يعيد فحص الخطر ليُخفى البانر تلقائياً عند النجاح.
  Future<void> triggerImmediateSync() => forceSyncNow(deepReconcile: true);

  /// يُستدعى بعد تغيير صلاحية/جهاز (منح صلاحية لجهاز) لبثّ التغيير فورًا
  /// إلى كل الأقران ودفع أي عمليات معلّقة — استجابة خلال ثوانٍ (<10 ثوانٍ).
  /// (دفعة 54 — جهة المدير) بث الطرد النشط لجهاز مستهدف:
  ///  1) شاهدة صريحة في /evictions/$deviceId بختم وقت الخادم —
  ///     تصل المستهدف عبر قناته المخصصة لحظياً.
  ///  2) حذف عقدته من /roster نهائياً (محفّز الدفاع الثاني).
  /// يُستدعى بعد expelDevice/revokeDevice المحليتين مباشرة.
  /// (دفعة 57) قياس سحابي حي لواجهة الإعدادات — بديل عرض ip:port القديم:
  /// حالة قناة SSE، كمون السحابة (رحلة GET خفيفة)، اسم مساحة العمل،
  /// وعدد العمليات المنتظرة في طابور الدفع السحابي.
  Future<Map<String, Object?>> cloudTelemetry() async {
    final t = _cloudTransport;
    final db = await _db;
    var pending = 0;
    try {
      final r = await db.rawQuery(
          "SELECT COUNT(*) c FROM sync_queue WHERE target = 'cloud' "
          "AND status IN ('pending','syncing','failed')");
      pending = (r.first['c'] as int?) ?? 0;
    } catch (_) {}
    String wsName = '';
    try {
      final w = await db.query('workspaces', limit: 1);
      if (w.isNotEmpty) {
        wsName = '${w.first['name'] ?? w.first['id'] ?? ''}';
      }
    } catch (_) {}
    int latencyMs = -1;
    try {
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isNotEmpty) {
        final ws = t?.workspaceId ?? 'default';
        final sw = Stopwatch()..start();
        // (F-1c) مسبار موثّق: roster للقراءة لأعضاء المساحة فقط —
        // الطلب العاري يُرفض 401 فتُظهر «السحابة بطيئة/غير متاحة»
        // رغم أنها تعمل.
        final res = await _authedProbe(
          '${url.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(ws)}/roster.json?shallow=true',
        );
        sw.stop();
        if (res != null && res.statusCode >= 200 && res.statusCode < 300) {
          latencyMs = sw.elapsedMilliseconds;
        }
      }
    } catch (_) {}
    return {
      'sse': t?.isListening ?? false,
      'workspace': wsName,
      'pending': pending,
      'latency_ms': latencyMs,
    };
  }

  /// (دفعة 57 — للمدير فقط) ضغط سجل العمليات السحابي:
  /// يحذف من /workspaces/$ws/operations كل عملية:
  ///   • أقدم من 30 يوماً (بختم خادم فيربيس server_ts)، و
  ///   • مغطاة بلقطة موثّقة (server_ts ≤ snapshotThroughTs المسجلة عند
  ///     آخر createInvite) — المنضمون الجدد يرتوون من اللقطة فلا يحتاجون
  ///     إعادة تشغيل التاريخ القديم.
  /// بدون علامة لقطة مسجلة لا يُحذف شيء (أمان مطلق). يعيد عدد المحذوف.
  Future<int> compactCloudOperations({
    required String backendUrl,
    String workspaceId = 'default',
    Duration olderThan = const Duration(days: 30),
  }) async {
    if (!await repo.isWorkspaceOwner()) return 0;
    final db = await _db;
    final row = await db.query('sync_meta',
        where: 'key = ?',
        whereArgs: ['snapshotThroughTs:$workspaceId'],
        limit: 1);
    final snapTs =
        row.isEmpty ? 0 : (int.tryParse('${row.first['value']}') ?? 0);
    if (snapTs <= 0) return 0; // لا لقطة موثّقة → لا ضغط.
    final cutoff = DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
    // الحد الآمن: الأقدم من (30 يوماً) والمغطى باللقطة معاً.
    final limitTs = snapTs < cutoff ? snapTs : cutoff;
    if (limitTs <= 0) return 0;
    return CloudJoin.compactOperations(
      backendUrl: backendUrl,
      workspaceId: workspaceId,
      throughTsMs: limitTs,
    );
  }

  /// (دفعة 56) «حذف نهائي من السجل»: محو جهاز مطرود محلياً وسحابياً —
  /// devices + مستخدم الظل اليتيم محلياً، وroster/evictions/joinRequest
  /// سحابياً. البطاقة تختفي نهائياً من كل الشاشات.
  Future<void> purgeDeviceRecordEverywhere(String targetDeviceId) async {
    // المحلي أولاً (يرمي عند خرق الشروط: جهاز نشط/مالك) ثم السحابي
    // بأفضل جهد — غياب الشبكة لا يمنع اختفاء البطاقة.
    await repo.purgeDeviceRecord(targetDeviceId);
    try {
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isNotEmpty) {
        final ws =
            _cloudTransport?.workspaceId ?? await repo.activeWorkspaceId();
        await CloudJoin.purgeDeviceRecordFromCloud(
          backendUrl: url,
          deviceId: targetDeviceId,
          workspaceId: ws,
        );
      }
    } catch (_) {}
    try {
      await broadcastRosterChange();
    } catch (_) {}
  }

  /// يبث شاهدة الإقصاء/الحظر في السحابة (`/evictions/{deviceId}`) ويحذف عضوية
  /// الجهاز من السجل السحابي (`/roster`) وفهرس الأجهزة؛ ليُقصى جهاز العضو
  /// فور اتصاله وتُحذف بيانات المجموعة من جهازه.
  Future<void> broadcastEviction(String targetDeviceId,
      {String reason = 'revoked_by_manager'}) async {
    try {
      if (!await repo.canManageGroup()) return;
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isEmpty) return;
      final ws = _cloudTransport?.workspaceId ?? await repo.activeWorkspaceId();
      // (2026-09-22 — قانون الطرد الكامل) الطرد/الحظر يمحو العضو من السجل
      // وعضوية المستخدم وفهرس الأجهزة وطلباته مع بث شاهدة الإقصاء بالسبب المحدد.
      await CloudJoin.expelMemberCompletely(
        repo,
        backendUrl: url,
        deviceId: targetDeviceId,
        workspaceId: ws,
        reason: reason,
      );
      notifyNewOperation();
    } catch (_) {
      // الشبكة غائبة — المصافحة الدورية لدى المستهدف تلتقط الطرد لاحقاً
      // عبر شواهد السحابة أو فحص العضوية عند عودة الاتصال.
    }
  }

  /// (F-1) GET موثّق أفضل جهد مع تجديد توكن واحد عند 401/403 —
  /// يعيد null عند تعذر الشبكة أو غياب هوية سحابية.
  static Future<http.Response?> _authedProbe(String url) async {
    try {
      var token = FirebaseAuthRest.cachedIdToken;
      if (token == null || token.isEmpty) {
        try {
          token = await FirebaseAuthRest.cloudIdToken();
        } catch (_) {}
      }
      if (token == null || token.isEmpty) return null;
      var res = await http
          .get(_withAuthQuery(url, token))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 401 || res.statusCode == 403) {
        final fresh = await FirebaseAuthRest.forceRefreshToken();
        if (fresh != null && fresh.isNotEmpty) {
          res = await http
              .get(_withAuthQuery(url, fresh))
              .timeout(const Duration(seconds: 8));
        }
      }
      return res;
    } catch (_) {
      return null;
    }
  }

  /// (F-1) توقيع أي طلب إلى RTDB بـ `?auth=` — القواعد تشترط auth != null.
  static Uri _withAuthQuery(String url, String token) {
    final uri = Uri.parse(url);
    final q = Map<String, String>.from(uri.queryParameters)..['auth'] = token;
    return uri.replace(queryParameters: q);
  }

  /// إعادة السماح لجهاز محظور: يُزيل وسم الحظر/الطرد المحلي (`revoked_at` /
  /// `expelled_at`) ويعيده مقترناً (`is_paired = 1`)، كما يحذف شاهدة الإقصاء
  /// السحابية من `/evictions/{deviceId}` حتى يتمكن الجهاز من إعادة الربط
  /// والمزامنة دون أن يُقصى مجدداً بسبب شاهدة سابقة.
  Future<void> clearEvictionBroadcast(String targetDeviceId) async {
    try {
      final db = await _db;
      await db.update(
        'devices',
        {
          'revoked_at': '',
          'expelled_at': '',
          'is_paired': 1,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [targetDeviceId],
      );
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isNotEmpty) {
        final ws = _cloudTransport?.workspaceId ?? await repo.activeWorkspaceId();
        final base = url.replaceAll(RegExp(r'/+$'), '');
        final encWs = Uri.encodeComponent(ws);
        final encDev = Uri.encodeComponent(targetDeviceId);
        // (F-1d) حذف موثّق: evictions للكتابة مشروطة auth != null —
        // الطلب العاري يفشل 401 فيبقى شاهد الطرد في السحابة إلى الأبد
        // (يُقرأ صفرياً لكنه يمنع إعادة الربط الفوري بعد الطرد).
        // تجديد توكن واحد عند 401/403 ثم فشل آمن — بلا إعادة محاولة.
        final evUrl = '$base/workspaces/$encWs/evictions/$encDev.json';
        var evToken = FirebaseAuthRest.cachedIdToken;
        if (evToken == null || evToken.isEmpty) {
          try {
            evToken = await FirebaseAuthRest.cloudIdToken();
          } catch (_) {}
        }
        if (evToken != null && evToken.isNotEmpty) {
          var evRes = await http
              .delete(_withAuthQuery(evUrl, evToken))
              .timeout(const Duration(seconds: 10));
          if (evRes.statusCode == 401 || evRes.statusCode == 403) {
            final evFresh = await FirebaseAuthRest.forceRefreshToken();
            if (evFresh != null && evFresh.isNotEmpty) {
              await http
                  .delete(_withAuthQuery(evUrl, evFresh))
                  .timeout(const Duration(seconds: 10));
            }
          }
        }
      }
    } catch (_) {}
  }

  Future<void> broadcastRosterChange() async {
    // توحيد الهوية: ادفع سجل الأجهزة فوراً للسحابة أيضاً حتى يظهر الاسم
    // الجديد على كل الأجهزة المرتبطة سحابياً دون انتظار الدورة (45 ثانية).
    try {
      final t = _cloudTransport;
      if (t != null) {
        await CloudJoin.syncRoster(
          repo,
          await _db,
          backendUrl: t.backendUrl,
          workspaceId: t.workspaceId,
        );
      }
    } catch (_) {}
    notifyNewOperation();
  }

  /// جدولة push فورية (لا تنتظر دورة الـ Timer) — لتسريع Near-Real-Time.
  Timer? _immediate;
  void notifyNewOperation() {
    if (!_started) return;
    _immediate?.cancel();
    // Debounce قصير جدًا (80ms) لتجميع العمليات السريعة مع بقاء المزامنة فورية.
    _immediate = Timer(const Duration(milliseconds: 80), () {
      processQueue();
    });
  }

  Future<SyncSummary> summary() async {
    final q = await _ensureQueue();
    final pending = await q.countPending();
    final failed = await q.countFailed();
    return SyncSummary(pending: pending, failed: failed);
  }

  /// 🔒 (التجربة) هل السحابة محظورة لانتهاء الفترة التجريبية؟
  /// فحص خفيف بكاش داخلي — لا يضرب الشبكة في كل دورة.
  Future<bool> _trialBlocked() async {
    try {
      final t = _cloudTransport;
      if (t == null) return false;
      // مهلة صارمة: فحص معلق (شبكة متجمدة) لا يحبس processQueue —
      // _running يُصفَّر في finally دوماً، لكن بدون مهلة كانت الدورة
      // كلها تبقى عالقة فيبدو المحرك «مجمداً» رغم تجديد الاشتراك.
      return await SubscriptionGuard.isBlocked(repo,
              backendUrl: t.backendUrl, workspaceId: t.workspaceId)
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      return false; // الشك لصالح الاستمرار — الفحص التالي يحسم.
    }
  }

  Future<void> processQueue() async {
    if (_running) return;
    _running = true;
    // (3.71.0) تشخيص: سهم الإرسال يومض أثناء الدفعة النشطة.
    SyncDiagnostics.instance.pushStarted();
    try {
      // 🔒 انتهاء التجربة يجمّد الدفع السحابي كلياً (العمل المحلي يستمر).
      if (await _trialBlocked()) return;
      final db = await _db;
      final q = await _ensureQueue();
      // 🔒 التحقق الصارم من صلاحيات العضو ومساحة العمل قبل دفع أي بيانات
      final activeWs = await repo.activeWorkspaceId();
      final isExpelled = await repo.amIExpelled();
      final user = await repo.deviceAssignedUser();
      final targetWs = _cloudTransport?.workspaceId ?? activeWs;
      final access = await q.verifyMemberAccess(
        activeWorkspaceId: activeWs,
        expectedWorkspaceId: targetWs,
        userRole: user?.role.code,
        userPermissions: user?.permissions.entries
            .where((e) => e.value)
            .map((e) => e.key)
            .toList(),
        isExpelledOrRevoked: isExpelled,
        isPushOperation: true,
      );
      if (access['allowed'] != true) {
        if (isExpelled) {
          unawaited(_checkMemberPermissions());
        }
        SyncDiagnostics.instance.recordPushError(
          access['message'] ?? 'المزامنة متوقفة: المستخدم أو المنشأة غير مصرح بها.',
          context: 'processQueue → verifyMemberAccess',
        );
        return;
      }

      // السحابة أولاً: عند نجاح رفع العملية للسحابة تُعلَّم synced=1،
      // فيعتبرها هدف LAN (في نفس الدورة) مُسلَّمة عبر السحابة للأجهزة
      // غير القابلة للوصول محلياً — بدل بقائها awaiting-offline-peers.
      final ordered = List<SyncTransport>.of(_transports)
        ..sort((a, b) {
          if (a.targetId == b.targetId) return 0;
          if (a.targetId == SyncTarget.cloud) return -1;
          if (b.targetId == SyncTarget.cloud) return 1;
          return 0;
        });
      for (final t in ordered) {
        List<Map<String, Object?>> rows;
        try {
          rows = await q
              .pickPending(limit: 50, target: t.targetId)
              .timeout(const Duration(seconds: 10));
        } catch (_) {
          continue;
        }
        const subBatchSize = 4;
        for (var i = 0; i < rows.length; i += subBatchSize) {
          final end =
              (i + subBatchSize < rows.length) ? i + subBatchSize : rows.length;
          final chunkRows = rows.sublist(i, end);
          final prepared = <({
            int qid,
            SyncOperation op,
            String entityTable,
            String entityId,
          })>[];

          for (final r in chunkRows) {
            final qid = r['id'] as int;
            final opId = r['operation_id'] as String;
            try {
              await q.markSyncing(qid).timeout(const Duration(seconds: 5));
            } catch (_) {
              continue; // Do not send without a durable queue state.
            }
            try {
              final opRows = await db
                  .query(
                    'operations',
                    where: 'id = ?',
                    whereArgs: [opId],
                    limit: 1,
                  )
                  .timeout(const Duration(seconds: 5));
              if (opRows.isEmpty) {
                try {
                  await q.markSynced(qid).timeout(const Duration(seconds: 3));
                } catch (_) {}
                continue;
              }
              final op = SyncOperation.fromMap(opRows.first);
              final entityTable = switch (op.entityType) {
                EntityKind.tx => 'transactions',
                EntityKind.account => 'accounts',
                EntityKind.item => 'items',
                EntityKind.itemCategory => 'item_categories',
                EntityKind.stockMove => 'stock_moves',
                EntityKind.voucher => 'vouchers',
                EntityKind.user => 'users',
                EntityKind.currency => 'currencies',
                EntityKind.setting => 'settings',
                EntityKind.section => 'sections',
                EntityKind.unknown => '(غير معروف)',
                EntityKind.category => 'categories',
                EntityKind.conversation => 'conversations',
                EntityKind.message => 'messages',
                EntityKind.userPermission => 'user_permissions',
              };
              final entityId = op.entityId;
              if (entityTable == 'transactions') {
                try {
                  await db
                      .update(
                        'transactions',
                        {'sync_state': 'syncing'},
                        where: 'id = ?',
                        whereArgs: [entityId],
                      )
                      .timeout(const Duration(seconds: 3));
                } catch (_) {}
              }
              prepared.add((
                qid: qid,
                op: op,
                entityTable: entityTable,
                entityId: entityId,
              ));
            } catch (e) {
              try {
                await q.markFailed(qid, e).timeout(const Duration(seconds: 3));
              } catch (_) {}
            }
          }

          if (prepared.isEmpty) continue;

          final seenEntities = <String>{};
          var canRunParallel =
              t.targetId == SyncTarget.cloud && prepared.length > 1;
          for (final item in prepared) {
            final key = '${item.entityTable}:${item.entityId}';
            if (!seenEntities.add(key)) {
              canRunParallel = false;
              break;
            }
          }

          if (canRunParallel) {
            final results = await Future.wait(
              prepared.map((item) async {
                try {
                  await t.push(item.op).timeout(const Duration(seconds: 20));
                  return (item: item, error: null as Object?);
                } catch (e) {
                  return (item: item, error: e);
                }
              }),
            );
            for (final res in results) {
              final item = res.item;
              final err = res.error;
              if (err == null) {
                try {
                  await q
                      .markSynced(item.qid)
                      .timeout(const Duration(seconds: 3));
                } catch (_) {}
                if (item.entityTable == 'transactions') {
                  try {
                    await db
                        .update(
                          'transactions',
                          {'sync_state': 'synced'},
                          where: 'id = ?',
                          whereArgs: [item.entityId],
                        )
                        .timeout(const Duration(seconds: 3));
                  } catch (_) {}
                }
              } else {
                SyncDiagnostics.instance.recordPushError(
                  err,
                  context:
                      'processQueue → transport.push ← جدول ${item.entityTable}',
                );
                try {
                  await q
                      .markFailed(item.qid, err)
                      .timeout(const Duration(seconds: 3));
                } catch (_) {}
                if (item.entityTable == 'transactions') {
                  try {
                    await db
                        .update(
                          'transactions',
                          {'sync_state': 'failed'},
                          where: 'id = ?',
                          whereArgs: [item.entityId],
                        )
                        .timeout(const Duration(seconds: 3));
                  } catch (_) {}
                }
              }
            }
          } else {
            for (final item in prepared) {
              try {
                await t.push(item.op).timeout(const Duration(seconds: 20));
                try {
                  await q
                      .markSynced(item.qid)
                      .timeout(const Duration(seconds: 3));
                } catch (_) {}
                if (item.entityTable == 'transactions') {
                  try {
                    await db
                        .update(
                          'transactions',
                          {'sync_state': 'synced'},
                          where: 'id = ?',
                          whereArgs: [item.entityId],
                        )
                        .timeout(const Duration(seconds: 3));
                  } catch (_) {}
                }
              } catch (e) {
                SyncDiagnostics.instance.recordPushError(
                  e,
                  context:
                      'processQueue → transport.push ← جدول ${item.entityTable}',
                );
                try {
                  await q
                      .markFailed(item.qid, e)
                      .timeout(const Duration(seconds: 3));
                } catch (_) {}
                if (item.entityTable == 'transactions') {
                  try {
                    await db
                        .update(
                          'transactions',
                          {'sync_state': 'failed'},
                          where: 'id = ?',
                          whereArgs: [item.entityId],
                        )
                        .timeout(const Duration(seconds: 3));
                  } catch (_) {}
                }
              }
            }
          }
        }
      }
    } finally {
      _running = false;
      // (3.71.0) تشخيص: عدّادات صادقة من sync_queue ثم نتيجة الدفعة.
      try {
        await SyncDiagnostics.instance.refreshQueue(await _db);
      } catch (_) {}
      SyncDiagnostics.instance.pushFinished();
      try {
        onSyncActivity?.call();
      } catch (_) {}
      // فحص حالة الخطر فور انتهاء الدورة: نجاح الدفع يخفي البانر لحظياً،
      // وحدوث خلل حقيقي غير شبكي يُظهر التنبيه دون انتظار.
      try {
        await _checkDangerState();
      } catch (_) {}
    }
  }
}

class SyncSummary {
  final int pending;
  final int failed;
  const SyncSummary({required this.pending, required this.failed});
}
