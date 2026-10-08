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
  });
}
