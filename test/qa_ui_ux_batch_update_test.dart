import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/cloud_config.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/l10n.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/sfx.dart';
import 'package:nexora_app/core/theme.dart';
import 'package:nexora_app/data/daily_harvest_service.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:nexora_app/ui/accounts_screen.dart';
import 'package:nexora_app/ui/dashboard_screen.dart';
import 'package:nexora_app/ui/home_shell.dart';
import 'package:nexora_app/ui/onboarding_screen.dart';
import 'package:nexora_app/ui/reports_screen.dart';
import 'package:nexora_app/ui/settings_screen.dart';
import 'package:nexora_app/ui/transactions_screen.dart';

Future<(Repo, Database, Directory, SyncEngine)> _openFreshRepo(String tag) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final dir = await Directory.systemTemp.createTemp('nexora_ui_ux_$tag');
  final dbFile = p.join(dir.path, 'test.db');
  final db = await databaseFactory.openDatabase(
    dbFile,
    options: OpenDatabaseOptions(
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  await AppDatabase.createSchema(db);
  final repo = Repo(databaseProvider: () async => db);
  await repo.initSyncInfra();
  final engine = SyncEngine(repo: repo, dbProvider: () async => db);
  return (repo, db, dir, engine);
}

Future<ProviderContainer> _createWarmedContainer(
  Repo repo,
  SyncEngine engine,
) async {
  final container = ProviderContainer(
    overrides: [
      repoProvider.overrideWithValue(repo),
      syncEngineProvider.overrideWithValue(engine),
    ],
  );
  await Future.wait([
    container.read(settingsProvider.future),
    container.read(summaryProvider.future),
    container.read(accountsProvider.future),
    container.read(allAccountsProvider.future),
    container.read(accountTxCountsProvider.future),
    container.read(currenciesProvider.future),
    container.read(currentUserProvider.future),
    container.read(usersProvider.future),
    container.read(txPageProvider.future),
    container.read(vouchersProvider.future),
    container.read(recentTxProvider.future),
    container.read(alertsProvider.future),
    container.read(devicesProvider.future),
    container.read(isOwnerProvider.future),
    container.read(countsProvider.future),
    container.read(itemCategoriesProvider.future),
    container.read(itemsProvider.future),
    container.read(inventorySummaryProvider.future),
    container.read(reportDataProvider.future),
  ]);
  return container;
}

Widget _wrapWithContainer(ProviderContainer container, Widget home) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light(),
      home: Scaffold(body: home),
    ),
  );
}

