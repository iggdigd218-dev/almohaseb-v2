import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/item_conflict.dart';
import 'package:nexora_app/core/sfx.dart';
import 'package:nexora_app/core/theme.dart';
import 'package:nexora_app/data/pos_cart.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:nexora_app/ui/inventory_screen.dart';
import 'package:nexora_app/ui/pos_screen.dart';
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
      '${tmp.path}/conflict.db',
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
    'QA-OFFLINE-CONFLICT-1 prevents item overwrite, auto-renumbers younger item, updates linked invoices & stock_moves, creates smart notification, and supports barcode generation & merge resolutions',
    () async {
      final (tmp, db, repo) = await createTestRepo('nexora_conflict_1_');
      final resolver = ConflictResolver();
      try {
        await repo.setSetting('sync.deviceName', 'أحمد الكاشير');
        await db.insert(
          'devices',
          {
            'id': 'dev-B',
            'workspace_id': 'default',
            'name': 'محمود المخزن',
            'is_owner': 0,
            'is_paired': 1,
            'created_at': '2026-11-10T08:00:00.000Z',
            'updated_at': '2026-11-10T09:00:00.000Z',
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );

        // 1. الجهاز الأول (محلي) يدخل صنفاً أوفلاين بالمعرف #50 والباركود SKU-9999
        final t1 = DateTime.parse('2026-11-10T10:00:00.000Z');
        await db.insert('items', {
          'id': 50,
          'plu': 50,
          'workspace_id': 'default',
          'name': 'بطارية آيفون 13 أصلية',
          'sku': 'SKU-9999',
          'unit': 'قطعة',
          'buy_price': 4000.0,
          'sell_price': 6000.0,
          'quantity': 10.0,
          'min_quantity': 2.0,
          'is_active': 1,
          'is_deleted': 0,
          'created_at': t1.toIso8601String(),
          'updated_at': t1.toIso8601String(),
        });

        // فاتورة محلية مرتبطة بالصنف #50
        await db.insert('transactions', {
          'id': 501,
          'workspace_id': 'default',
          'type': 'revenue',
          'amount': 6000.0,
          'currency': 'YER',
          'description': 'بيع بطارية آيفون 13',
          'date': t1.toIso8601String(),
          'created_at': t1.toIso8601String(),
          'updated_at': t1.toIso8601String(),
        });
        await db.insert('transaction_items', {
          'tx_id': 501,
          'item_id': 50,
          'name': 'بطارية آيفون 13 أصلية',
          'unit': 'قطعة',
          'quantity': 1.0,
          'unit_price': 6000.0,
          'total': 6000.0,
        });

        OfflineItemConflict? detectedConflict;
        ItemConflictHooks.onConflictDetected = (c) {
          detectedConflict = c;
        };

        // 2. الجهاز الثاني (dev-B) أدخل أوفلاين صنفاً مختلفاً بنفس المعرف #50 ونفس الباركود SKU-9999
        const t2 = '2026-11-10T10:05:00.000Z';
        const remoteItemOp = SyncOperation(
          id: 'op-remote-item-50',
          workspaceId: 'default',
          deviceId: 'dev-B',
          userId: 2,
          opType: OpKind.create,
          entityType: EntityKind.item,
          entityId: '50',
          payload: {
            'id': 50,
            'plu': 50,
            'name': 'شاشة سامسونج A54 وكالة',
            'sku': 'SKU-9999',
            'unit': 'قطعة',
            'buy_price': 15000.0,
            'sell_price': 20000.0,
            'quantity': 5.0,
            'min_quantity': 1.0,
            'created_by_name': 'محمود المخزن',
            'created_at': t2,
            'updated_at': t2,
          },
          timestamp: t2,
          deviceTime: t2,
          version: 1,
          parentOpId: '',
        );
        await repo.applyRemoteOperation(db, remoteItemOp, resolver);

        // 3. الجهاز الثاني يرسل فاتورة وحركة مخزون مرتبطتين بالمعرف الأصلي 50
        const remoteTxOp = SyncOperation(
          id: 'op-remote-tx-601',
          workspaceId: 'default',
          deviceId: 'dev-B',
          userId: 2,
          opType: OpKind.create,
          entityType: EntityKind.tx,
          entityId: '601',
          payload: {
            'id': 601,
            'type': 'revenue',
            'amount': 40000.0,
            'currency': 'YER',
            'description': 'بيع شاشات سامسونج A54',
            'date': t2,
            'created_at': t2,
            'updated_at': t2,
            'items': [
              {
                'item_id': 50,
                'name': 'شاشة سامسونج A54 وكالة',
                'unit': 'قطعة',
                'quantity': 2.0,
                'unit_price': 20000.0,
                'total': 40000.0,
              },
            ],
          },
          timestamp: t2,
          deviceTime: t2,
          version: 2,
          parentOpId: '',
        );
        await repo.applyRemoteOperation(db, remoteTxOp, resolver);

        const remoteMoveOp = SyncOperation(
          id: 'op-remote-move-701',
          workspaceId: 'default',
          deviceId: 'dev-B',
          userId: 2,
          opType: OpKind.create,
          entityType: EntityKind.stockMove,
          entityId: '701',
          payload: {
            'id': 701,
            'item_id': 50,
            'kind': 'sale',
            'quantity': 2.0,
            'unit_price': 20000.0,
            'reference': '601',
            'date': t2,
            'created_at': t2,
            'updated_at': t2,
          },
          timestamp: t2,
          deviceTime: t2,
          version: 3,
          parentOpId: '',
        );
        await repo.applyRemoteOperation(db, remoteMoveOp, resolver);

        // التحقق 1: عدم ضياع أي من الصنفين وفصل الصنف الأصغر برقم جديد
        final allItems = await repo.items();
        expect(allItems.length, 2);
        final item1 = allItems.firstWhere((e) => e.id == 50);
        final item2 = allItems.firstWhere((e) => e.id != 50);
        expect(item1.name, 'بطارية آيفون 13 أصلية');
        expect(item2.name, 'شاشة سامسونج A54 وكالة');
        expect(item2.id, greaterThan(50));
        expect(item1.sku, 'SKU-9999');
        expect(item2.sku, 'SKU-9999');

        // التحقق 2: تحديث مرجع item_id في الفواتير وحركات المخزون المرتبطة بالصنف الثاني
        final tx501Lines = await db.query(
          'transaction_items',
          where: 'tx_id = ?',
          whereArgs: [501],
        );
        expect(tx501Lines.single['item_id'], 50);

        final tx601Lines = await db.query(
          'transaction_items',
          where: 'tx_id = ?',
          whereArgs: [601],
        );
        expect(tx601Lines.single['item_id'], item2.id);

        final move701Rows = await db.query(
          'stock_moves',
          where: 'id = ?',
          whereArgs: [701],
        );
        expect(move701Rows.single['item_id'], item2.id);

        // التحقق 3: إنشاء إشعار ذكي مفصّل في الجرس وسجل التعارض المعلق
        expect(detectedConflict, isNotNull);
        final pending = await repo.pendingItemConflicts();
        expect(pending.length, 1);
        final conflict = pending.first;
        expect(conflict.item1Name, 'بطارية آيفون 13 أصلية');
        expect(conflict.item1Creator, contains('أحمد الكاشير'));
        expect(conflict.item2Name, 'شاشة سامسونج A54 وكالة');
        expect(conflict.item2Creator, contains('محمود المخزن'));
        expect(conflict.conflictType, 'id_and_sku');
        expect(
          conflict.conflictTypeLabel,
          contains('تعارض رقم صنف (#50 تم فصله تلقائياً'),
        );
        expect(conflict.conflictTypeLabel, contains('اشتراك في نفس الباركود'));

        final notifs = await repo.notifications();
        final conflictNotif = notifs.firstWhere(
          (n) => n['entity_type'] == 'item_conflict',
        );
        expect('${conflictNotif['body']}', contains('بطارية آيفون 13 أصلية'));
        expect('${conflictNotif['body']}', contains('شاشة سامسونج A54 وكالة'));
        expect('${conflictNotif['body']}', contains('محمود المخزن'));

        // التحقق 4: الخيار الأول للحل (توليد/تعديل الباركود)
        final newGeneratedSku = await repo.resolveItemConflictChangeBarcode(
          conflictKey: conflict.key,
          targetItemId: item2.id!,
        );
        expect(newGeneratedSku, isNotEmpty);
        expect(newGeneratedSku, isNot('SKU-9999'));
        final updatedItem2 = (await repo.items()).firstWhere(
          (e) => e.id == item2.id,
        );
        expect(updatedItem2.sku, newGeneratedSku);
        expect(await repo.pendingItemConflicts(), isEmpty);

        // التحقق 5: الخيار الثاني للحل (دمج الصنفين في صنف واحد وجمع الكميات وتوحيد الحركات والفواتير)
        // نعيد ضبط حالة التعارض لاختبار مسار الدمج الكامل
        await repo.setSetting(
          conflict.key,
          conflict.copyWith(status: 'pending', resolution: '').toJson(),
        );
        await repo.resolveItemConflictMergeItems(
          conflictKey: conflict.key,
          keepItemId: 50,
        );
        final afterMergeItems = await repo.items();
        expect(afterMergeItems.length, 1);
        final merged = afterMergeItems.single;
        expect(merged.id, 50);
        // الكمية المدمجة = كمية الصنف الأول (10) + كمية الصنف الثاني بعد بيع حبتين (5 - 2 = 3) = 13
        expect(merged.quantity, 13.0);

        // التحقق من توحيد الفواتير وحركات المخزون تحت الصنف المدمج #50
        final tx601AfterMerge = await db.query(
          'transaction_items',
          where: 'tx_id = ?',
          whereArgs: [601],
        );
        expect(tx601AfterMerge.single['item_id'], 50);
        final move701AfterMerge = await db.query(
          'stock_moves',
          where: 'id = ?',
          whereArgs: [701],
        );
        expect(move701AfterMerge.single['item_id'], 50);
      } finally {
        ItemConflictHooks.onConflictDetected = null;
        await db.close();
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    },
  );

  testWidgets(
    'QA-OFFLINE-CONFLICT-2 displays conflict Banner & Resolution Dialog, and shows POS shared barcode picker when keep_separate is chosen',
    (tester) async {
      late Directory tmp;
      late Database db;
      late Repo repo;
      late SyncEngine engine;
      late ProviderContainer container;
      final resolver = ConflictResolver();

      await tester.runAsync(() async {
        (tmp, db, repo) = await createTestRepo('nexora_conflict_2_');
        await repo.setSetting('sync.deviceName', 'كاشير المحل');

        const t1 = '2026-11-10T11:00:00.000Z';
        await db.insert('items', {
          'id': 10,
          'plu': 10,
          'workspace_id': 'default',
          'name': 'شاحن تايب سي 20 واط',
          'sku': 'BAR-777',
          'unit': 'قطعة',
          'buy_price': 1500.0,
          'sell_price': 2500.0,
          'quantity': 8.0,
          'min_quantity': 1.0,
          'is_active': 1,
          'is_deleted': 0,
          'created_at': t1,
          'updated_at': t1,
        });

        const t2 = '2026-11-10T11:03:00.000Z';
        await repo.applyRemoteOperation(
          db,
          const SyncOperation(
            id: 'op-remote-item-10',
            workspaceId: 'default',
            deviceId: 'dev-peer',
            userId: 3,
            opType: OpKind.create,
            entityType: EntityKind.item,
            entityId: '10',
            payload: {
              'id': 10,
              'plu': 10,
              'name': 'وصلة سماعة آيفون أصلية',
              'sku': 'BAR-777',
              'unit': 'قطعة',
              'buy_price': 1000.0,
              'sell_price': 1800.0,
              'quantity': 12.0,
              'min_quantity': 1.0,
              'created_by_name': 'سعيد المبيعات',
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
        // 1. فتح شاشة إدارة المنتجات والتحقق من ظهور الـ Banner الواضح وفتح نافذة الحل الفورية
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
        await tester.pump(const Duration(milliseconds: 250));

        expect(
          find.byKey(const ValueKey('item_conflict_banner')),
          findsOneWidget,
        );
        expect(find.textContaining('شاحن تايب سي 20 واط'), findsWidgets);
        expect(find.textContaining('وصلة سماعة آيفون أصلية'), findsWidgets);
        expect(find.textContaining('سعيد المبيعات'), findsWidgets);

        // فتح نافذة المعالجة الفورية واختيار الخيار 3: «اعتماد الفصل»
        await tester.tap(
          find.byKey(const ValueKey('resolve_conflict_banner_btn')),
        );
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('item_conflict_resolution_dialog')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('conflict_action_change_barcode')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('conflict_action_merge_items')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('conflict_action_keep_separate')),
          findsOneWidget,
        );

        await tester.ensureVisible(
          find.byKey(const ValueKey('conflict_action_keep_separate')),
        );
        await tester.tap(
          find.byKey(const ValueKey('conflict_action_keep_separate')),
        );
        await tester.pump();
        await tester.runAsync(() async {
          for (var i = 0; i < 20; i++) {
            final pending = await repo.pendingItemConflicts();
            if (pending.isEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
          await container.read(itemsProvider.future);
        });
        await tester.pumpAndSettle();

        // 2. فتح شاشة نقطة البيع (POS) ومسح/إدخال الباركود المشترك BAR-777
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
              home: const Scaffold(body: PosScreen()),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final searchField = find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              (w.decoration?.hintText?.contains('ابحث عن صنف') ?? false),
        );
        expect(searchField, findsOneWidget);

        await tester.enterText(searchField, 'BAR-777');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        // التحقق من ظهور النافذة المصغرة الفورية للكاشير لاختيار الصنف المقصود
        expect(
          find.byKey(const ValueKey('pos_shared_barcode_picker_dialog')),
          findsOneWidget,
        );
        expect(
          find.textContaining('باركود مشترك (BAR-777) — اختر الصنف المقصود'),
          findsOneWidget,
        );
        expect(find.text('شاحن تايب سي 20 واط'), findsWidgets);
        expect(find.text('وصلة سماعة آيفون أصلية'), findsWidgets);

        // يختار الكاشير الصنف الثاني «وصلة سماعة آيفون أصلية» من النافذة المصغرة
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('pos_shared_barcode_picker_dialog')),
            matching: find.text('وصلة سماعة آيفون أصلية'),
          ),
        );
        await tester.pumpAndSettle();

        final draftState = container.read(posDraftProvider);
        expect(draftState.cart.length, 1);
        expect(
          draftState.cart.values.single.item.name,
          'وصلة سماعة آيفون أصلية',
        );
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
