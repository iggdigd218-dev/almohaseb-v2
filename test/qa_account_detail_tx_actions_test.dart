import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/sfx.dart';
import 'package:nexora_app/core/theme.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:nexora_app/ui/account_detail.dart';
import 'package:nexora_app/ui/tx_form.dart';
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

  testWidgets(
    'QA-ACC-DETAIL-ACTIONS shows transaction actions (view, edit, share/print, delete) in AccountDetailScreen and updates balance immediately after edit or delete',
    (tester) async {
      late Directory tmp;
      late Database db;
      late Repo repo;
      late SyncEngine engine;
      late ProviderContainer container;
      late int customerId;

      await tester.runAsync(() async {
        tmp = await Directory.systemTemp.createTemp('nexora_acc_detail_');
        db = await databaseFactory.openDatabase(
          '${tmp.path}/ui.db',
          options: OpenDatabaseOptions(
            onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          ),
        );
        await AppDatabase.createSchema(db);
        await AppDatabase.ensureLatestColumns(db);
        repo = Repo(databaseProvider: () async => db);
        await repo.initSyncInfra();

        final now = DateTime(2026, 11, 10, 10, 30);
        customerId = await repo.saveAccount(
          Account(
            name: 'أحمد عبد الله المنصوري',
            kind: AccountKind.customer,
            currency: 'YER',
            notifyChannel: 'none',
            createdAt: now,
            updatedAt: now,
          ),
        );

        // 1. Add a credit sales invoice with linked items and a long description
        await repo.saveTx(
          Tx(
            accountId: customerId,
            accountKind: AccountKind.customer,
            type: OpType.debit,
            amount: 1500,
            currency: 'YER',
            description:
                'فاتورة مبيعات آجلة شاملة لشاشات وبطاريات صيانة أصلية مع الضمان الكامل',
            reference: 'INV-101',
            notes: 'ملاحظات تفصيلية للفاتورة الأولى',
            date: now,
            createdAt: now,
            updatedAt: now,
          ),
          items: const [
            InvoiceLine(
              name: 'شاشة سامسونج A52 وكالة',
              quantity: 1,
              unit: 'حبة',
              unitPrice: 1000,
            ),
            InvoiceLine(
              name: 'بطارية داخلية أصلية',
              quantity: 1,
              unit: 'حبة',
              unitPrice: 500,
            ),
          ],
          deductStock: false,
        );

        // 2. Add a second debit transaction to test editing and deletion
        await repo.saveTx(
          Tx(
            accountId: customerId,
            accountKind: AccountKind.customer,
            type: OpType.debit,
            amount: 500,
            currency: 'YER',
            description: 'دفعة بضاعة إضافية على الحساب',
            reference: 'INV-102',
            date: now.add(const Duration(minutes: 10)),
            createdAt: now.add(const Duration(minutes: 10)),
            updatedAt: now.add(const Duration(minutes: 10)),
          ),
        );

        engine = SyncEngine(repo: repo, dbProvider: () async => db);
        container = ProviderContainer(
          overrides: [
            repoProvider.overrideWithValue(repo),
            syncEngineProvider.overrideWithValue(engine),
          ],
        );

        await Future.wait([
          container.read(settingsProvider.future),
          container.read(allAccountsProvider.future),
          container.read(currenciesProvider.future),
          container.read(currentUserProvider.future),
          container.read(accountTxProvider(customerId).future),
        ]);
      });

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 960);

      Future<void> pumpFrames([int count = 4]) async {
        for (var i = 0; i < count; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 80));
        }
      }

      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              locale: const Locale('ar'),
              supportedLocales: const [Locale('ar')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: AccountDetailScreen(accountId: customerId),
            ),
          ),
        );
        await pumpFrames(5);

        // Verify customer name is visible in AppBar (not duplicated) and initial balance is 2,000 (1500 + 500)
        expect(find.text('أحمد عبد الله المنصوري'), findsOneWidget);
        expect(find.text('التاريخ'), findsOneWidget);
        expect(find.text('المبلغ'), findsOneWidget);
        expect(find.text('التفاصيل'), findsOneWidget);
        expect(find.text('الرصيد'), findsOneWidget);
        expect(find.textContaining('2,000'), findsWidgets);

        // Verify the transaction rows with 'خيارات العملية' tooltip exist on each row
        final menuButtons = find.byTooltip('خيارات العملية');
        expect(menuButtons, findsNWidgets(2));

        // 1. Open actions sheet on the invoice transaction (INV-101)
        await tester.ensureVisible(menuButtons.last);
        await tester.pump();
        await tester.tap(menuButtons.last);
        await pumpFrames(4);

        // Verify all required actions are visible in the bottom sheet
        expect(
          find.text('عرض التفاصيل الكاملة / الفاتورة'),
          findsOneWidget,
        );
        expect(find.text('تعديل العملية'), findsOneWidget);
        expect(
          find.text('مشاركة سند الإشعار (واتساب / صورة)'),
          findsOneWidget,
        );
        expect(find.text('معاينة صورة السند'), findsOneWidget);
        expect(
          find.text('طباعة السند / الفاتورة (حرارية / PDF)'),
          findsOneWidget,
        );
        expect(find.text('حذف العملية'), findsOneWidget);

        // 2. Tap 'عرض التفاصيل الكاملة / الفاتورة' and verify full description & invoice items appear
        await tester.tap(find.text('عرض التفاصيل الكاملة / الفاتورة'));
        await pumpFrames(5);

        expect(find.text('تفاصيل الفاتورة والعملية'), findsOneWidget);
        expect(
          find.text(
            'فاتورة مبيعات آجلة شاملة لشاشات وبطاريات صيانة أصلية مع الضمان الكامل',
          ),
          findsOneWidget,
        );
        expect(find.text('شاشة سامسونج A52 وكالة'), findsOneWidget);
        expect(find.text('بطارية داخلية أصلية'), findsOneWidget);

        // Close the details dialog
        await tester.tap(find.text('إغلاق'));
        await pumpFrames(3);

        // 3. Test editing the second transaction (500 -> 800) directly from AccountDetailScreen
        await tester.tap(menuButtons.first);
        await pumpFrames(4);
        await tester.tap(find.text('تعديل العملية'));
        await pumpFrames(6);

        // Find the amount field inside TxForm ('المبلغ *') and change to '800'
        final amountField = find.widgetWithText(TextFormField, 'المبلغ *');
        expect(amountField, findsOneWidget);
        await tester.enterText(amountField, '800');
        await tester.pump();

        final saveBtn = find.text('حفظ العملية');
        expect(saveBtn, findsOneWidget);
        await tester.ensureVisible(saveBtn);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(saveBtn);
        for (var i = 0;
            i < 40 &&
                (find.byType(TxForm).evaluate().isNotEmpty ||
                    find.textContaining('2,300').evaluate().isEmpty);
            i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await pumpFrames(4);

        // Verify TxForm closed and balance updated immediately on AccountDetailScreen to 2,300 (1500 + 800)
        expect(find.byType(TxForm), findsNothing);
        expect(find.textContaining('2,300'), findsWidgets);

        // 4. Test deleting the second transaction (800) directly from AccountDetailScreen
        final updatedMenuButtons = find.byTooltip('خيارات العملية');
        expect(updatedMenuButtons, findsNWidgets(2));
        await tester.tap(updatedMenuButtons.first);
        await pumpFrames(4);

        await tester.tap(find.text('حذف العملية'));
        await pumpFrames(4);

        // Confirm deletion in confirmDialog
        final confirmDeleteBtn = find.widgetWithText(FilledButton, 'حذف');
        expect(confirmDeleteBtn, findsOneWidget);
        await tester.tap(confirmDeleteBtn);
        for (var i = 0;
            i < 40 &&
                find.byTooltip('خيارات العملية').evaluate().length != 1;
            i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await pumpFrames(4);

        // Verify transaction count is now 1 and balance updated immediately to 1,500
        expect(find.byTooltip('خيارات العملية'), findsOneWidget);
        expect(find.textContaining('1,500'), findsWidgets);
        expect(tester.takeException(), isNull);
      } finally {
        await pumpFrames(4);
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpFrames(2);
        engine.stop();
        container.dispose();
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await db.close();
          await tmp.delete(recursive: true);
        });
        await tester.pump(const Duration(seconds: 1));
      }
    },
  );
}