Future<void> _pumpRealAsync(WidgetTester tester, {int cycles = 4}) async {
  for (var i = 0; i < cycles; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  debugDefaultBackendUrlOverride = '';
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUpAll(() async {
    await initializeDateFormatting('ar');
    await initializeDateFormatting('en');
    Sfx.setMuted(true);
  });

  group('QA — حزمة تحديثات الواجهة وتجربة المستخدم والتقارير والحصاد اليومي (7 متطلبات)', () {
    testWidgets(
      '1 & 7-أ & 6: فتح التطبيق افتراضياً على «العملاء»، وعرض «عميل نقدي» بدل الشرطة، وأيقونة إخفاء الأرصدة بجانب الرصيد',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(430, 900);

        late Repo repo;
        late Database db;
        late Directory dir;
        late SyncEngine engine;
        late ProviderContainer container;
        await tester.runAsync(() async {
          (repo, db, dir, engine) = await _openFreshRepo('req1_6_7a');
          final now = DateTime.now();
          await repo.saveTx(
            Tx(
              type: OpType.expense,
              accountId: null,
              amount: 3500,
              currency: 'YER',
              description: 'مشتريات سريعة',
              date: now,
              createdAt: now,
              updatedAt: now,
            ),
          );
          container = await _createWarmedContainer(repo, engine);
        });

        try {
          // 1) التحقق من أن الشاشة الافتراضية عند فتح HomeShell هي قسم «العملاء» (AppScreen.accounts)
          expect(kDefaultInitialHomeScreen, AppScreen.accounts);

          // 2) فتح DashboardScreen والتحقق من ظهور «عميل نقدي» بدل «—» وأيقونة العين المدمجة بجانب الرصيد
          await tester.pumpWidget(
            _wrapWithContainer(container, const DashboardScreen()),
          );
          await _pumpRealAsync(tester);

          expect(find.text('عميل نقدي'), findsWidgets);
          expect(find.text('—'), findsNothing);
          final eyeBtn = find.byKey(const ValueKey('toggle_hide_balances_btn'));
          expect(eyeBtn, findsOneWidget);
          await tester.tap(eyeBtn);
          await tester.pump();
          expect(find.text('••••••'), findsWidgets);
        } finally {
          engine.stop();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 15));
          container.dispose();
          await tester.runAsync(() async {
            await db.close();
            await dir.delete(recursive: true);
          });
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );

    testWidgets(
      '5 & 7-ب & 7-ج & 7-د: شاشة العملاء — الشريط العلوي الموحّد، أيقونة الشخص، ألوان ومسمى «عليه» (أحمر) و«له» (أزرق)، وتناوب ألوان البطاقات',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(430, 900);

        late Repo repo;
        late Database db;
        late Directory dir;
        late SyncEngine engine;
        late ProviderContainer container;
        await tester.runAsync(() async {
          (repo, db, dir, engine) = await _openFreshRepo('req5_7bcd');
          final now = DateTime.now();
          final debtorId = await repo.saveAccount(
            Account(
              name: 'أحمد صالح',
              kind: AccountKind.customer,
              currency: 'YER',
              phone: '777111222',
              createdAt: now,
              updatedAt: now,
            ),
          );
          final creditorId = await repo.saveAccount(
            Account(
              name: 'خالد منصور',
              kind: AccountKind.customer,
              currency: 'YER',
              phone: '777333444',
              createdAt: now,
              updatedAt: now,
            ),
          );

          // عملية تجعل «أحمد صالح» مديناً (عليه > 0)
          await repo.saveTx(
            Tx(
              type: OpType.debit,
              accountId: debtorId,
              amount: 5000,
              currency: 'YER',
              description: 'فاتورة آجلة',
              date: now,
              createdAt: now,
              updatedAt: now,
            ),
          );
          // عملية تجعل «خالد منصور» دائناً (له < 0)
          await repo.saveTx(
            Tx(
              type: OpType.credit,
              accountId: creditorId,
              amount: 2500,
              currency: 'YER',
              description: 'دفعة مقدمة',
              date: now,
              createdAt: now,
              updatedAt: now,
            ),
          );
          container = await _createWarmedContainer(repo, engine);
        });

        try {
          await tester.pumpWidget(
            _wrapWithContainer(container, const AccountsScreen()),
          );
          await _pumpRealAsync(tester);

          // المتطلب 5: وجود بادج التصفية الموحد + أيقونة البحث المصغرة + زر (+) بدون نص
          expect(
            find.byKey(const ValueKey('accounts_unified_filter_badge')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('accounts_search_icon_badge')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('accounts_add_btn')),
            findsOneWidget,
          );
          expect(find.text('حساب جديد'), findsNothing);

          // المتطلب 7-ب: أيقونة الشخص القياسية بدلاً من الحروف الأولى
          expect(find.byIcon(Icons.person_rounded), findsWidgets);
          expect(find.text('أص'), findsNothing);
          expect(find.text('خم'), findsNothing);

          // المتطلب 7-ج: ظهور «عليه» (وليس «عليكم») باللون الأحمر، و«له» باللون الأخضر
          expect(find.text('عليكم'), findsNothing);
          expect(find.text('لكم'), findsNothing);
          final debtLabel = tester.widget<Text>(find.text('عليه').first);
          expect(debtLabel.style?.color, const Color(0xFFEF4444));
          final creditLabel = tester.widget<Text>(find.text('له').first);
          expect(creditLabel.style?.color, const Color(0xFF10B981));

          // المتطلب 7-د: تلوين متناوب للبطاقات بين الأبيض والتركواز الفاتح الهادئ
          final containers = tester
              .widgetList<Container>(find.byType(Container))
              .where((c) {
            final dec = c.decoration;
            return dec is BoxDecoration &&
                (dec.color == Colors.white ||
                    dec.color == const Color(0xFFE6F7F5));
          }).toList();
          expect(
            containers.any(
              (c) => (c.decoration as BoxDecoration).color == Colors.white,
            ),
            isTrue,
          );
          expect(
            containers.any(
              (c) =>
                  (c.decoration as BoxDecoration).color ==
                  const Color(0xFFE6F7F5),
            ),
            isTrue,
          );

          // النقر على أيقونة البحث يمدد حقل النص
          await tester.tap(
            find.byKey(const ValueKey('accounts_search_icon_badge')),
          );
          await tester.pump();
          expect(
            find.byKey(const ValueKey('accounts_search_field')),
            findsOneWidget,
          );
        } finally {
          engine.stop();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 15));
          container.dispose();
          await tester.runAsync(() async {
            await db.close();
            await dir.delete(recursive: true);
          });
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );

    testWidgets(
      '2-أ & 3 & 7-د: شاشة العمليات — فلتر الفترات لبطاقتي (وارد/صادر)، البادج الموحد المصغر، وملخص الأصناف والمنفذ',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(430, 900);

        late Repo repo;
        late Database db;
        late Directory dir;
        late SyncEngine engine;
        late ProviderContainer container;
        await tester.runAsync(() async {
          (repo, db, dir, engine) = await _openFreshRepo('req2a_3_7d');
          final now = DateTime.now();
          final threeDaysAgo = now.subtract(const Duration(days: 3));

          // عملية اليوم
          final todayTxId = await repo.saveTx(
            Tx(
              type: OpType.revenue,
              accountId: null,
              amount: 4000,
              currency: 'YER',
              description: 'فاتورة نقدية مدفوعة',
              date: now,
              cashierName: 'محمد الكاشير',
              createdAt: now,
              updatedAt: now,
            ),
          );
          for (final name in [
            'حليب نادك',
            'خبز أبيض',
            'جبن شيدر',
            'عصير برتقال',
          ]) {
            await db.insert('transaction_items', {
              'workspace_id': 'default',
              'tx_id': todayTxId,
              'name': name,
              'unit': 'حبة',
              'quantity': 1,
              'unit_price': 1000,
              'total': 1000,
            });
          }

          // عملية قبل 3 أيام
          await repo.saveTx(
            Tx(
              type: OpType.revenue,
              accountId: null,
              amount: 6000,
              currency: 'YER',
              description: 'مبيعات سابقة',
              date: threeDaysAgo,
              cashierName: 'سالم',
              createdAt: threeDaysAgo,
              updatedAt: threeDaysAgo,
            ),
          );
          container = await _createWarmedContainer(repo, engine);
        });

        try {
          await tester.pumpWidget(
            _wrapWithContainer(container, const TransactionsScreen()),
          );
          await _pumpRealAsync(tester);

          // المتطلب 2-أ: افتراضياً الفترة «يومي» وتعرض حركة اليوم فقط (4,000)
          expect(find.textContaining('وارد (YER) • يومي'), findsOneWidget);
          expect(find.textContaining('صادر (YER) • يومي'), findsOneWidget);

          // المتطلب 3: عدم وجود البادجات الثلاثة القديمة، ووجود البادج الموحد المصغر + ملخص الأصناف + اسم المنفذ
          expect(find.text('ناجحة'), findsNothing);
          expect(find.text('بانتظار المزامنة'), findsNothing);
          expect(find.textContaining('✓ 1/1'), findsWidgets);
          expect(find.textContaining('حليب نادك، خبز أبيض +2'), findsOneWidget);
          expect(find.textContaining('محمد الكاشير'), findsOneWidget);

          // النقر على بطاقة «وارد» واختيار «أسبوعي» يحدّث العنوان والإجمالي ليشمل عملية قبل 3 أيام (10,000)
          await tester.tap(find.textContaining('وارد (YER) • يومي'));
          await _pumpRealAsync(tester, cycles: 3);
          await tester.tap(find.text('أسبوعي'));
          await tester.runAsync(() async {
            await container.read(txPageProvider.future);
          });
          await _pumpRealAsync(tester, cycles: 3);

          expect(find.textContaining('وارد (YER) • أسبوعي'), findsOneWidget);
          expect(find.text('10,000'), findsOneWidget);
        } finally {
          engine.stop();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 15));
          container.dispose();
          await tester.runAsync(() async {
            await db.close();
            await dir.delete(recursive: true);
          });
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );

    test(
      '2-ب: نظام إشعار الحصاد اليومي الذكي — شروط الظهور، صلاحيات المدير مقابل العضو، والعمود seen',
      () async {
        final (repo, db, dir, engine) = await _openFreshRepo('req2b_harvest');
        addTearDown(() async {
          engine.stop();
          try {
            await db.close();
          } catch (e) {
            debugPrint('close db error: $e');
          }
          try {
            await dir.delete(recursive: true);
          } catch (e) {
            debugPrint('delete dir error: $e');
          }
        });

        final now = DateTime.now();

        // 1) بدون أصناف مدخلة في المخزون -> لا يظهر الإشعار أبداً
        final emptyEval = await DailyHarvestService.evaluate(repo);
        expect(emptyEval.shouldShow, isFalse);
        expect(await DailyHarvestService.checkAndNotify(repo), isNull);

        // 2) إدخال صنف في المخزون ولكن المبيعات = 0 -> لا يظهر الإشعار
        await repo.saveItem(
          Item(
            name: 'أرز بسمتي',
            sku: 'SKU-100',
            sellPrice: 5000,
            buyPrice: 4000,
            quantity: 20,
            createdAt: now,
            updatedAt: now,
          ),
        );
        final zeroSalesEval = await DailyHarvestService.evaluate(repo);
        expect(zeroSalesEval.shouldShow, isFalse);
        expect(await DailyHarvestService.checkAndNotify(repo), isNull);

        // تسجيل جهاز عضو ومبيعات خاصة بالمدير ومبيعات خاصة بالعضو
        await db.insert('devices', {
          'id': 'dev-member-2',
          'workspace_id': 'default',
          'name': 'كاشير الفرع',
          'is_paired': 1,
          'is_owner': 0,
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        });

        // فاتورة نفذها المدير (5,000)
        await repo.saveTx(
          Tx(
            type: OpType.revenue,
            accountId: null,
            amount: 5000,
            currency: 'YER',
            description: 'فاتورة نقدية مدفوعة #1',
            date: now,
            cashierName: 'المدير العام',
            createdAt: now,
            updatedAt: now,
          ),
        );

        // فاتورة نفذها العضو (3,000)
        final memberTxId = await db.insert('transactions', {
          'workspace_id': 'default',
          'type': 'revenue',
          'amount': 3000,
          'currency': 'YER',
          'description': 'فاتورة نقدية مدفوعة #2',
          'date': now.toIso8601String(),
          'status': 'done',
          'sync_state': 'synced',
          'cashier_name': 'كاشير الفرع',
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        });
        await db.insert('operations', {
          'id': 'op-member-tx-$memberTxId',
          'workspace_id': 'default',
          'device_id': 'dev-member-2',
          'entity_type': 'tx',
          'entity_id': '$memberTxId',
          'op_type': 'create',
          'payload': '{}',
          'device_time': now.toIso8601String(),
          'timestamp': now.toIso8601String(),
        });

        // 3) تقييم المدير: يعرض إجمالي مبيعات المتجر بالكامل (5000 + 3000 = 8000) وعدد الفواتير (2)
        final managerSummary = await DailyHarvestService.evaluate(
          repo,
          isManagerOverride: true,
        );
        expect(managerSummary.shouldShow, isTrue);
        expect(managerSummary.totalSales, 8000);
        expect(managerSummary.invoiceCount, 2);
        expect(managerSummary.title, isNotEmpty);
        expect(managerSummary.message, isNotEmpty);

        // إصدار الإشعار والتحقق من حفظه في جدول notifications بالعمود seen = 0
        final emitted = await DailyHarvestService.checkAndNotify(
          repo,
          isManagerOverride: true,
        );
        expect(emitted, isNotNull);
        final notifRows = await db.query(
          'notifications',
          where: "kind = 'daily_harvest'",
        );
        expect(notifRows, isNotEmpty);
        expect(notifRows.first['seen'], 0);

        // 4) تقييم العضو: يعرض مبيعات المدير/العضو المنفذ على جهازه فقط دون كشف مبيعات بقية الأجهزة
        final memberSummary = await DailyHarvestService.evaluate(
          repo,
          isManagerOverride: false,
        );
        expect(memberSummary.shouldShow, isTrue);
        expect(memberSummary.totalSales, 5000);
        expect(memberSummary.invoiceCount, 1);
      },
    );

    testWidgets(
      '4: شاشة التقارير — الشريط العلوي الموحد وشبكة البطاقات الأربع التفاعلية (2×2) مع دمج عدد العمليات',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(430, 900);

        late Repo repo;
        late Database db;
        late Directory dir;
        late SyncEngine engine;
        late ProviderContainer container;
        await tester.runAsync(() async {
          (repo, db, dir, engine) = await _openFreshRepo('req4_reports');
          final now = DateTime.now();
          final custId = await repo.saveAccount(
            Account(
              name: 'عميل التقارير',
              kind: AccountKind.customer,
              currency: 'YER',
              createdAt: now,
              updatedAt: now,
            ),
          );
          await repo.saveTx(
            Tx(
              type: OpType.debit,
              accountId: custId,
              amount: 7500,
              currency: 'YER',
              description: 'فاتورة مبيعات تقارير',
              date: now,
              createdAt: now,
              updatedAt: now,
            ),
          );
          container = await _createWarmedContainer(repo, engine);
        });

        try {
          await tester.pumpWidget(
            _wrapWithContainer(container, const ReportsScreen()),
          );
          await _pumpRealAsync(tester);

          // 4-أ: شريط علوي واحد يضم بادج التاريخ وبادج «تصفية وعرض»
          expect(
            find.byKey(const ValueKey('reports_date_range_badge')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('reports_unified_filter_badge')),
            findsOneWidget,
          );

          // 4-ب: شبكة 2×2 للبطاقات الأربع مع دمج «عدد العمليات» كعنصر فرعي داخل «إجمالي المبيعات»
          expect(find.byKey(const ValueKey('report_card_sales')), findsOneWidget);
          expect(
            find.byKey(const ValueKey('report_card_owed_to_us')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('report_card_owed_by_us')),
            findsOneWidget,
          );
          expect(find.byKey(const ValueKey('report_card_net')), findsOneWidget);
          expect(find.textContaining('عدد العمليات: 1'), findsOneWidget);

          // النقر على بطاقة «إجمالي المبيعات» يميزها ويحدث الجدول لعرض عمليات المبيعات
          await tester.tap(find.byKey(const ValueKey('report_card_sales')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          expect(find.text('فاتورة مبيعات تقارير'), findsOneWidget);

          // النقر على بطاقة «إجمالي المستحق لنا» يحدث الجدول لعرض الحسابات المدينة
          await tester.tap(
            find.byKey(const ValueKey('report_card_owed_to_us')),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          expect(find.textContaining('عميل التقارير'), findsOneWidget);
        } finally {
          engine.stop();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 15));
          container.dispose();
          await tester.runAsync(() async {
            await db.close();
            await dir.delete(recursive: true);
          });
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );

    testWidgets(
      'شاشة تسجيل الدخول وإدارة الحساب (OnboardingScreen) — الأزرار المختصرة، أيقونة QR المدمجة، إزالة زر الحذف الكامل، ورسائل الأخطاء الصريحة',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(430, 900);

        // 1) التحقق من تصنيف رسائل الأخطاء الصريحة الثلاث بدقة
        expect(
          classifyOnboardingAuthError(
            const SocketException('Failed host lookup'),
          ),
          'لا يوجد اتصال بالإنترنت، يرجى التحقق من الشبكة',
        );
        expect(
          classifyOnboardingAuthError(StateError('INVALID_PASSWORD')),
          'خطأ في البريد الإلكتروني / رقم الهاتف أو كلمة المرور',
        );
        expect(
          classifyOnboardingAuthError(
            StateError('INVALID_CREDENTIALS_OR_NOT_FOUND:INVALID_LOGIN_CREDENTIALS'),
          ),
          'خطأ في البريد الإلكتروني / رقم الهاتف أو كلمة المرور',
        );
        expect(
          classifyOnboardingAuthError(StateError('USER_NOT_FOUND')),
          'لم يتم العثور على حسابك أو أي منشأة مرتبطة بهذا الحساب',
        );
        expect(
          classifyOnboardingAuthError(null, isWorkspaceNotFound: true),
          'لم يتم العثور على حسابك أو أي منشأة مرتبطة بهذا الحساب',
        );

        late Repo repo;
        late Database db;
        late Directory dir;
        late SyncEngine engine;
        late ProviderContainer container;
        await tester.runAsync(() async {
          (repo, db, dir, engine) = await _openFreshRepo('onboarding_ui');
          container = await _createWarmedContainer(repo, engine);
        });

        try {
          await tester.pumpWidget(
            _wrapWithContainer(container, const OnboardingScreen()),
          );
          await _pumpRealAsync(tester);

          // التحقق من اختصار الأزرار وإزالة الأزرار القديمة
          expect(find.text('تسجيل جديد'), findsOneWidget);
          expect(find.text('تسجيل حساب جديد وتأسيس منشأة'), findsNothing);

          expect(find.text('الدخول بدون حساب'), findsOneWidget);
          expect(find.text('الاستخدام المحلي المستقل'), findsNothing);

          // وجود زر أيقونة باركود QR مصغر بدون نص بجانب زر «الدخول بدون حساب»
          expect(
            find.byKey(const ValueKey('onboarding_qr_join_btn')),
            findsOneWidget,
          );
          expect(
            find.text('انضمام كعضو لمحل قائم (رمز / باركود QR)'),
            findsNothing,
          );

          // إزالة زر «حذف كامل من الجهاز والسحابة» تماماً من أسفل الشاشة
          expect(find.text('حذف كامل من الجهاز والسحابة'), findsNothing);
        } finally {
          engine.stop();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 15));
          container.dispose();
          await tester.runAsync(() async {
            await db.close();
            await dir.delete(recursive: true);
          });
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );

    testWidgets(
      'نظام اللغات (العربية / English) — تبديل اللغة من الإعدادات، الحفظ في SharedPreferences، وتحديث اتجاه الواجهة RTL / LTR فوراً',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(430, 900);
        SharedPreferences.setMockInitialValues({});

        late Repo repo;
        late Database db;
        late Directory dir;
        late SyncEngine engine;
        late ProviderContainer container;
        await tester.runAsync(() async {
          (repo, db, dir, engine) = await _openFreshRepo('l10n_switch');
          container = await _createWarmedContainer(repo, engine);
        });

        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: Consumer(
                builder: (context, ref, _) {
                  final loc = ref.watch(appLocaleProvider);
                  final isEn = loc.languageCode == 'en';
                  return MaterialApp(
                    locale: loc,
                    supportedLocales: AppLocalizations.supportedLocales,
                    localizationsDelegates: const [
                      AppLocalizations.delegate,
                      GlobalMaterialLocalizations.delegate,
                      GlobalWidgetsLocalizations.delegate,
                      GlobalCupertinoLocalizations.delegate,
                    ],
                    builder: (context, child) => Directionality(
                      textDirection:
                          isEn ? TextDirection.ltr : TextDirection.rtl,
                      child: child ?? const SizedBox.shrink(),
                    ),
                    home: const Scaffold(body: SettingsScreen()),
                  );
                },
              ),
            ),
          );
          await _pumpRealAsync(tester);

          // افتراضياً: اللغة العربية واتجاه RTL
          expect(container.read(appLocaleProvider).languageCode, 'ar');
          expect(
            Directionality.of(tester.element(find.byType(SettingsScreen))),
            TextDirection.rtl,
          );
          expect(
            find.byKey(const ValueKey('settings_language_card')),
            findsOneWidget,
          );
          expect(find.text('بيانات المؤسسة'), findsOneWidget);

          // النقر على خيار English لتبديل اللغة فوراً
          await tester.tap(find.byKey(const ValueKey('lang_option_en')));
          await _pumpRealAsync(tester, cycles: 2);

          expect(container.read(appLocaleProvider).languageCode, 'en');
          expect(
            Directionality.of(tester.element(find.byType(SettingsScreen))),
            TextDirection.ltr,
          );
          expect(find.text('Business Profile'), findsOneWidget);

          final sp = await SharedPreferences.getInstance();
          expect(sp.getString('app_locale'), 'en');

          // العودة إلى العربية
          await tester.tap(find.byKey(const ValueKey('lang_option_ar')));
          await _pumpRealAsync(tester, cycles: 2);

          expect(container.read(appLocaleProvider).languageCode, 'ar');
          expect(
            Directionality.of(tester.element(find.byType(SettingsScreen))),
            TextDirection.rtl,
          );
          expect(find.text('بيانات المؤسسة'), findsOneWidget);
          expect(sp.getString('app_locale'), 'ar');
        } finally {
          engine.stop();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 15));
          container.dispose();
          await tester.runAsync(() async {
            await db.close();
            await dir.delete(recursive: true);
          });
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );
  });
}
