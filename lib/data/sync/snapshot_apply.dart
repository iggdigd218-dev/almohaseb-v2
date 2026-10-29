// (دفعة 58) تطبيق لقطة الانضمام — استُخرجت من LanSyncService المحذوف.
// تُستخدم حصرياً في مسار الانضمام السحابي (CloudJoin.join/completeApprovedJoin):
// تمسح بيانات الجهاز المحلية كاملة وتستبدلها بنسخة المجموعة.
import 'package:sqflite/sqflite.dart';

import '../../core/database.dart';
import '../../core/media_paths.dart';
import '../../core/secret_store.dart';

class SnapshotApply {
  static const Set<String> _deviceColumns = {
    'id',
    'workspace_id',
    'name',
    'platform',
    'app_version',
    'last_seen_at',
    'last_sync_at',
    'pair_token',
    'pair_token_exp',
    'auth_secret',
    'revoked_at',
    'expelled_at',
    'user_id',
    'paired_by',
    'is_paired',
    'is_owner',
    'created_at',
    'updated_at',
  };

  /// يُطبّق لقطة البيانات القادمة من المضيف على الجهاز العضو (يمسح القديم ويستبدله).
  static Future<void> applySnapshot(
    Future<Database> Function() dbProvider,
    String ourDeviceId,
    Map<String, Object?> snap,
  ) async {
    var db = await dbProvider();
    bool isClosed = false;
    try {
      isClosed = !db.isOpen;
    } catch (_) {
      isClosed = false;
    }
    if (isClosed) {
      final path = db.path;
      if (path.isNotEmpty &&
          path != ':memory:' &&
          !path.contains('in_memory')) {
        try {
          db = await databaseFactory.openDatabase(
            path,
            options: OpenDatabaseOptions(
              version: AppDatabase.schemaVersion,
              onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            ),
          );
          await AppDatabase.ensureFullSchema(db);
        } catch (_) {
          db = await AppDatabase.instance.database;
        }
      } else {
        db = await AppDatabase.instance.database;
      }
    }
    await db.transaction((txn) async {
      final nowIso = DateTime.now().toIso8601String();
      final snapWsList =
          (snap['workspaces'] as List?)?.whereType<Map>().toList();
      final realWs = snapWsList?.firstWhere(
          (w) =>
              '${w['id'] ?? ''}' != 'default' &&
              '${w['id'] ?? ''}'.trim().isNotEmpty,
          orElse: () => snapWsList.firstOrNull ?? const {});
      final wsId = '${realWs?['id'] ?? ''}'.trim().isNotEmpty
          ? '${realWs?['id']}'.trim()
          : 'default';

      final knownDevices =
          await txn.query('devices', columns: ['id', 'auth_secret']);
      final knownSecrets = {
        for (final d in knownDevices) d['id']: d['auth_secret']
      };
      // 1) مسح البيانات المحلية (نُبقي devices/workspaces/sync_meta جزئياً).
      // «حذف كامل»: يشمل أيضاً القوالب والإشعارات وإعدادات العمل القديمة —
      // لا يبقى من بيانات الجهاز القديمة أي أثر بعد الانضمام.
      const clearTables = [
        'sections',
        'templates',
        'notifications',
        'accounts',
        'transactions',
        'transaction_items',
        'vouchers',
        'currencies',
        'categories',
        'item_categories',
        'items',
        'stock_moves',
        'conversations',
        'messages',
        'users',
        'trash',
        'activity',
        'operations',
        'sync_queue',
      ];
      for (final t in clearTables) {
        await txn.delete(t);
      }
      // نحذف سجلات الأجهزة الأخرى ونُبقي سجلنا وسجل المضيف.
      await txn.delete('devices', where: 'id <> ?', whereArgs: [ourDeviceId]);

      // ضمان وجود سجل المنشأة الأب أولاً قبل أي إدراج أو تعديل في الجداول الفرعية
      await AppDatabase.ensureWorkspaceRow(
        txn,
        wsId,
        name: '${realWs?['name'] ?? realWs?['title'] ?? 'متجري'}',
      );

      final knownSectionIds = <Object?>{
        for (final r in await txn.query('sections', columns: ['id'])) r['id'],
      };
      final knownCategoryIds = <Object?>{
        for (final r in await txn.query('item_categories', columns: ['id'])) r['id'],
      };
      final knownItemIds = <Object?>{
        for (final r in await txn.query('items', columns: ['id'])) r['id'],
      };
      final embeddedTxItems = <Map>[];

      // 2) نسخ الجداول من اللقطة.
      Future<void> insertAll(String table) async {
        final raw = snap[table];
        if (raw is! List) return;
        final tableInfo = await txn.rawQuery('PRAGMA table_info($table)');
        final cols = {for (final c in tableInfo) c['name'] as String};
        if (cols.isEmpty) return;

        for (final r in raw) {
          if (r is! Map) continue;
          try {
            final map = <String, Object?>{};
            r.forEach((k, v) {
              if (k is String) map[k] = v as Object?;
            });
            // استخراج سطور الفاتورة المضمّنة داخل transactions إن وُجدت
            if (table == 'transactions' && map['items'] is List) {
              final rawItems = map.remove('items');
              if (rawItems is List &&
                  (snap['transaction_items'] == null ||
                      (snap['transaction_items'] as List).isEmpty)) {
                embeddedTxItems.addAll(rawItems.whereType<Map>());
              }
            }
            if (table == 'workspaces') {
              final wId = '${map['id'] ?? ''}'.trim();
              if (wId.isEmpty) continue;
              map['id'] = wId;
              final title = map.remove('title');
              if ('${map['name'] ?? ''}'.trim().isEmpty) {
                map['name'] = '${title ?? 'متجري'}';
              }
              map['owner_google_id'] ??= '';
              map['owner_email'] ??= '';
              map['owner_name'] ??= '';
              if ('${map['created_at'] ?? ''}'.trim().isEmpty) {
                map['created_at'] = nowIso;
              }
              if ('${map['updated_at'] ?? ''}'.trim().isEmpty) {
                map['updated_at'] = nowIso;
              }
            }
            if (table == 'sections') {
              if ('${map['name'] ?? ''}'.trim().isEmpty) map['name'] = 'قسم';
              if ('${map['created_at'] ?? ''}'.trim().isEmpty) map['created_at'] = nowIso;
              if ('${map['updated_at'] ?? ''}'.trim().isEmpty) map['updated_at'] = nowIso;
              map['deleted_at'] ??= '';
              map['sort_order'] ??= 0;
            }
            if (table == 'item_categories') {
              if ('${map['name'] ?? ''}'.trim().isEmpty) map['name'] = 'تصنيف';
              if ('${map['created_at'] ?? ''}'.trim().isEmpty) map['created_at'] = nowIso;
              if ('${map['updated_at'] ?? ''}'.trim().isEmpty) map['updated_at'] = nowIso;
              map['deleted_at'] ??= '';
              if (map['section_id'] != null && !knownSectionIds.contains(map['section_id'])) {
                map['section_id'] = null;
              }
            }
            if (table == 'items') {
              if ('${map['name'] ?? ''}'.trim().isEmpty) map['name'] = 'صنف';
              if ('${map['created_at'] ?? ''}'.trim().isEmpty) map['created_at'] = nowIso;
              if ('${map['updated_at'] ?? ''}'.trim().isEmpty) map['updated_at'] = nowIso;
              map['deleted_at'] ??= '';
              map['archived'] ??= 0;
              map['is_deleted'] ??= 0;
              map['is_active'] ??= 1;
              if (map['category_id'] != null && !knownCategoryIds.contains(map['category_id'])) {
                map['category_id'] = null;
              }
              if (map['section_id'] != null && !knownSectionIds.contains(map['section_id'])) {
                map['section_id'] = null;
              }
              final thumbB64 = map.remove('thumb_b64');
              if (thumbB64 is String && thumbB64.trim().isNotEmpty) {
                final localImg =
                    await MediaPaths.materializeThumbBase64(thumbB64);
                if (localImg.isNotEmpty) {
                  map['image'] = localImg;
                }
              }
            }
            if (table == 'accounts') {
              if ('${map['name'] ?? ''}'.trim().isEmpty) map['name'] = 'حساب';
              if ('${map['created_at'] ?? ''}'.trim().isEmpty) map['created_at'] = nowIso;
              if ('${map['updated_at'] ?? ''}'.trim().isEmpty) map['updated_at'] = nowIso;
            }
            if (table == 'transactions') {
              if ('${map['created_at'] ?? ''}'.trim().isEmpty) map['created_at'] = nowIso;
              if ('${map['updated_at'] ?? ''}'.trim().isEmpty) map['updated_at'] = nowIso;
              if ('${map['date'] ?? ''}'.trim().isEmpty) map['date'] = nowIso;
            }
            if (table == 'transaction_items') {
              if ('${map['created_at'] ?? ''}'.trim().isEmpty) map['created_at'] = nowIso;
              if ('${map['updated_at'] ?? ''}'.trim().isEmpty) map['updated_at'] = nowIso;
              if (map['item_id'] != null && !knownItemIds.contains(map['item_id'])) {
                map['item_id'] = null;
              }
            }
            if (table == 'stock_moves') {
              if ('${map['created_at'] ?? ''}'.trim().isEmpty) map['created_at'] = nowIso;
              if ('${map['updated_at'] ?? ''}'.trim().isEmpty) map['updated_at'] = nowIso;
              if ('${map['date'] ?? ''}'.trim().isEmpty) map['date'] = nowIso;
              if (map['item_id'] != null && !knownItemIds.contains(map['item_id'])) {
                map['item_id'] = null;
              }
            }
            if (table == 'devices') {
              // تصفية الحقول غير الموجودة في جدول devices المحلي (مثل أعمدة LAN أو حقول السحابة)
              map.removeWhere((k, _) => !_deviceColumns.contains(k));
              final devWs = '${map['workspace_id'] ?? ''}'.trim().isNotEmpty
                  ? '${map['workspace_id']}'.trim()
                  : wsId;
              map['workspace_id'] = devWs;
              await AppDatabase.ensureWorkspaceRow(txn, devWs);
              map['name'] = '${map['name'] ?? 'جهاز'}';
              if ('${map['created_at'] ?? ''}'.trim().isEmpty) {
                map['created_at'] = nowIso;
              }
              if ('${map['updated_at'] ?? ''}'.trim().isEmpty) {
                map['updated_at'] = nowIso;
              }
              if (map['user_id'] != null) {
                final rawUid = map['user_id'];
                final uid =
                    rawUid is int ? rawUid : int.tryParse('$rawUid');
                if (uid == null) {
                  map['user_id'] = null;
                } else {
                  final uHit = await txn.query('users',
                      columns: ['id'],
                      where: 'id = ?',
                      whereArgs: [uid],
                      limit: 1);
                  map['user_id'] = uHit.isNotEmpty ? uid : null;
                }
              }
              if (map['id'] == ourDeviceId ||
                  (map['auth_secret'] as String? ?? '').isEmpty) {
                // سرّنا لا يُكتب أبداً من لقطة واردة؛ وعند غياب السر في
                // اللقطة نحتفظ بما تعلمناه سابقاً عبر الاقتران.
                map['auth_secret'] = knownSecrets[map['id']] ?? '';
              } else {
                // (دفعة 57) سر قرين وارد صريحاً في اللقطة — يُعمّى
                // بمفتاحنا المحلي قبل أن يلمس القرص.
                map['auth_secret'] = await SecretStore.protect(
                    (map['auth_secret'] as String?) ?? '');
              }
              if (map['id'] == ourDeviceId) {
                // سجلنا كما يعرفه المضيف — لسنا مالكين، ونمسح أي طرد أو حظر سابق.
                map['is_owner'] = 0;
                map['is_paired'] = 1;
                map['revoked_at'] = '';
                map['expelled_at'] = '';
              } else if ((map['is_owner'] ?? 0) == 1) {
                // تأكد من أن سجل المضيف يظل is_owner=1 (المالك الشرعي).
                map['is_owner'] = 1;
              }
            }
            if (table == 'users') {
              // العضو لا يملك أي مستخدم محلي كـ "أنا"؛ الهوية تأتي من
              // devices.user_id التي يعيّنها المدير لاحقاً.
              map['is_me'] = 0;
            }
            if (cols.contains('workspace_id') && '${map['workspace_id'] ?? ''}'.trim().isEmpty) {
              map['workspace_id'] = wsId;
            }
            map.removeWhere((k, _) => !cols.contains(k));
            await txn.insert(
              table,
              map,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            if (table == 'sections' && map['id'] != null) {
              knownSectionIds.add(map['id']);
            }
            if (table == 'item_categories' && map['id'] != null) {
              knownCategoryIds.add(map['id']);
            }
            if (table == 'items' && map['id'] != null) {
              knownItemIds.add(map['id']);
            }
          } catch (_) {}
        }
      }

      // 2أ) إدراج المنشأة الأب أولاً قبل المستخدمين والأجهزة والأصناف
      await insertAll('workspaces');
      // (3.71.0 — دخول نظيف) العضو يبقى في مساحة المجموعة وحدها: كل صف
      // محلي خارج اللقطة (مساحة شخصية ميتة) يُحذف — كان يظلل مسار
      // المزامنة ويبتلع طلبات المغادرة فلا تصل المدير.
      try {
        final snapWs = snap['workspaces'];
        if (snapWs is List && snapWs.isNotEmpty) {
          final keep = <String>[
            for (final r in snapWs)
              if (r is Map) '${r['id'] ?? ''}'.trim()
          ]..removeWhere((e) => e.isEmpty);
          if (keep.isNotEmpty) {
            await txn.update(
              'devices',
              {'workspace_id': keep.first},
              where:
                  'workspace_id NOT IN (${List.filled(keep.length, '?').join(',')})',
              whereArgs: keep,
            );
            await txn.delete(
              'workspaces',
              where:
                  'id NOT IN (${List.filled(keep.length, '?').join(',')})',
              whereArgs: keep,
            );
          }
        }
      } catch (_) {}
      // ترتيب محكم يحترم قيود المفاتيح الأجنبية: الأقسام والفئات أولاً ثم الأصناف والحسابات ثم الفواتير
      await insertAll('sections');
      await insertAll('categories');
      await insertAll('item_categories');
      await insertAll('users');
      await insertAll('devices');
      await insertAll('accounts');
      await insertAll('items');
      await insertAll('transactions');
      await insertAll('transaction_items');
      // إدراج بنود الفواتير المضمّنة إن وُجدت
      if (embeddedTxItems.isNotEmpty) {
        final tiInfo = await txn.rawQuery('PRAGMA table_info(transaction_items)');
        final tiCols = {for (final c in tiInfo) c['name'] as String};
        for (final rawLine in embeddedTxItems) {
          try {
            final lineMap = <String, Object?>{};
            rawLine.forEach((k, v) {
              if (k is String && tiCols.contains(k)) lineMap[k] = v as Object?;
            });
            if (tiCols.contains('created_at') && '${lineMap['created_at'] ?? ''}'.trim().isEmpty) {
              lineMap['created_at'] = nowIso;
            }
            if (tiCols.contains('updated_at') && '${lineMap['updated_at'] ?? ''}'.trim().isEmpty) {
              lineMap['updated_at'] = nowIso;
            }
            if (lineMap['item_id'] != null && !knownItemIds.contains(lineMap['item_id'])) {
              lineMap['item_id'] = null;
            }
            await txn.insert('transaction_items', lineMap,
                conflictAlgorithm: ConflictAlgorithm.replace);
          } catch (_) {}
        }
      }
      await insertAll('vouchers');
      await insertAll('stock_moves');
      await insertAll('currencies');
      await insertAll('conversations');
      await insertAll('messages');
      await insertAll('trash');
      await insertAll('activity');
      await insertAll('templates');

      // 2ب) إعدادات المؤسسة: تُمسح إعدادات العمل القديمة على الجهاز المنضم
      // (اسم المؤسسة/العنوان/التذييل/الشعار القديم...) وتُستبدل بإعدادات
      // المجموعة القادمة في اللقطة — فلا يبقى اسم مؤسسته القديمة على السندات.
      const orgKeys = [
        'businessName',
        'businessNameEn',
        'address',
        'phone',
        'whatsapp',
        'managerName',
        'voucherFooter',
        'defaultVoucherNotes',
        'logo',
        'businessActivity',
        'org.icon.b64',
        'user_name',
        'profile_name',
        'profile_phone',
        'defaultCurrency',
      ];
      for (final k in orgKeys) {
        await txn.delete('settings', where: 'key = ?', whereArgs: [k]);
      }
      Future<void> applyOrgSetting(String k, Object? v) async {
        final val = '${v ?? ''}'.trim();
        if (k == 'logo' || !orgKeys.contains(k) || val.isEmpty) return;
        await txn.insert(
          'settings',
          {'key': k, 'value': val},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      final orgSettings = snap['orgSettings'];
      if (orgSettings is Map) {
        for (final e in orgSettings.entries) {
          await applyOrgSetting('${e.key}', e.value);
        }
      }
      final settingsList = snap['settings'];
      if (settingsList is List) {
        for (final s in settingsList) {
          if (s is Map) {
            await applyOrgSetting('${s['key'] ?? ''}', s['value']);
          }
        }
      } else if (settingsList is Map) {
        for (final e in settingsList.entries) {
          await applyOrgSetting('${e.key}', e.value);
        }
      }
      final meta = snap['meta'] is Map ? (snap['meta'] as Map) : null;
      if (meta != null) {
        await applyOrgSetting('businessName',
            meta['storeName'] ?? meta['store_name'] ?? meta['businessName']);
        await applyOrgSetting('businessActivity', meta['businessActivity']);
        await applyOrgSetting('address', meta['address']);
        await applyOrgSetting('phone', meta['phone']);
        await applyOrgSetting('whatsapp', meta['phone'] ?? meta['whatsapp']);
        await applyOrgSetting('defaultCurrency', meta['defaultCurrency']);
        await applyOrgSetting('managerName',
            meta['owner_name'] ?? meta['clientName']);
      }
      // 2ج) تحديث تاريخ أول استخدام للمستخدم/الجهاز المنضم لمنع ظهور أي إشعارات قديمة سابقة
      await txn.insert(
        'settings',
        {'key': 'first_use_at', 'value': DateTime.now().toIso8601String()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      // 3) التحقق من دور هذا الجهاز (قاعدة المدير الحتمية):
      // أ) جهاز المنشئ المضيف لمجموعة العمل (ourDeviceId == hostId) هو المدير دوماً بلا تغيير.
      // ب) الجهاز المسجل ببريد إلكتروني هو المدير دوماً (البريد خاص بجهاز المدير فقط).
      final dev = await txn.query('devices',
          where: 'id = ?', whereArgs: [ourDeviceId], limit: 1);
      final hostId = '${snap['hostDeviceId'] ?? ''}';

      final emailRow = await txn.query('settings',
          where: "key = 'account.email'", limit: 1);
      final localEmail = emailRow.isNotEmpty
          ? '${emailRow.first['value'] ?? ''}'.trim()
          : '';

      final isHost = ourDeviceId.isNotEmpty && hostId.isNotEmpty && ourDeviceId == hostId;
      final hasLocalEmail = localEmail.isNotEmpty &&
          !localEmail.startsWith('cashier@') &&
          !localEmail.startsWith('member@') &&
          !localEmail.endsWith('@local');

      final isHostOrOwner = isHost || hasLocalEmail;

      if (isHostOrOwner) {
        // حماية سيادية: جهاز المدير يبقى مالكاً (is_owner = 1) ووضعه host دوماً
        await txn.update(
          'devices',
          {
            'is_owner': 1,
            'is_paired': 1,
            'revoked_at': '',
            'expelled_at': '',
            'updated_at': nowIso,
          },
          where: 'id = ?',
          whereArgs: [ourDeviceId],
        );
        await txn.insert(
            'sync_meta',
            {
              'key': 'workspaceMode',
              'value': 'host',
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.insert(
            'sync_meta',
            {
              'key': 'ownerDeviceId',
              'value': ourDeviceId,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      } else {
        // جهاز العضو الجديد المنضم — ضمان وجود سجل المنشأة الأب أولاً قبل إدراج/تحديث الجهاز
        await AppDatabase.ensureWorkspaceRow(txn, wsId);
        if (dev.isEmpty) {
          await txn.insert(
            'devices',
            {
              'id': ourDeviceId,
              'workspace_id': wsId,
              'name': 'جهاز عضو',
              'is_owner': 0,
              'is_paired': 1,
              'revoked_at': '',
              'expelled_at': '',
              'created_at': nowIso,
              'updated_at': nowIso,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        } else {
          await txn.update(
            'devices',
            {
              'workspace_id': wsId,
              'is_owner': 0,
              'is_paired': 1,
              'revoked_at': '',
              'expelled_at': '',
              'updated_at': nowIso,
            },
            where: 'id = ?',
            whereArgs: [ourDeviceId],
          );
        }
        // ضبط وضع المساحة على "عضو" وحذف أي سجل ملكية سابق
        await txn.insert(
            'sync_meta',
            {
              'key': 'workspaceMode',
              'value': 'member',
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.delete('sync_meta', where: "key = 'ownerDeviceId'");

        // منشئ هذه المساحة هو المدير (hostId) وليس جهاز العضو
        if (hostId.isNotEmpty) {
          await txn.insert(
            'settings',
            {'key': 'creatorDeviceId', 'value': hostId},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        // تطهير كامل لأي بريد إلكتروني على جهاز العضو (البريد خاص بالمدير فقط)
        final memberPurgeKeys = [
          'account.email',
          'profile_email',
          'email',
          'account.uid',
          'account.name',
          'account.idToken',
          'account.refreshToken',
        ];
        for (final k in memberPurgeKeys) {
          await txn.delete('settings', where: 'key = ?', whereArgs: [k]);
        }
      }
    });
  }

}
