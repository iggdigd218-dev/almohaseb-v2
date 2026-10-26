// (2026-09-28) حارس تطابق الكتالوج (حسابات، أصناف، أقسام) عبر كافة الأجهزة.
//
// يضمن التحقق الدوري الصارم من تطابق الحسابات والأصناف والأقسام بين جميع الأجهزة
// المرتبطة بمساحة العمل، وإظهار تحذير صريح وبارز في مؤشر المزامنة عند أي تفاوت.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../repository.dart';
import 'package:sqflite/sqflite.dart';
import 'cloud_firebase_transport.dart';
import 'cloud_join.dart';
import 'conflict_resolver.dart';
import 'firebase_auth_service.dart';
import 'sync_activity.dart';
import 'sync_diagnostics.dart';

/// بصمة ملخصة دقيقة للكتالوج (حسابات، أصناف، أقسام، فئات).
class CatalogDigest {
  final int accountsCount;
  final int itemsCount;
  final int sectionsCount;
  final int categoriesCount;
  final String hash;
  final DateTime updatedAt;

  const CatalogDigest({
    required this.accountsCount,
    required this.itemsCount,
    required this.sectionsCount,
    required this.categoriesCount,
    required this.hash,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'accounts': accountsCount,
        'items': itemsCount,
        'sections': sectionsCount,
        'categories': categoriesCount,
        'hash': hash,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory CatalogDigest.fromMap(Map<dynamic, dynamic> m) => CatalogDigest(
        accountsCount: ((m['accounts'] ?? 0) as num).toInt(),
        itemsCount: ((m['items'] ?? 0) as num).toInt(),
        sectionsCount: ((m['sections'] ?? 0) as num).toInt(),
        categoriesCount: ((m['categories'] ?? 0) as num).toInt(),
        hash: '${m['hash'] ?? ''}',
        updatedAt: DateTime.tryParse('${m['updated_at'] ?? ''}') ??
            DateTime.now(),
      );

  bool matches(CatalogDigest other) =>
      accountsCount == other.accountsCount &&
      itemsCount == other.itemsCount &&
      sectionsCount == other.sectionsCount &&
      categoriesCount == other.categoriesCount &&
      hash == other.hash;

  List<String> diff(CatalogDigest other) {
    final d = <String>[];
    if (itemsCount != other.itemsCount) {
      d.add('الأصناف (محلي: $itemsCount | طرف آخر: ${other.itemsCount})');
    }
    if (accountsCount != other.accountsCount) {
      d.add('الحسابات (محلي: $accountsCount | طرف آخر: ${other.accountsCount})');
    }
    if (sectionsCount != other.sectionsCount) {
      d.add('الأقسام (محلي: $sectionsCount | طرف آخر: ${other.sectionsCount})');
    }
    if (categoriesCount != other.categoriesCount) {
      d.add('الفئات (محلي: $categoriesCount | طرف آخر: ${other.categoriesCount})');
    }
    if (d.isEmpty && hash != other.hash) {
      d.add('تفاوت في بيانات الكتالوج');
    }
    return d;
  }
}

class CatalogSyncGuard {
  CatalogSyncGuard._();

  /// حساب البصمة المحلية الحتمية لقاعدة البيانات (باستبعاد المحذوف قطعياً).
  static Future<CatalogDigest> computeLocalDigest(Repo repo) async {
    final db = await repo.database;

    // 1. الحسابات النشطة غير المحذوفة
    final accRows = await db.query(
      'accounts',
      columns: ['id', 'name'],
      where: "archived = 0 AND (deleted_at IS NULL OR TRIM(deleted_at) = '')",
      orderBy: 'id ASC',
    );

    // 2. الأصناف النشطة غير المحذوفة
    final itemRows = await db.query(
      'items',
      columns: ['id', 'name', 'sku'],
      where:
          "(is_deleted = 0 OR is_deleted IS NULL) AND (deleted_at IS NULL OR TRIM(deleted_at) = '' OR TRIM(deleted_at) = 'null')",
      orderBy: 'id ASC',
    );

    // 3. الأقسام النشطة
    final secRows = await db.query(
      'sections',
      columns: ['id', 'name'],
      where: "(deleted_at IS NULL OR TRIM(deleted_at) = '')",
      orderBy: 'id ASC',
    );

    // 4. الفئات النشطة
    final catRows = await db.query(
      'item_categories',
      columns: ['id', 'name'],
      where: "(deleted_at IS NULL OR TRIM(deleted_at) = '')",
      orderBy: 'id ASC',
    );

    final sb = StringBuffer();
    for (final r in accRows) {
      sb.write('A:${r['id']}:${r['name']};');
    }
    for (final r in itemRows) {
      sb.write('I:${r['id']}:${r['name']}:${r['sku']};');
    }
    for (final r in secRows) {
      sb.write('S:${r['id']}:${r['name']};');
    }
    for (final r in catRows) {
      sb.write('C:${r['id']}:${r['name']};');
    }

    final bytes = utf8.encode(sb.toString());
    final digest = sha256.convert(bytes).toString();

    return CatalogDigest(
      accountsCount: accRows.length,
      itemsCount: itemRows.length,
      sectionsCount: secRows.length,
      categoriesCount: catRows.length,
      hash: digest,
      updatedAt: DateTime.now(),
    );
  }

  /// التحقق السحابي الشامل ونشر البصمة ومطابقة الأجهزة الأخرى.
  static Future<void> verifyAndPublish({
    required Repo repo,
    required CloudFirebaseTransport transport,
  }) async {
    try {
      final mode = await repo.workspaceMode();
      if (mode == 'standalone') {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        return;
      }

      var local = await computeLocalDigest(repo);
      final ourId = repo.requireDeviceId;
      final backendUrl = transport.backendUrl;
      final ws = transport.workspaceId;
      final root =
          '${backendUrl.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(ws)}';
      final token = await FirebaseAuthRest.cloudIdToken();

      // 1. نشر البصمة المحلية إلى السحابة
      final putUri = Uri.parse(
              '$root/catalog_digest/${Uri.encodeComponent(ourId)}.json')
          .replace(queryParameters: token != null ? {'auth': token} : null);
      try {
        await http
            .put(
              putUri,
              body: jsonEncode(local.toMap()),
              headers: {'Content-Type': 'application/json'},
            )
            .timeout(const Duration(seconds: 5));
      } catch (e) {
        debugPrint('CatalogSyncGuard: failed to put digest: $e');
      }

      // 2. قراءة بصمات أجهزة المنشأة الأخرى
      final getUri = Uri.parse('$root/catalog_digest.json')
          .replace(queryParameters: token != null ? {'auth': token} : null);
      Map<String, dynamic>? allDigests;
      try {
        final res =
            await http.get(getUri).timeout(const Duration(seconds: 5));
        if (res.statusCode == 200 &&
            res.body.trim().isNotEmpty &&
            res.body.trim() != 'null') {
          final decoded = jsonDecode(res.body);
          if (decoded is Map) {
            allDigests = Map<String, dynamic>.from(decoded);
          }
        }
      } catch (e) {
        debugPrint('CatalogSyncGuard: failed to get digests: $e');
      }

      if (allDigests == null || allDigests.isEmpty) {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        return;
      }

      // (2026-09-28) قاعدة سيادية صارمة:
      // جهاز المدير هو المصدر المعتمد والأصيل لكافة بيانات المنشأة —
      // غياب أي عضو لفترة طويلة أو قصيرة لا يُعد مشكلة ولا يُظهر أي تحذير إطلاقاً.
      final isOwner = await repo.isWorkspaceOwner();
      if (isOwner) {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        // نشر لقطة محدثة للكتالوج والحسابات ليتمكن الأعضاء من معالجة أي حسابات أو أصناف مؤقتة
        try {
          final snap = await CloudJoin.buildWorkspaceSnapshot(repo);
          final snapPayload = {
            'createdAt': DateTime.now().toIso8601String(),
            'hostDeviceId': ourId,
            'compacted_through_ts': DateTime.now().millisecondsSinceEpoch,
            'data': snap,
          };
          await http
              .put(
                Uri.parse('$root/snapshot.json').replace(
                    queryParameters: token != null ? {'auth': token} : null),
                body: jsonEncode(snapPayload),
                headers: {'Content-Type': 'application/json'},
              )
              .timeout(const Duration(seconds: 10));
        } catch (_) {}
        return;
      }

      // ترميم أي حسابات أو أصناف مؤقتة (قيد المزامنة) لدى العضو
      try {
        final healedCount = await healStubEntities(
          repo: repo,
          backendUrl: backendUrl,
          workspaceId: ws,
        );
        if (healedCount > 0) {
          local = await computeLocalDigest(repo);
        }
      } catch (_) {}

      // أثناء المزامنة النشطة أو وجود عمليات في طابور الإرسال، لا يُرفع تحذير مؤقت
      final diagSnap = SyncDiagnostics.instance.snapshot;
      if (diagSnap.pulling || diagSnap.pushing || diagSnap.pendingCount > 0) {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        return;
      }

      // 3. مقارنة بصمة هذا الجهاز العضو مع بصمة جهاز المدير المعتمدة فقط
      final db = await repo.database;
      final ownerDevRows = await db.query('devices',
          columns: ['id'], where: 'is_owner = 1', limit: 1);
      final managerDeviceId = ownerDevRows.isNotEmpty
          ? '${ownerDevRows.first['id']}'
          : (await repo.settings())['hostDeviceId'] ?? '';

      if (managerDeviceId.isEmpty || !allDigests.containsKey(managerDeviceId)) {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        return;
      }

      final managerRaw = allDigests[managerDeviceId];
      if (managerRaw is! Map) {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        return;
      }

      final managerDigest = CatalogDigest.fromMap(managerRaw);

      if (local.matches(managerDigest)) {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        return;
      }

      bool hasMismatch = true;
      String? mismatchDetail;

      // (Delta-Sync + Snapshot Healing) معالجة ذكية حتى للأجهزة العائدة بعد غياب طويل (> 72 ساعة)
      try {
        final applied = await transport.pull(
          resolver: ConflictResolver(),
          forceFullSync: false,
        );
        final healedAfter = await healStubEntities(
          repo: repo,
          backendUrl: backendUrl,
          workspaceId: ws,
          forceCatalogCheck: true,
        );
        if (applied > 0 || healedAfter > 0) {
          final reconciled = await computeLocalDigest(repo);
          local = reconciled;
          // رفع البصمة المعالجة المحدثة
          await http.put(
            putUri,
            body: jsonEncode(local.toMap()),
            headers: {'Content-Type': 'application/json'},
          ).timeout(const Duration(seconds: 5));
        }
      } catch (_) {}

      // غياب تحديث بصمة المدير لأكثر من 3 أيام بعد محاولة الإصلاح لا يُظهر تحذيراً مزعجاً
      if (DateTime.now().difference(managerDigest.updatedAt).inHours > 72 &&
          local.matches(managerDigest)) {
        SyncDiagnostics.instance.setCatalogMismatch(false);
        return;
      }

      final diag = SyncDiagnostics.instance.snapshot;
      final isActivelyCatchingUp =
          diag.pushing || diag.pulling || diag.pendingCount > 0;

      if (local.matches(managerDigest)) {
        hasMismatch = false;
      } else if (isActivelyCatchingUp ||
          DateTime.now().difference(managerDigest.updatedAt).inHours > 72) {
        // العضو قيد استكمال رفع أو سحب عملياته المتراكمة — لا نطلق إنذاراً كاذباً
        hasMismatch = false;
      } else {
        final diffs = local.diff(managerDigest);
        mismatchDetail =
            'تفاوت مع المدير (${diffs.join('، ')}) — جارٍ استكمال المزامنة الذاتية...';
      }

      if (hasMismatch) {
        SyncDiagnostics.instance
            .setCatalogMismatch(true, details: mismatchDetail);
      } else {
        SyncDiagnostics.instance.setCatalogMismatch(false);
      }
    } catch (e) {
      debugPrint('CatalogSyncGuard: verifyAndPublish error: $e');
    }
  }

  /// فحص وترميم أي حسابات أو أصناف مؤقتة (قيد المزامنة) أو مفقودة ناتجة عن وصول فواتير قبل أصل الحساب
  /// أو غياب الجهاز لأيام وتعرّض سجل العمليات للضغط الدوري (compacted_through_ts).
  static Future<int> healStubEntities({
    required Repo repo,
    required String backendUrl,
    required String workspaceId,
    bool forceCatalogCheck = false,
  }) async {
    final db = await repo.database;
    final stubAccounts = await db.query(
      'accounts',
      columns: ['id', 'name'],
      where: "name LIKE 'حساب مؤقت%' OR name LIKE '%قيد المزامنة%'",
    );
    final stubItems = await db.query(
      'items',
      columns: ['id', 'name'],
      where: "name LIKE 'صنف مؤقت%'",
    );
    final stubSections = await db.query(
      'sections',
      columns: ['id', 'name'],
      where: "name LIKE 'قسم مؤقت%'",
    );
    final stubCategories = await db.query(
      'item_categories',
      columns: ['id', 'name'],
      where: "name LIKE 'تصنيف مؤقت%'",
    );

    final totalAccounts = Sqflite.firstIntValue(
          await db.rawQuery(
              "SELECT COUNT(*) FROM accounts WHERE (deleted_at IS NULL OR TRIM(deleted_at) = '')"),
        ) ??
        0;

    // فحص ما إذا كان الجهاز عائداً بعد غياب طويل وتم ضغط العمليات الأقدم من مؤشره
    int localCursor = 0;
    int lastCheckedCompactedTs = 0;
    try {
      final curRows = await db.query(
        'sync_meta',
        where: 'key = ?',
        whereArgs: ['last_synced_cursor:$workspaceId'],
        limit: 1,
      );
      if (curRows.isNotEmpty) {
        localCursor = int.tryParse('${curRows.first['value'] ?? '0'}') ?? 0;
      }
      final chkRows = await db.query(
        'sync_meta',
        where: 'key = ?',
        whereArgs: ['healedCompactedTs:$workspaceId'],
        limit: 1,
      );
      if (chkRows.isNotEmpty) {
        lastCheckedCompactedTs =
            int.tryParse('${chkRows.first['value'] ?? '0'}') ?? 0;
      }
    } catch (_) {}

    if (!forceCatalogCheck &&
        stubAccounts.isEmpty &&
        stubItems.isEmpty &&
        stubSections.isEmpty &&
        stubCategories.isEmpty &&
        totalAccounts > 1 &&
        lastCheckedCompactedTs > 0) {
      return 0;
    }

    final root =
        '${backendUrl.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(workspaceId)}';
    Map<String, dynamic>? snapData;
    var remoteCompactedTs = 0;
    for (final snapName in const [
      'snapshot.json',
      'joinSnapshot.json',
      'backup.json'
    ]) {
      try {
        final rec = await CloudJoin.getJson('$root/$snapName');
        if (rec != null) {
          remoteCompactedTs =
              (rec['compacted_through_ts'] as num?)?.toInt() ?? 0;
          if (rec['payload'] is Map &&
              (rec['payload'] as Map)['data'] is Map) {
            snapData = Map<String, dynamic>.from(
                (rec['payload'] as Map)['data'] as Map);
            break;
          } else if (rec['data'] is Map) {
            snapData = Map<String, dynamic>.from(rec['data'] as Map);
            break;
          } else if (rec['accounts'] != null || rec['items'] != null) {
            snapData = Map<String, dynamic>.from(rec);
            break;
          }
        }
      } catch (_) {}
    }

    if (snapData == null || snapData.isEmpty) return 0;

    final isCompactedGap = remoteCompactedTs > 0 &&
        (localCursor == 0 || localCursor < remoteCompactedTs) &&
        remoteCompactedTs > lastCheckedCompactedTs;

    if (!forceCatalogCheck &&
        !isCompactedGap &&
        stubAccounts.isEmpty &&
        stubItems.isEmpty &&
        stubSections.isEmpty &&
        stubCategories.isEmpty &&
        totalAccounts > 1) {
      return 0;
    }

    var healed = 0;
    final nowIso = DateTime.now().toIso8601String();

    // 1. ترميم الأقسام
    if (snapData['sections'] is List) {
      final secList = (snapData['sections'] as List).whereType<Map>();
      final tableInfo = await db.rawQuery('PRAGMA table_info(sections)');
      final validCols = {for (final col in tableInfo) col['name'] as String};
      for (final s in secList) {
        final sMap = <String, Object?>{};
        s.forEach((k, v) {
          if (validCols.contains(k.toString())) sMap[k.toString()] = v as Object?;
        });
        final sid = sMap['id'];
        if (sid == null) continue;
        final ex = await db.query('sections',
            where: 'id = ?', whereArgs: [sid], limit: 1);
        if (ex.isEmpty) {
          await db.insert('sections', sMap,
              conflictAlgorithm: ConflictAlgorithm.replace);
          healed++;
        } else if ('${ex.first['name'] ?? ''}'.contains('قسم مؤقت') ||
            (forceCatalogCheck && '${ex.first['name'] ?? ''}' != '${sMap['name'] ?? ''}')) {
          await db.update('sections', sMap, where: 'id = ?', whereArgs: [sid]);
          healed++;
        }
      }
    }

    // 2. ترميم الفئات
    if (snapData['item_categories'] is List) {
      final catList = (snapData['item_categories'] as List).whereType<Map>();
      final tableInfo = await db.rawQuery('PRAGMA table_info(item_categories)');
      final validCols = {for (final col in tableInfo) col['name'] as String};
      for (final c in catList) {
        final cMap = <String, Object?>{};
        c.forEach((k, v) {
          if (validCols.contains(k.toString())) cMap[k.toString()] = v as Object?;
        });
        final cid = cMap['id'];
        if (cid == null) continue;
        final ex = await db.query('item_categories',
            where: 'id = ?', whereArgs: [cid], limit: 1);
        if (ex.isEmpty) {
          await db.insert('item_categories', cMap,
              conflictAlgorithm: ConflictAlgorithm.replace);
          healed++;
        } else if ('${ex.first['name'] ?? ''}'.contains('تصنيف مؤقت') ||
            (forceCatalogCheck && '${ex.first['name'] ?? ''}' != '${cMap['name'] ?? ''}')) {
          await db.update('item_categories', cMap,
              where: 'id = ?', whereArgs: [cid]);
          healed++;
        }
      }
    }

    // 3. ترميم الحسابات والعملاء
    if (snapData['accounts'] is List) {
      final accList = (snapData['accounts'] as List).whereType<Map>();
      final tableInfo = await db.rawQuery('PRAGMA table_info(accounts)');
      final validCols = {for (final col in tableInfo) col['name'] as String};

      for (final a in accList) {
        final aMap = <String, Object?>{};
        a.forEach((k, v) {
          if (validCols.contains(k.toString())) aMap[k.toString()] = v as Object?;
        });
        final aid = aMap['id'];
        if (aid == null) continue;

        final ex = await db.query('accounts',
            where: 'id = ?', whereArgs: [aid], limit: 1);
        if (ex.isEmpty) {
          aMap['updated_at'] = nowIso;
          await db.insert('accounts', aMap,
              conflictAlgorithm: ConflictAlgorithm.replace);
          healed++;
        } else {
          final curName = '${ex.first['name'] ?? ''}';
          if (curName.contains('حساب مؤقت') ||
              curName.contains('قيد المزامنة') ||
              (forceCatalogCheck && curName != '${aMap['name'] ?? ''}')) {
            aMap['updated_at'] = nowIso;
            await db.update('accounts', aMap,
                where: 'id = ?', whereArgs: [aid]);
            healed++;
          }
        }
      }
    }

    // 4. ترميم الأصناف
    if (snapData['items'] is List) {
      final itemList = (snapData['items'] as List).whereType<Map>();
      final tableInfo = await db.rawQuery('PRAGMA table_info(items)');
      final validCols = {for (final col in tableInfo) col['name'] as String};

      for (final itm in itemList) {
        final itmMap = <String, Object?>{};
        itm.forEach((k, v) {
          if (validCols.contains(k.toString())) itmMap[k.toString()] = v as Object?;
        });
        final itmId = itmMap['id'];
        if (itmId == null) continue;

        final ex = await db.query('items',
            where: 'id = ?', whereArgs: [itmId], limit: 1);
        if (ex.isEmpty) {
          await db.insert('items', itmMap,
              conflictAlgorithm: ConflictAlgorithm.replace);
          healed++;
        } else {
          final curName = '${ex.first['name'] ?? ''}';
          if (curName.contains('صنف مؤقت') ||
              (forceCatalogCheck &&
                  (curName != '${itmMap['name'] ?? ''}' ||
                      '${ex.first['sku'] ?? ''}' != '${itmMap['sku'] ?? ''}'))) {
            final patchMap = Map<String, Object?>.from(itmMap);
            if (!curName.contains('صنف مؤقت')) {
              // الحفاظ على الكمية المحلية الحالية للصنف الموجود
              patchMap.remove('quantity');
            }
            await db.update('items', patchMap,
                where: 'id = ?', whereArgs: [itmId]);
            healed++;
          }
        }
      }
    }

    // 5. إذا كان الجهاز عائداً بعد غياب طويل وتجاوزت اللقطة مؤشره المحلي (isCompactedGap)،
    // نُرمّم الفواتير وبنودها والسندات وحركات المخزون المفقودة من اللقطة دون المساس بالموجود.
    if (isCompactedGap) {
      for (final table in const [
        'transactions',
        'transaction_items',
        'vouchers',
        'stock_moves',
      ]) {
        if (snapData[table] is List) {
          try {
            final rows = (snapData[table] as List).whereType<Map>();
            final tableInfo = await db.rawQuery('PRAGMA table_info($table)');
            final validCols = {
              for (final col in tableInfo) col['name'] as String
            };
            for (final r in rows) {
              final rMap = <String, Object?>{};
              r.forEach((k, v) {
                if (validCols.contains(k.toString())) {
                  rMap[k.toString()] = v as Object?;
                }
              });
              final rid = rMap['id'];
              if (rid == null) continue;
              final inserted = await db.insert(
                table,
                rMap,
                conflictAlgorithm: ConflictAlgorithm.ignore,
              );
              if (inserted > 0) healed++;
            }
          } catch (_) {}
        }
      }
      try {
        await db.insert(
          'sync_meta',
          {
            'key': 'healedCompactedTs:$workspaceId',
            'value': '$remoteCompactedTs',
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } catch (_) {}
    }

    if (healed > 0) {
      try {
        SyncActivityBus.instance.ping();
      } catch (_) {}
    }

    return healed;
  }

  /// فحص مباشر بين مستودعين محليين (مخصص للاختبارات والمطابقة المباشرة).
  static Future<bool> verifyDirect(Repo repoA, Repo repoB) async {
    final digestA = await computeLocalDigest(repoA);
    final digestB = await computeLocalDigest(repoB);
    final match = digestA.matches(digestB);
    if (!match) {
      final diffs = digestA.diff(digestB);
      final details =
          'تحذير مزامنة: عدم تطابق بين الأجهزة في ${diffs.join('، ')}';
      SyncDiagnostics.instance.setCatalogMismatch(true, details: details);
    } else {
      SyncDiagnostics.instance.setCatalogMismatch(false);
    }
    return match;
  }
}
