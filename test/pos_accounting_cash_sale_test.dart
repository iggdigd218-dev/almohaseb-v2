import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/receipt_image.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_pos_cash_test_');
    db = await databaseFactory.openDatabase(
      '${tmp.path}/pos_test.db',
      options: OpenDatabaseOptions(
        onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  group('POS Accounting, Cash Sales Net Impact = 0, & Strict Debt Validation', () {
    test('Cash sale for a customer has Net Impact = 0 on customer balance', () async {
      final now = DateTime.now();

      final custId = await repo.saveAccount(
        Account(
          name: 'أحمد صالح',
          kind: AccountKind.customer,
          openingBalance: 1500.0,
          phone: '777123456',
          createdAt: now,
          updatedAt: now,
        ),
      );

      final customerBeforeCashSale = (await repo.account(custId))!;
      expect(customerBeforeCashSale.balance, equals(1500.0));

      // تنفيذ فاتورة بيع نقدي مربوطة بالعميل
      final cashTx = Tx(
        accountId: custId,
        accountKind: AccountKind.customer,
        type: OpType.revenue,
        amount: 4500.0,
        currency: 'YER',
        description: 'فاتورة نقدية مدفوعة رقم #1',
        reference: '1',
        notes: 'طريقة الدفع: مدفوع نقداً\nالمبلغ المدفوع: 4,500 ر.ي\nالمتبقي: 0.00 ر.ي',
        date: now,
        createdAt: now,
        updatedAt: now,
      );
      await repo.saveTx(
        cashTx,
        items: const [
          InvoiceLine(
            name: 'صنف تجريبي',
            quantity: 3,
            unitPrice: 1500,
            total: 4500,
          ),
        ],
      );

      final customerAfterCashSale = (await repo.account(custId))!;
      expect(customerAfterCashSale.balance, equals(customerBeforeCashSale.balance));

      // التحقق من دالة تصحيح الأرصدة واستبعاد الفواتير النقدية
      final recalculated = await repo.recalculateCustomerBalance(custId);
      expect(recalculated, equals(customerBeforeCashSale.balance));
    });

    test('Credit sale and receipt voucher update balance & recalculateCustomerBalance matches', () async {
      final now = DateTime.now();

      final custId = await repo.saveAccount(
        Account(
          name: 'محمد العميل',
          kind: AccountKind.customer,
          openingBalance: 0.0,
          createdAt: now,
          updatedAt: now,
        ),
      );

      // 1. فاتورة آجلة بمبلغ 2000 (عليه)
      await repo.saveTx(
        Tx(
          accountId: custId,
          accountKind: AccountKind.customer,
          type: OpType.debit,
          amount: 2000.0,
          currency: 'YER',
          date: now,
          createdAt: now,
          updatedAt: now,
        ),
      );

      // 2. فاتورة نقدية بمبلغ 900 (لا تؤثر على الرصيد)
      await repo.saveTx(
        Tx(
          accountId: custId,
          accountKind: AccountKind.customer,
          type: OpType.revenue,
          amount: 900.0,
          currency: 'YER',
          date: now,
          createdAt: now,
          updatedAt: now,
        ),
      );

      // 3. سند قبض بمبلغ 500 (له)
      await repo.saveTx(
        Tx(
          accountId: custId,
          accountKind: AccountKind.customer,
          type: OpType.inflow,
          amount: 500.0,
          currency: 'YER',
          date: now,
          createdAt: now,
          updatedAt: now,
        ),
      );

      final cust = (await repo.account(custId))!;
      expect(cust.balance, equals(1500.0));
      final recalc = await repo.recalculateCustomerBalance(custId);
      expect(recalc, equals(1500.0));
    });

    test('Strict validation rejects credit/partial debt without valid customer or with generic cash customer', () async {
      final now = DateTime.now();

      // 1. بدون عميل
      expect(
        () => repo.saveTx(
          Tx(
            accountId: null,
            type: OpType.debit,
            amount: 1000.0,
            currency: 'YER',
            date: now,
            createdAt: now,
            updatedAt: now,
          ),
        ),
        throwsA(isA<StateError>()),
      );

      // 2. بحساب اسمه "عميل نقدي عام"
      final genericCashId = await repo.saveAccount(
        Account(
          name: 'عميل نقدي عام',
          kind: AccountKind.customer,
          createdAt: now,
          updatedAt: now,
        ),
      );

      expect(
        () => repo.saveTx(
          Tx(
            accountId: genericCashId,
            type: OpType.debit,
            amount: 1000.0,
            currency: 'YER',
            date: now,
            createdAt: now,
            updatedAt: now,
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('ReceiptData marks cash sale with isCashSale = true and title فاتورة نقدية مدفوعة', () {
      final now = DateTime.now();
      final tx = Tx(
        accountId: 1,
        type: OpType.revenue,
        amount: 3000,
        currency: 'YER',
        date: now,
        createdAt: now,
        updatedAt: now,
      );
      final r = ReceiptData.fromTx(
        tx: tx,
        account: null,
        currency: kDefaultCurrencies.first,
        settings: const {},
      );
      expect(r.isCashSale, isTrue);
      expect(r.title, equals('فاتورة نقدية مدفوعة'));
      expect(r.isDebit, isFalse);
    });

    test('1. Atomic Inventory Deduction: rollback entire invoice if any item stock fails', () async {
      final now = DateTime.now();
      final item1Id = await repo.saveItem(
        Item(
          name: 'صنف متوفر',
          unit: 'حبة',
          sellPrice: 100,
          quantity: 10,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final item2Id = await repo.saveItem(
        Item(
          name: 'صنف نافد',
          unit: 'حبة',
          sellPrice: 200,
          quantity: 2,
          createdAt: now,
          updatedAt: now,
        ),
      );

      // محاولة إصدار فاتورة تحتوي صنفين، الثاني يطلب 5 والمتاح 2 فقط
      await expectLater(
        () => repo.saveTx(
          Tx(
            type: OpType.revenue,
            amount: 1200,
            currency: 'YER',
            description: 'فاتورة يجب أن تتراجع بالكامل',
            date: now,
            createdAt: now,
            updatedAt: now,
          ),
          items: [
            InvoiceLine(
              itemId: item1Id,
              name: 'صنف متوفر',
              unit: 'حبة',
              quantity: 2,
              unitPrice: 100,
              total: 200,
            ),
            InvoiceLine(
              itemId: item2Id,
              name: 'صنف نافد',
              unit: 'حبة',
              quantity: 5,
              unitPrice: 200,
              total: 1000,
            ),
          ],
          deductStock: true,
        ),
        throwsA(isA<StateError>()),
      );

      // التحقق من التراجع الكامل (Rollback): لم تُحفظ الفاتورة ولم يُخصم الصنف الأول
      expect(await repo.transactions(), isEmpty);
      expect((await repo.item(item1Id))!.quantity, equals(10));
      expect((await repo.item(item2Id))!.quantity, equals(2));
    });

    test('2. Delete & Restore Tx: reverses stock on delete, preserves items in trash, re-deducts on restore', () async {
      final now = DateTime.now();
      final custId = await repo.saveAccount(
        Account(
          name: 'عميل استرجاع',
          kind: AccountKind.customer,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final itemId = await repo.saveItem(
        Item(
          name: 'شاشة عرض',
          unit: 'قطعة',
          sellPrice: 500,
          quantity: 20,
          createdAt: now,
          updatedAt: now,
        ),
      );

      final txId = await repo.saveTx(
        Tx(
          accountId: custId,
          accountKind: AccountKind.customer,
          type: OpType.debit,
          amount: 1500,
          currency: 'YER',
          description: 'فاتورة مبيعات آجلة',
          reference: '55',
          date: now,
          createdAt: now,
          updatedAt: now,
        ),
        items: [
          InvoiceLine(
            itemId: itemId,
            name: 'شاشة عرض',
            unit: 'قطعة',
            quantity: 3,
            unitPrice: 500,
            total: 1500,
          ),
        ],
        deductStock: true,
      );

      // بعد البيع: الرصيد المخزني 17
      expect((await repo.item(itemId))!.quantity, equals(17));
      expect(await repo.transactionItems(txId), hasLength(1));

      // عند الحذف: يعود المخزون إلى 20 وتُحفظ البنود في سلة المهملات
      await repo.deleteTx(txId);
      expect((await repo.item(itemId))!.quantity, equals(20));

      final trashList = await repo.trash();
      expect(trashList, isNotEmpty);

      // عند الاسترجاع: تعود الفاتورة ببنودها كاملة ويُخصم المخزون مجدداً إلى 17
      await repo.restoreFromTrash(trashList.first['id'] as int);
      expect((await repo.item(itemId))!.quantity, equals(17));
      final restoredItems = await repo.transactionItems(txId);
      expect(restoredItems, hasLength(1));
      expect(restoredItems.first.name, equals('شاشة عرض'));
      expect(restoredItems.first.quantity, equals(3));
    });

    test('3. Vouchers Ledger Impact: receipt & payment vouchers update customer/supplier balance on approval and reverse on cancel', () async {
      final now = DateTime.now();
      final custId = await repo.saveAccount(
        Account(
          name: 'عميل مدين',
          kind: AccountKind.customer,
          openingBalance: 1000,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final suppId = await repo.saveAccount(
        Account(
          name: 'مورد دائن',
          kind: AccountKind.supplier,
          openingBalance: -2000,
          createdAt: now,
          updatedAt: now,
        ),
      );

      // إنشاء سند قبض كمسودة: لا يحرّك الرصيد قبل الاعتماد
      final rvId = await repo.saveVoucher(
        Voucher(
          number: 'ق0099',
          kind: VoucherKind.receipt,
          accountId: custId,
          amount: 400,
          currency: 'YER',
          statement: 'دفعة من الحساب',
          status: 'draft',
          date: now,
          createdAt: now,
          updatedAt: now,
        ),
      );
      expect(await repo.balanceOf((await repo.account(custId))!), equals(1000));

      // اعتماد سند القبض -> ينقص مديونية العميل فوراً إلى 600 ويربط txId
      final savedRv = (await repo.voucher(rvId))!;
      await repo.saveVoucher(savedRv.copyWith(status: 'approved'));
      final approvedRv = (await repo.voucher(rvId))!;
      expect(approvedRv.txId, isNotNull);
      expect(await repo.balanceOf((await repo.account(custId))!), equals(600));

      // اعتماد سند صرف للمورد بمبلغ 500 -> يخفض مستحقات المورد من -2000 إلى -1500
      final pvId = await repo.saveVoucher(
        Voucher(
          number: 'ص0099',
          kind: VoucherKind.payment,
          accountId: suppId,
          amount: 500,
          currency: 'YER',
          statement: 'سداد دفعة للمورد',
          status: 'approved',
          date: now,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final approvedPv = (await repo.voucher(pvId))!;
      expect(approvedPv.txId, isNotNull);
      expect(await repo.balanceOf((await repo.account(suppId))!), equals(-1500));

      // إلغاء سند القبض -> يلغي القيد المالي المرتبط ويعيد مديونية العميل إلى 1000
      await repo.saveVoucher(approvedRv.copyWith(status: 'cancelled'));
      expect(await repo.balanceOf((await repo.account(custId))!), equals(1000));
    });

    test('5. Performance Hot-Path: transactionById & recentDebtorAccountIds fetch directly', () async {
      final now = DateTime.now();
      final custId = await repo.saveAccount(
        Account(
          name: 'عميل نشط',
          kind: AccountKind.customer,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final txId = await repo.saveTx(
        Tx(
          accountId: custId,
          accountKind: AccountKind.customer,
          type: OpType.debit,
          amount: 750,
          currency: 'YER',
          reference: '777',
          date: now,
          createdAt: now,
          updatedAt: now,
        ),
      );

      final directTx = await repo.transactionById(txId);
      expect(directTx, isNotNull);
      expect(directTx!.id, equals(txId));
      expect(directTx.amount, equals(750));

      final recentIds = await repo.recentDebtorAccountIds(limit: 3);
      expect(recentIds, contains(custId));
    });
  });
}
