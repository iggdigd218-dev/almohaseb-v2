// QA — اختبارات التدقيق الشامل (الجزء الثاني: المحاسبة A1–A8، الأمان SEC1–SEC8، الواجهة والطباعة U1–U6)
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/app_version.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/format.dart';
import 'package:nexora_app/core/l10n.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/security.dart';
import 'package:nexora_app/core/thermal_invoice_doc.dart';
import 'package:nexora_app/data/pos_cart.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/subscription_guard.dart';
import 'package:nexora_app/ui/reports_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;
  final now = DateTime(2026, 11, 10, 12, 0);
  final nowIso = now.toIso8601String();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('qa_audit_part2_');
    db = await databaseFactory.openDatabase('${tmp.path}/audit_part2.db');
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.setSetting('sync.deviceId', 'DEV-AUDIT-2');
    await repo.initSyncInfra();
    await db.insert(
      'users',
      {
        'id': 1,
        'name': 'المدير',
        'role': 'admin',
        'permissions': '',
        'is_me': 1,
        'active': 1,
        'created_at': nowIso,
        'updated_at': nowIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.update('devices', {'user_id': 1, 'is_owner': 1});
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('المحور الأول: التدقيق المحاسبي (A1–A8)', () {
    test('A1 المرتجع على فاتورة مخصومة يطبّق نسبة الخصم ويمنع تجاوز الصافي التراكمي', () async {
      final custId = await repo.saveAccount(
        Account(
          name: 'عميل خصم',
          kind: AccountKind.customer,
          currency: 'YER',
          notifyChannel: 'none',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final itemId = await repo.saveItem(
        Item(
          name: 'صنف تجريبي',
          buyPrice: 600,
          sellPrice: 1000,
          quantity: 10,
          createdAt: now,
          updatedAt: now,
        ),
      );

      // فاتورة: قطعتان × 1000 = 2000 قبل الخصم، بخصم 10% => الصافي 1800
      final invId = await repo.saveTx(
        Tx(
          type: OpType.debit,
          accountId: custId,
          amount: 1800,
          currency: 'YER',
          description: 'فاتورة مبيعات #INV-100',
          reference: 'INV-100',
          date: now,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.insert('transaction_items', {
        'tx_id': invId,
        'item_id': itemId,
        'name': 'صنف تجريبي',
        'quantity': 2.0,
        'unit_price': 1000.0,
        'total': 2000.0,
      });

      final invTx = (await repo.transactions(accountId: custId))
          .firstWhere((t) => t.id == invId);

      // إرجاع قطعة واحدة بسعر الوحدة الخام (1000) -> يجب تطبيق نسبة الخصم (1800/2000 = 0.9) => 900
      final ret1Id = await repo.processSalesReturn(
        originalTx: invTx,
        returnLines: [
          InvoiceLine(
            itemId: itemId,
            name: 'صنف تجريبي',
            quantity: 1,
            unitPrice: 1000,
            total: 1000,
          ),
        ],
        refundCash: false,
      );
      final ret1Tx = (await repo.transactions(accountId: custId))
          .firstWhere((t) => t.id == ret1Id);
      expect(ret1Tx.amount, closeTo(900, 0.01));

      // إرجاع بمبلغ يتجاوز المتبقي من صافي الفاتورة يُرفض
      await expectLater(
        repo.processSalesReturn(
          originalTx: invTx,
          returnLines: [
            InvoiceLine(
              itemId: itemId,
              name: 'صنف تجريبي',
              quantity: 1,
              unitPrice: 1500,
              total: 1500,
            ),
          ],
          refundCash: false,
        ),
        throwsArgumentError,
      );

      final ret2Id = await repo.processSalesReturn(
        originalTx: invTx,
        returnLines: [
          InvoiceLine(
            itemId: itemId,
            name: 'صنف تجريبي',
            quantity: 1,
            unitPrice: 1000,
            total: 1000,
          ),
        ],
        refundCash: false,
      );
      final ret2Tx = (await repo.transactions(accountId: custId))
          .firstWhere((t) => t.id == ret2Id);
      expect(ret2Tx.amount, closeTo(900, 0.01));
    });

    test('A2 المرتجع بصنف معرفه محذوف لا يرحّل رصيده إلى صنف آخر بنفس الاسم', () async {
      final custId = await repo.saveAccount(
        Account(
          name: 'عميل أمان الأصناف',
          kind: AccountKind.customer,
          currency: 'YER',
          notifyChannel: 'none',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final newItemId = await repo.saveItem(
        Item(
          name: 'شاشة',
          buyPrice: 3000,
          sellPrice: 5000,
          quantity: 4,
          createdAt: now,
          updatedAt: now,
        ),
      );
      const deletedOldId = 999999; // صنف غير موجود في جدول items
      final invId = await repo.saveTx(
        Tx(
          type: OpType.debit,
          accountId: custId,
          amount: 5000,
          currency: 'YER',
          description: 'فاتورة مبيعات #INV-DEL',
          reference: 'INV-DEL',
          date: now,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.insert('transaction_items', {
        'tx_id': invId,
        'item_id': deletedOldId,
        'name': 'شاشة',
        'quantity': 1.0,
        'unit_price': 5000.0,
        'total': 5000.0,
      });
      final invTx = (await repo.transactions(accountId: custId))
          .firstWhere((t) => t.id == invId);

      await repo.processSalesReturn(
        originalTx: invTx,
        returnLines: const [
          InvoiceLine(
            itemId: deletedOldId,
            name: 'شاشة',
            quantity: 1,
            unitPrice: 5000,
            total: 5000,
          ),
        ],
        refundCash: false,
      );

      final intactItem =
          (await repo.items()).firstWhere((i) => i.id == newItemId);
      expect(intactItem.quantity, equals(4.0),
          reason: 'ممنوع إرجاع كمية إلى صنف آخر بمجرد تطابق الاسم عند غياب المعرف الصريح');
    });

    test('A3 & A6 reportDataProvider يعزل العملات ويحسب الأرصدة شاملةً حركات ما قبل الفترة', () async {
      await db.update('currencies', {'decimal': 2},
          where: 'code = ?', whereArgs: ['USD']);
      final custUsd = await repo.saveAccount(
        Account(
          name: 'عميل دولار',
          kind: AccountKind.customer,
          currency: 'USD',
          openingBalance: 10,
          notifyChannel: 'none',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final preDate = DateTime(2026, 10, 15, 10, 0);
      final inDate = DateTime(2026, 11, 10, 10, 0);

      // حركة قبل الفترة: دين بالـ USD بمبلغ 25.55
      await repo.saveTx(
        Tx(
          type: OpType.debit,
          accountId: custUsd,
          amount: 25.55,
          currency: 'USD',
          description: 'رصيد سابق',
          date: preDate,
          createdAt: preDate,
          updatedAt: preDate,
        ),
      );
      // حركة بعملة أخرى YER على حساب USD يجب ألا تُجمع كدولار (توافق allBalances)
      await repo.saveTx(
        Tx(
          type: OpType.debit,
          accountId: custUsd,
          amount: 10000,
          currency: 'YER',
          description: 'حركة عملة مخالفة',
          date: inDate,
          createdAt: inDate,
          updatedAt: inDate,
        ),
      );
      // دفعة داخل الفترة: سداد 5.55 USD
      await repo.saveTx(
        Tx(
          type: OpType.credit,
          accountId: custUsd,
          amount: 5.55,
          currency: 'USD',
          description: 'دفعة',
          date: inDate,
          createdAt: inDate,
          updatedAt: inDate,
        ),
      );

      final container = ProviderContainer(
        overrides: [repoProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      container.read(reportScopeProvider.notifier).state = ReportScope(
        from: DateTime(2026, 11, 1),
        to: DateTime(2026, 11, 30, 23, 59, 59),
      );

      final rd = await container.read(reportDataProvider.future);
      // 10 opening + 25.55 pre - 5.55 in = 30.00 (ignoring mismatched 10000 YER)
      expect(rd.balances[custUsd], closeTo(30.0, 0.001));
    });

    test('A4 & A5 & A8 بناء التقارير يفصل العملات ويفصل الأرباح التشغيلية عن التدفقات ويحصر المبيعات', () {
      final cust = Account(
        id: 1,
        name: 'أحمد',
        kind: AccountKind.customer,
        currency: 'YER',
        notifyChannel: 'none',
        createdAt: now,
        updatedAt: now,
      );
      final data = ReportData(
        accounts: [cust],
        balances: const {1: 0},
        txCount: const {1: 4},
        posTxIds: const {101},
        txs: [
          // فاتورة مبيعات POS بـ YER (تُحسب مبيعات + إيراد تشغيلي)
          Tx(
            id: 101,
            type: OpType.revenue,
            accountId: 1,
            amount: 1000,
            currency: 'YER',
            description: 'فاتورة مبيعات #1',
            date: now,
            createdAt: now,
            updatedAt: now,
          ),
          // قيد دين عميل يدوي بـ USD (ليس مبيعات ولا إيراد تشغيل!)
          Tx(
            id: 102,
            type: OpType.debit,
            accountId: 1,
            amount: 50,
            currency: 'USD',
            description: 'دين عميل قديم',
            date: now,
            createdAt: now,
            updatedAt: now,
          ),
          // مصروف تشغيلي بـ YER
          Tx(
            id: 103,
            type: OpType.expense,
            amount: 300,
            currency: 'YER',
            description: 'كهرباء',
            category: 'تشغيل',
            date: now,
            createdAt: now,
            updatedAt: now,
          ),
          // مقبوض (تدفق نقدي وليس إيراد تشغيل) بـ USD
          Tx(
            id: 104,
            type: OpType.inflow,
            amount: 20,
            currency: 'USD',
            description: 'توريد صندوق',
            date: now,
            createdAt: now,
            updatedAt: now,
          ),
        ],
      );

      const currencies = [
        CurrencyDef('YER', 'ريال يمني', 'ر.ي', 0),
        CurrencyDef('USD', 'دولار', '\$', 2),
      ];

      // A8: بطاقة المبيعات تحتوي فقط فاتورة المبيعات وليس قيد الدين اليدوي
      final salesDetail =
          buildCardDetailTable(ReportSummaryCard.sales, data, currencies);
      expect(salesDetail.rows, hasLength(1));
      expect(salesDetail.rows.first.join(' '), contains('1,000'));

      // A4 & A5: تقرير الأرباح والخسائر يعزل YER عن USD ولا يدخل التدفقات النقدية في صافي الربح التشغيلي
      final pl = buildReport(ReportTab.pl, data, currencies, PeriodUnit.day);
      final opRevYer =
          pl.rows.firstWhere((r) => r.first.contains('الإيرادات التشغيلية') && r.first.contains('ر.ي'));
      final opExpYer =
          pl.rows.firstWhere((r) => r.first.contains('المصروفات التشغيلية') && r.first.contains('ر.ي'));
      final opNetYer =
          pl.rows.firstWhere((r) => r.first.contains('صافي الربح التشغيلي') && r.first.contains('ر.ي'));
      final opNetUsd =
          pl.rows.firstWhere((r) => r.first.contains('صافي الربح التشغيلي') && r.first.contains('\$'));
      final cashInUsd =
          pl.rows.firstWhere((r) => r.first.contains('التدفقات النقدية (القبض)') && r.first.contains('\$'));

      expect(opRevYer[1], contains('1,000'));
      expect(opExpYer[1], contains('300'));
      expect(opNetYer[1], contains('700'));
      expect(opNetUsd[1], isNot(contains('20.00')),
          reason: 'التدفق النقدي (inflow) لا يُحسب ضمن صافي الربح التشغيلي');
      expect(cashInUsd[1], contains('20.00'));

      // A5: التقرير الملخص لا يجمع YER و USD رقمياً معاً
      final summary =
          buildReport(ReportTab.summary, data, currencies, PeriodUnit.day);
      final sumText = summary.summary.map((e) => '${e.$1}: ${e.$2}').join(' | ');
      expect(sumText, isNot(contains('1,050')));
      expect(sumText, isNot(contains('350')));
    });

    test('A7 خصم سلة نقطة البيع يُقرّب حسب منازل العملة العشرية', () {
      final item = Item(
        id: 1,
        name: 'عطر',
        buyPrice: 8,
        sellPrice: 12.345,
        quantity: 10,
        createdAt: now,
        updatedAt: now,
      );
      final draft3 = PosDraft(
        cart: {1: CartEntry(item: item, quantity: 1, unitPrice: 12.345)},
        discountText: '10',
        discountIsPercent: true,
        currencyDecimals: 3,
      );
      expect(draft3.discountValueFor(), equals(1.235));
      expect(draft3.netTotalFor(), equals(11.11));

      final draft0 = draft3.copyWith(currencyDecimals: 0);
      expect(draft0.discountValueFor(), equals(1.0));
      expect(draft0.netTotalFor(), equals(11.0));
    });
  });

  group('المحور الثاني: الأمان وقواعد Firebase والصلاحيات (SEC1–SEC8)', () {
    test('SEC1–SEC4 & SEC6 قواعد Firebase محصّنة ومطابقة بين النسختين', () {
      final r1 = jsonDecode(
          File('firebase/database.rules.json').readAsStringSync()) as Map<String, dynamic>;
      final r2 = jsonDecode(
          File('firebase/rules.license-hardened.json').readAsStringSync()) as Map<String, dynamic>;
      expect(jsonEncode(r1), equals(jsonEncode(r2)));

      final raw = File('firebase/database.rules.json').readAsStringSync();
      expect(raw.contains('.hasChildren()'), isFalse,
          reason: 'تم استبدال ثغرة .hasChildren() بالتحقق الصريح من /members');

      final root = r1['rules'] as Map<String, dynamic>;
      final vouchersRead = (root['vouchers'] as Map<String, dynamic>)['.read'] as String;
      expect(vouchersRead, isNot(equals('auth != null')));
      expect(vouchersRead, contains('auth.token.admin === true'));

      final ws = (root['workspaces'] as Map<String, dynamic>)[r'$ws'] as Map<String, dynamic>;
      final wsWrite = ws['.write'] as String;
      expect(wsWrite, isNot(contains('owner_email')),
          reason: 'المالك لم يعد يملك مسح عقدة الاشتراك كاملةً عبر /workspaces/\$ws');

      expect(ws.containsKey('members'), isTrue);
      final metaRead = (ws['meta'] as Map<String, dynamic>)['.read'] as String;
      expect(metaRead, isNot(equals('auth != null')));
      expect((ws['meta'] as Map<String, dynamic>).containsKey('password_hash'), isTrue);
    });

    test('SEC5 انتهاء الاشتراك المدفوع active بعد مضي expires_at يُحجب تلقائياً', () {
      const nowMs = 1800000000000;
      const expiredPaid = SubscriptionState(
        status: 'active',
        createdAtMs: nowMs - 86400000 * 400,
        expiresAtMs: nowMs - 1000,
        isActive: true,
        isFrozen: false,
        deviceFingerprint: 'FP-TEST',
        serverNowMs: nowMs,
      );
      expect(expiredPaid.expired, isTrue);
      expect(expiredPaid.isSubscribed, isFalse);

      const validPaid = SubscriptionState(
        status: 'active',
        createdAtMs: nowMs - 86400000,
        expiresAtMs: nowMs + 86400000,
        isActive: true,
        isFrozen: false,
        deviceFingerprint: 'FP-TEST',
        serverNowMs: nowMs,
      );
      expect(validPaid.expired, isFalse);
      expect(validPaid.isSubscribed, isTrue);
    });

    test('SEC6 Security.hash يولّد PBKDF2-HMAC-SHA256 ويدعم التحقق وترقية التجزئات القديمة', () {
      final pbkdf2 = Security.hash('StrongPass#2026');
      expect(pbkdf2, startsWith('pbkdf2_sha256\$10000\$'));
      expect(Security.verify('StrongPass#2026', pbkdf2), isTrue);
      expect(Security.verify('WrongPass', pbkdf2), isFalse);
      expect(Security.needsRehash(pbkdf2), isFalse);

      final legacy = sha256.convert(utf8.encode('nexora::oldpass')).toString();
      expect(Security.verify('oldpass', legacy), isTrue);
      expect(Security.needsRehash(legacy), isTrue);
    });

    test('SEC7 & SEC8 صلاحيات Repo.can ورفض تعديل الصلاحيات لغير المدير', () async {
      await db.update('devices', {'is_owner': 0});
      await db.update('users', {'role': 'cashier', 'permissions': 'add_tx'});
      await repo.setSetting('account.email', 'worker@store.com');

      await expectLater(
        repo.upsertUserPermission(email: 'worker@store.com', role: 'admin'),
        throwsStateError,
      );
      await expectLater(
        repo.promoteToDeputy('worker@store.com'),
        throwsStateError,
      );

      await db.insert('user_permissions', {
        'user_email': 'worker@store.com',
        'store_id': repo.requireWorkspaceId,
        'role': 'cashier',
        'can_discount': 0,
        'can_delete_tx': 1,
        'can_view_reports': 0,
        'can_manage_items': 0,
        'is_active': 1,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      expect(await repo.can('can_discount'), isFalse);
      expect(await repo.can('delete_tx'), isTrue);

      await db.update('user_permissions', {'is_active': 0},
          where: 'user_email = ?', whereArgs: ['worker@store.com']);
      expect(await repo.can('delete_tx'), isFalse);
    });
  });

  group('المحور الثالث: العملات، الترجمة، المعاينة والإصدار (U1–U6)', () {
    test('U1 تنسيق المبالغ وبناء الفاتورة الحرارية يلتزم بمنازل العملة العشرية', () async {
      expect(Fmt.money(12.345, 3), equals('12.345'));
      expect(Fmt.money(12.345, 2), equals('12.35'));
      expect(Fmt.money(1250, 0), equals('1,250'));
      expect(Fmt.money(-0.0001, 2), equals('0.00'));

      final doc = await buildThermalInvoiceDocument(
        tx: Tx(
          id: 77,
          type: OpType.revenue,
          amount: 12.345,
          currency: 'KWD',
          description: 'فاتورة مبيعات #77',
          reference: 'INV-77',
          date: now,
          createdAt: now,
          updatedAt: now,
        ),
        account: null,
        lines: const [
          InvoiceLine(
            itemId: 1,
            name: 'بضاعة دقيقة',
            quantity: 1,
            unitPrice: 12.345,
            total: 12.345,
          ),
        ],
        orgName: 'متجر الاختبار',
        orgPhone: '777000111',
        footer: 'شكراً لتعاملكم',
        currencySymbol: 'د.ك',
        currencyDecimals: 3,
      );
      expect(doc.bytes.length, greaterThan(1000));
    });

    test('U4 ترجمة شاشة التقارير إلى الإنجليزية تغطي كافة العناوين والأعمدة والبطاقات', () {
      const en = AppLocalizations(Locale('en'));
      expect(en.text('إجمالي المبيعات'), isNot(equals('إجمالي المبيعات')));
      expect(en.text('صافي المستحق'), isNot(equals('صافي المستحق')));
      expect(en.text('إيراد تشغيلي'), equals('Operating Revenue'));
      expect(en.text('مصروف تشغيلي'), equals('Operating Expense'));
      expect(en.text('صافي الربح التشغيلي'), equals('Net Operating Profit'));
      expect(en.text('عدد العمليات: 5'), equals('Transactions: 5'));
    });

    test('تطابق رقم الإصدار في app_version.dart و pubspec.yaml', () {
      expect(kAppVersion, equals('3.98.50'));
      expect(kAppBuild, equals(365));
      final pub = File('pubspec.yaml').readAsStringSync();
      expect(pub, contains('version: 3.98.50+365'));
    });

    test('منع الفصل الوهمي لمعرفات 64-بت (Snowflake) والشفاء الذاتي للأصناف المفصولة والكميات المصفرّة', () async {
      final resolver = ConflictResolver();
      const origId = 1881078209686363648;
      const splitId = 1881793993336740638;
      const tCreate = '2026-11-10T08:00:00.000Z';
      const tRename = '2026-11-12T10:00:00.000Z';

      // 1. صنف في اللقطة بالاسم المعدّل الأحدث A10e وكمية 5
      await db.insert('items', {
        'id': origId,
        'plu': 101,
        'workspace_id': 'default',
        'name': 'A10e',
        'sku': '10176',
        'unit': 'حبة',
        'buy_price': 2000.0,
        'sell_price': 3000.0,
        'quantity': 5.0,
        'min_quantity': 1.0,
        'is_active': 1,
        'is_deleted': 0,
        'created_at': tCreate,
        'updated_at': tRename,
      });

      // وصول عملية التأسيس التاريخية القديمة بالاسم القديم "شاشة A10e" وكمية 0
      await repo.applyRemoteOperation(
        db,
        const SyncOperation(
          id: 'op-hist-create-a10e',
          workspaceId: 'default',
          deviceId: 'DEV-HOST',
          userId: 1,
          opType: OpKind.create,
          entityType: EntityKind.item,
          entityId: '$origId',
          payload: {
            'id': origId,
            'plu': 101,
            'name': 'شاشة A10e',
            'sku': '10176',
            'unit': 'حبة',
            'buy_price': 2000.0,
            'sell_price': 3000.0,
            'quantity': 0.0,
            'created_at': tCreate,
            'updated_at': tCreate,
          },
          timestamp: tCreate,
          deviceTime: tCreate,
          version: 1,
          parentOpId: '',
        ),
        resolver,
      );

      // لا ينشأ أي تعارض وهمي ولا تتغير الكمية أو الاسم الأحدث
      expect(await repo.pendingItemConflicts(), isEmpty);
      final afterReplay = (await repo.items()).singleWhere((i) => i.id == origId);
      expect(afterReplay.name, equals('A10e'));
      expect(afterReplay.quantity, equals(5.0));

      // 2. محاكاة وجود فصل وهمي سابق في قاعدة البيانات مع تصفير الكمية
      await db.update('items', {'name': 'شاشة A10e', 'quantity': 0.0},
          where: 'id = ?', whereArgs: [origId]);
      await db.insert('items', {
        'id': splitId,
        'plu': 102,
        'workspace_id': 'default',
        'name': 'A10e',
        'sku': '10176',
        'unit': 'حبة',
        'buy_price': 2000.0,
        'sell_price': 3000.0,
        'quantity': 0.0,
        'min_quantity': 1.0,
        'is_active': 1,
        'is_deleted': 0,
        'created_at': tCreate,
        'updated_at': tRename,
      });
      await db.insert('operations', {
        'id': 'op-update-a10e-rename-restock',
        'workspace_id': 'default',
        'device_id': 'DEV-HOST',
        'user_id': 1,
        'op_type': 'update',
        'entity_type': 'item',
        'entity_id': '$origId',
        'payload': '{"id":$origId,"name":"A10e","sku":"10176","quantity":5.0,"__qty_changed":1,"updated_at":"$tRename"}',
        'timestamp': tRename,
        'device_time': tRename,
        'version': 2,
        'parent_op_id': 'op-hist-create-a10e',
        'synced': 1,
      });
      await db.insert('operations', {
        'id': 'op-bogus-split-ayman',
        'workspace_id': 'default',
        'device_id': 'DEV-AYMAN',
        'user_id': 2,
        'op_type': 'create',
        'entity_type': 'item',
        'entity_id': '$splitId',
        'payload': '{"id":$splitId,"name":"A10e","__conflict_resolved":true,"__reassigned_from_id":$origId}',
        'timestamp': tRename,
        'device_time': tRename,
        'version': 1,
        'parent_op_id': '',
        'synced': 1,
      });
      await db.insert('settings', {
        'key': 'item_conflict:${origId}_$splitId',
        'value': '{"key":"item_conflict:${origId}_$splitId","conflictType":"id","originalCollidingId":$origId,"sharedSku":"10176","item1Id":$origId,"item1Name":"شاشة A10e","item1Creator":"ايمن","item2Id":$splitId,"item2Name":"A10e","item2Creator":"فخامة المدير","status":"pending","createdAt":"$tRename"}',
      });

      // بمجرد استدعاء pendingItemConflicts أو items يتم الشفاء الذاتي الفوري
      final conflictsAfterHeal = await repo.pendingItemConflicts();
      expect(conflictsAfterHeal, isEmpty);

      final itemsAfterHeal = await repo.items();
      expect(itemsAfterHeal.any((i) => i.id == splitId), isFalse);
      final healedOrig = itemsAfterHeal.singleWhere((i) => i.id == origId);
      expect(healedOrig.name, equals('A10e'));
      expect(healedOrig.quantity, equals(5.0));
    });
  });
}
