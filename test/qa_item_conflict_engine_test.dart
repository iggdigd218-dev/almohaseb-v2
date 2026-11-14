import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/item_conflict.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/sfx.dart';
import 'package:nexora_app/core/theme.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:nexora_app/ui/inventory_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUpAll(() async {
    await initializeDateFormatting('ar');
    Sfx.setMuted(true);
    await (FontLoader('AppNaskh')
          ..addFont(rootBundle.load('assets/fonts/NotoNaskhArabic-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/NotoNaskhArabic-Bold.ttf')))
        .load();
  });

  Future<(Directory, Database, Repo)> createTestRepo(String prefix) async {
    final tmp = await Directory.systemTemp.createTemp(prefix);
    final db = await databaseFactory.openDatabase(
      '${tmp.path}/engine_audit.db',
      options: OpenDatabaseOptions(
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    await AppDatabase.createSchema(db);
    await AppDatabase.ensureLatestColumns(db);
    final repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
    return (tmp, db, repo);
  }

  test(
    'QA-CONFLICT-ENGINE-1 devices DEFAULT dates, creator name priority skipping placeholders, MAX(id)+1 allocation, and wildcard item_id_remap lookup',
    () async {
      final (tmp, db, repo) = await createTestRepo('nexora_eng_1_');
      final resolver = ConflictResolver();
      try {
        // 1. إدراج جهاز بدون created_at أو updated_at يجب أن ينجح بفضل DEFAULT ''
        await db.insert('devices', {
          'id': 'dev-remote-1',
          'workspace_id': 'default',
          'name': 'فرع التحرير',
          'is_paired': 1,
        });

        // 2. جدول users يحتوي افتراضياً على "المدير" (اسم عام يجب تخطيه)
        // التحقق من أولوية الإعدادات: profile.owner_name -> account.name -> sync.deviceName
        await repo.setSetting('sync.deviceName', 'جهاز الكاشير 1');
        await repo.setSetting('account.name', 'مؤسسة النور');
        await repo.setSetting('profile.owner_name', 'خالد المحاسب');

        // نضع صنفاً عالي المعرف للتأكد أن _allocateFreeItemId يستخدم MAX(id) + 1
        const t0 = '2026-11-10T07:00:00.000Z';
        await db.insert('items', {
          'id': 200,
          'plu': 200,
          'workspace_id': 'default',
          'name': 'صنف مرجعي 200',
          'sku': 'REF-200',
          'unit': 'قطعة',
          'buy_price': 100.0,
          'sell_price': 150.0,
          'quantity': 1.0,
          'min_quantity': 0.0,
          'is_active': 1,
          'is_deleted': 0,
          'created_at': t0,
          'updated_at': t0,
        });

        const t1 = '2026-11-10T08:00:00.000Z';
        await db.insert('items', {
          'id': 50,
          'plu': 50,
          'workspace_id': 'default',
          'name': 'كابل شحن أصلي',
          'sku': 'CABLE-50',
          'unit': 'قطعة',
          'buy_price': 1000.0,
          'sell_price': 1500.0,
          'quantity': 10.0,
          'min_quantity': 1.0,
          'is_active': 1,
          'is_deleted': 0,
          'created_at': t1,
          'updated_at': t1,
        });

        const t2 = '2026-11-10T08:10:00.000Z';
        await repo.applyRemoteOperation(
          db,
          const SyncOperation(
            id: 'op-item-50-remote',
            workspaceId: 'default',
            deviceId: 'dev-remote-1',
            userId: 2,
            opType: OpKind.create,
            entityType: EntityKind.item,
            entityId: '50',
            payload: {
              'id': 50,
              'plu': 50,
              'name': 'سماعة بلوتوث رياضية',
              'sku': 'CABLE-50',
              'unit': 'قطعة',
              'buy_price': 3000.0,
              'sell_price': 4500.0,
              'quantity': 6.0,
              'min_quantity': 1.0,
              'created_at': t2,
              'updated_at': t2,
            },
            timestamp: t2,
            deviceTime: t2,
            version: 1,
            parentOpId: '',
          ),
          resolver,
        );

        final pending = await repo.pendingItemConflicts();
        expect(pending.length, 1);
        final conflict = pending.single;
        expect(conflict.item1Creator, 'خالد المحاسب');
        expect(conflict.item2Creator, 'فرع التحرير');
        // MAX(id) كان 200، فيأخذ الصنف المفصول المعرف 201 مباشرة
        expect(conflict.item2Id, 201);

        // 3. وصول حركة مخزون لاحقة بدون deviceId تطابق المعرف المعاد ترقيمه عبر LIKE 'item_id_remap:%:50'
        await repo.applyRemoteOperation(
          db,
          const SyncOperation(
            id: 'op-move-remap-wildcard',
            workspaceId: 'default',
            deviceId: '',
            userId: 2,
            opType: OpKind.create,
            entityType: EntityKind.stockMove,
            entityId: '901',
            payload: {
              'id': 901,
              'item_id': 50,
              'kind': 'purchase',
              'quantity': 4.0,
              'unit_price': 3000.0,
              'date': t2,
              'created_at': t2,
            },
            timestamp: t2,
            deviceTime: t2,
            version: 2,
            parentOpId: '',
          ),
          resolver,
        );

        final move901 = await db.query(
          'stock_moves',
          where: 'id = ?',
          whereArgs: [901],
        );
        expect(move901.single['item_id'], 201);
      } finally {
        await db.close();
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    },
  );

  test(
    'QA-CONFLICT-ENGINE-2 deduplicates conflict sync ops, preserves resolved conflicts on subsequent item updates, updates seen=1 on remote resolution, and defers hook outside transaction',
    () async {
      final (tmp, db, repo) = await createTestRepo('nexora_eng_2_');
      final resolver = ConflictResolver();
      final hookEvents = <String>[];
      ItemConflictHooks.onConflictDetected = (c) {
        hookEvents.add('${c.key}:${c.status}');
      };
      try {
        await repo.setSetting('sync.deviceName', 'كاشير الفرع');
        const t1 = '2026-11-10T09:00:00.000Z';
        await db.insert('items', {
          'id': 30,
          'plu': 30,
          'workspace_id': 'default',
          'name': 'حافظة آيباد برو',
          'sku': 'SHARED-30',
          'unit': 'قطعة',
          'buy_price': 2000.0,
          'sell_price': 3500.0,
          'quantity': 5.0,
          'min_quantity': 1.0,
          'is_active': 1,
          'is_deleted': 0,
          'created_at': t1,
          'updated_at': t1,
        });

        const t2 = '2026-11-10T09:05:00.000Z';
        ItemConflictHooks.beginTransactionScope();
        await db.transaction((txn) async {
          await repo.applyRemoteOperation(
            txn,
            const SyncOperation(
              id: 'op-item-31-sku',
              workspaceId: 'default',
              deviceId: 'dev-peer',
              userId: 2,
              opType: OpKind.create,
              entityType: EntityKind.item,
              entityId: '31',
              payload: {
                'id': 31,
                'plu': 31,
                'name': 'قلم لمس مغناطيسي',
                'sku': 'SHARED-30',
                'unit': 'قطعة',
                'buy_price': 2500.0,
                'sell_price': 4000.0,
                'quantity': 4.0,
                'min_quantity': 1.0,
                'created_by_name': 'سمير المخزن',
                'created_at': t2,
                'updated_at': t2,
              },
              timestamp: t2,
              deviceTime: t2,
              version: 1,
              parentOpId: '',
            ),
            resolver,
          );
          // داخل المعاملة لم يُطلق الإشعار بعد
          expect(hookEvents, isEmpty);
        });
        ItemConflictHooks.commitTransactionScope();
        expect(hookEvents, ['item_conflict:30_31:pending']);

        final opsAfterFirst = await db.query(
          'operations',
          where: "entity_type = 'setting' AND entity_id = 'item_conflict:30_31'",
        );
        expect(opsAfterFirst.length, 1);

        // وصول تحديث للصنف بنفس البيانات لا يكرر queueOperation للتعارض غير المتغير
        const t3 = '2026-11-10T09:06:00.000Z';
        await repo.applyRemoteOperation(
          db,
          const SyncOperation(
            id: 'op-item-31-update-same',
            workspaceId: 'default',
            deviceId: 'dev-peer',
            userId: 2,
            opType: OpKind.update,
            entityType: EntityKind.item,
            entityId: '31',
            payload: {
              'sell_price': 4200.0,
              'created_by_name': 'سمير المخزن',
              'updated_at': t3,
            },
            timestamp: t3,
            deviceTime: t3,
            version: 2,
            parentOpId: '',
          ),
          resolver,
        );
        final opsAfterDuplicate = await db.query(
          'operations',
          where: "entity_type = 'setting' AND entity_id = 'item_conflict:30_31'",
        );
        expect(opsAfterDuplicate.length, 1);

        // حل التعارض بخيار الإبقاء منفصلين
        await repo.resolveItemConflictKeepSeparate(
          conflictKey: 'item_conflict:30_31',
        );
        expect(await repo.pendingItemConflicts(), isEmpty);

        // تحديث لاحق للصنف #31 بنفس الباركود لا يعيد فتح التعارض المحلول
        const t4 = '2026-11-10T09:10:00.000Z';
        await repo.applyRemoteOperation(
          db,
          const SyncOperation(
            id: 'op-item-31-after-resolve',
            workspaceId: 'default',
            deviceId: 'dev-peer',
            userId: 2,
            opType: OpKind.update,
            entityType: EntityKind.item,
            entityId: '31',
            payload: {
              'name': 'قلم لمس مغناطيسي',
              'sku': 'SHARED-30',
              'sell_price': 4300.0,
              'updated_at': t4,
            },
            timestamp: t4,
            deviceTime: t4,
            version: 3,
            parentOpId: '',
          ),
          resolver,
        );
        expect(await repo.pendingItemConflicts(), isEmpty);

        // اختبار استقبال حل التعارض من جهاز آخر وتحديث seen = 1 في notifications
        await db.update(
          'notifications',
          {'seen': 0},
          where: "entity_type = 'item_conflict' AND entity_id = ?",
          whereArgs: ['item_conflict:30_31'],
        );
        final resolvedConflict = (await repo.itemConflictByKey(
          'item_conflict:30_31',
        ))!;
        await repo.applyRemoteOperation(
          db,
          SyncOperation(
            id: 'op-remote-conflict-resolved',
            workspaceId: 'default',
            deviceId: 'dev-peer',
            userId: 2,
            opType: OpKind.settings,
            entityType: EntityKind.setting,
            entityId: 'item_conflict:30_31',
            payload: {
              'key': 'item_conflict:30_31',
              'value': resolvedConflict.toJson(),
            },
            timestamp: t4,
            deviceTime: t4,
            version: 4,
            parentOpId: '',
          ),
          resolver,
        );
        final notifRows = await db.query(
          'notifications',
          where: "entity_type = 'item_conflict' AND entity_id = ?",
          whereArgs: ['item_conflict:30_31'],
        );
        expect(notifRows.single['seen'], 1);
        expect('${notifRows.single['title']}', contains('تم حل تعارض الصنف'));
      } finally {
        ItemConflictHooks.onConflictDetected = null;
        await db.close();
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    },
  );

  test(
    'QA-CONFLICT-ENGINE-3 resolveItemConflictMergeItems preserves exact stock when net moves on merged item are negative and survives reconcileInventoryQuantities',
    () async {
      final (tmp, db, repo) = await createTestRepo('nexora_eng_3_');
      try {
        const t1 = '2026-11-10T10:00:00.000Z';
        // الصنف الأساسي #70: رصيد افتتاحي 10 مسجل في عملية الإنشاء بدون حركات لاحقة
        await db.insert('items', {
          'id': 70,
          'plu': 70,
          'workspace_id': 'default',
          'name': 'باور بانك أنكر 20000',
          'sku': 'ANK-20K',
          'unit': 'قطعة',
          'buy_price': 8000.0,
          'sell_price': 11000.0,
          'quantity': 10.0,
          'min_quantity': 2.0,
          'is_active': 1,
          'is_deleted': 0,
          'created_at': t1,
          'updated_at': t1,
        });
        await db.insert('operations', {
          'id': 'op-init-70',
          'workspace_id': 'default',
          'device_id': 'dev-local',
          'user_id': 1,
          'op_type': 'create',
          'entity_type': 'item',
          'entity_id': '70',
          'payload': '{"id":70,"quantity":10.0}',
          'timestamp': t1,
          'device_time': t1,
          'version': 1,
          'parent_op_id': '',
          'synced': 1,
        });

        // الصنف المكرر #71: أُنشئ برصيد افتتاحي 8 ثم بيع منه 3 فصار رصيده الحالي 5 وصافي حركاته -3
        await db.insert('items', {
          'id': 71,
          'plu': 71,
          'workspace_id': 'default',
          'name': 'باور بانك أنكر 20K',
          'sku': 'ANK-20K',
          'unit': 'قطعة',
          'buy_price': 8000.0,
          'sell_price': 11000.0,
          'quantity': 5.0,
          'min_quantity': 2.0,
          'is_active': 1,
          'is_deleted': 0,
          'created_at': t1,
          'updated_at': t1,
        });
        await db.insert('stock_moves', {
          'id': 801,
          'workspace_id': 'default',
          'item_id': 71,
          'kind': 'sale',
          'quantity': 3.0,
          'unit_price': 11000.0,
          'notes': 'بيع 3 قطع قبل الدمج',
          'date': '2026-11-10',
          'created_at': t1,
        });

        const conflict = OfflineItemConflict(
          key: 'item_conflict:70_71',
          conflictType: 'sku',
          sharedSku: 'ANK-20K',
          item1Id: 70,
          item1Name: 'باور بانك أنكر 20000',
          item1Creator: 'أحمد',
          item2Id: 71,
          item2Name: 'باور بانك أنكر 20K',
          item2Creator: 'محمود',
          status: 'pending',
          createdAt: t1,
        );
        await repo.setSetting(conflict.key, conflict.toJson());

        await repo.resolveItemConflictMergeItems(
          conflictKey: conflict.key,
          keepItemId: 70,
        );

        final mergedBeforeReconcile = (await repo.items()).singleWhere(
          (i) => i.id == 70,
        );
        expect(mergedBeforeReconcile.quantity, 15.0);

        // التحقق من ثبات الرصيد عند إعادة مطابقة المخزون مع سجل الحركات (10 + 8 - 3 = 15)
        await ApplyRemoteOp.reconcileInventoryQuantities(db);
        final mergedAfterReconcile = (await repo.items()).singleWhere(
          (i) => i.id == 70,
        );
        expect(mergedAfterReconcile.quantity, 15.0);
      } finally {
        await db.close();
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    },
  );

  test(
    'QA-CONFLICT-ENGINE-4 safeParseDateTime, ItemCategory.fromMap, Item.fromMap, and ensureLatestColumns handle mixed, empty, epoch, slash, and invalid dates without FormatException',
    () async {
      // 1. اختبار ItemCategory.fromMap و Item.fromMap مع صيغ تواريخ مختلطة وفارغة وغير صالحة
      final epochMs = DateTime.utc(2026, 11, 10, 14, 30).millisecondsSinceEpoch;
      final epochSec = epochMs ~/ 1000;

      final catIso = ItemCategory.fromMap(const {
        'id': 1,
        'name': 'هواتف',
        'created_at': '2026-11-10T14:30:00.000Z',
        'updated_at': '',
      });
      expect(catIso.createdAt.year, 2026);
      expect(catIso.updatedAt, catIso.createdAt);

      final catEpochNum = ItemCategory.fromMap({
        'id': 2,
        'name': 'إكسسوارات',
        'created_at': epochMs,
        'updated_at': '$epochSec',
      });
      expect(catEpochNum.createdAt.toUtc().year, 2026);
      expect(catEpochNum.updatedAt.toUtc().month, 11);

      final catSlash = ItemCategory.fromMap(const {
        'id': 3,
        'name': 'شواحن',
        'created_at': '2026/11/10 15:45:00',
        'updated_at': '١٠/١١/٢٠٢٦',
      });
      expect(catSlash.createdAt.year, 2026);
      expect(catSlash.createdAt.month, 11);
      expect(catSlash.createdAt.day, 10);
      expect(catSlash.updatedAt.year, 2026);

      final catEmptyAndNull = ItemCategory.fromMap(const {
        'id': 4,
        'name': 'بطاريات',
        'created_at': '',
        'updated_at': null,
      });
      expect(catEmptyAndNull.createdAt, DateTime.fromMillisecondsSinceEpoch(0));
      expect(safeParseNullableDateTime(''), isNull);
      expect(safeParseNullableDateTime(null), isNull);
      expect(safeParseNullableDateTime('invalid-date-value'), isNull);

      final itemMixed = Item.fromMap({
        'id': 9,
        'name': 'صنف بتواريخ مختلطة',
        'created_at': '',
        'updated_at': '$epochMs',
      });
      expect(itemMixed.createdAt.toUtc().year, 2026);
      expect(itemMixed.updatedAt.toUtc().year, 2026);

      // 2. اختبار ترميم ensureLatestColumns للتواريخ الفارغة وغير القياسية في SQLite
      final (tmp, db, repo) = await createTestRepo('nexora_eng_4_');
      try {
        await db.insert('item_categories', {
          'id': 11,
          'workspace_id': 'default',
          'name': 'فئة بدون تاريخ',
          'created_at': '',
          'updated_at': '',
        });
        await db.insert('item_categories', {
          'id': 12,
          'workspace_id': 'default',
          'name': 'فئة بتوقيت رقمي',
          'created_at': '$epochMs',
          'updated_at': '2026/11/10 08:00:00',
        });
        await db.insert('items', {
          'id': 88,
          'plu': 88,
          'workspace_id': 'default',
          'name': 'صنف بتوقيت تالف',
          'category_id': 11,
          'sku': 'HEAL-88',
          'unit': 'قطعة',
          'buy_price': 500.0,
          'sell_price': 800.0,
          'quantity': 4.0,
          'min_quantity': 1.0,
          'is_active': 1,
          'is_deleted': 0,
          'created_at': '',
          'updated_at': 'not-a-valid-date',
        });

        await AppDatabase.ensureLatestColumns(db);

        final healedCats = await db.query(
          'item_categories',
          where: 'id IN (11, 12)',
          orderBy: 'id ASC',
        );
        for (final row in healedCats) {
          expect(DateTime.tryParse('${row['created_at']}'), isNotNull);
          expect(DateTime.tryParse('${row['updated_at']}'), isNotNull);
        }
        final healedItem = await db.query(
          'items',
          where: 'id = ?',
          whereArgs: [88],
        );
        expect(DateTime.tryParse('${healedItem.single['created_at']}'), isNotNull);
        expect(DateTime.tryParse('${healedItem.single['updated_at']}'), isNotNull);

        final tree = await repo.itemCategoryTree();
        expect(tree.map((c) => c.name), containsAll(['فئة بدون تاريخ', 'فئة بتوقيت رقمي']));
        final loadedItems = await repo.items();
        expect(loadedItems.map((i) => i.name), contains('صنف بتوقيت تالف'));
      } finally {
        await db.close();
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    },
  );

  testWidgets(
    'QA-CONFLICT-ENGINE-5 InventoryScreen shows outer ItemConflictBanner even when catalog is empty and lists remaining conflicts in modal sheet',
    (tester) async {
      late Directory tmp;
      late Database db;
      late Repo repo;
      late SyncEngine engine;
      late ProviderContainer container;

      await tester.runAsync(() async {
        (tmp, db, repo) = await createTestRepo('nexora_eng_5_');
        const c1 = OfflineItemConflict(
          key: 'item_conflict:1_2',
          conflictType: 'sku',
          sharedSku: 'SKU-111',
          item1Id: 1,
          item1Name: 'صنف أول أ',
          item1Creator: 'أحمد',
          item2Id: 2,
          item2Name: 'صنف أول ب',
          item2Creator: 'سعيد',
          status: 'pending',
          createdAt: '2026-11-10T12:05:00.000Z',
        );
        const c2 = OfflineItemConflict(
          key: 'item_conflict:3_4',
          conflictType: 'id',
          originalCollidingId: 3,
          item1Id: 3,
          item1Name: 'صنف ثان أ',
          item1Creator: 'أحمد',
          item2Id: 4,
          item2Name: 'صنف ثان ب',
          item2Creator: 'خالد',
          status: 'pending',
          createdAt: '2026-11-10T12:00:00.000Z',
        );
        await repo.setSetting(c1.key, c1.toJson());
        await repo.setSetting(c2.key, c2.toJson());

        engine = SyncEngine(repo: repo, dbProvider: () async => db);
        container = ProviderContainer(
          overrides: [
            repoProvider.overrideWithValue(repo),
            syncEngineProvider.overrideWithValue(engine),
          ],
        );
        await container.read(itemsProvider.future);
        await container.read(itemCategoryTreeProvider.future);
        await container.read(sectionsProvider.future);
        await container.read(settingsProvider.future);
        await container.read(pendingItemConflictsProvider.future);
      });

      await tester.binding.setSurfaceSize(const Size(900, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              locale: const Locale('ar'),
              supportedLocales: const [Locale('ar')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: const Scaffold(body: InventoryScreen()),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        // الكتالوج فارغ تماماً ("ابدأ بإضافة فئة") ومع ذلك يظهر ItemConflictBanner في Column الخارجي
        expect(find.text('ابدأ بإضافة فئة'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('item_conflict_banner')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('show_all_conflicts_banner_btn')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const ValueKey('show_all_conflicts_banner_btn')),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('جميع تعارضات الأصناف المعلّقة (2)'), findsOneWidget);
        expect(find.textContaining('صنف أول أ'), findsWidgets);
        expect(find.textContaining('صنف ثان أ'), findsWidgets);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
        engine.stop();
        container.dispose();
        await tester.runAsync(() async {
          await db.close();
          try {
            await tmp.delete(recursive: true);
          } catch (_) {}
        });
      }
    },
  );
}
