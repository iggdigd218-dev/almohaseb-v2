import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/app_version.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/backup_engine.dart';
import 'package:nexora_app/data/google_drive_service.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/ui/backup_screen.dart';
import 'package:nexora_app/ui/home_shell.dart';

final _testNow = DateTime.utc(2026, 10, 10, 12, 0, 0);

Future<Database> _openFileDb(String path) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: AppDatabase.schemaVersion,
      onCreate: (db, v) async {
        await AppDatabase.createSchema(db);
      },
    ),
  );
  await AppDatabase.ensureFullSchema(db);
  return db;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = await Directory.systemTemp.createTemp('nexora_backup_engine_test_');
  });

  tearDown(() async {
    GoogleDriveService.instance.debugListBackupsOverride = null;
    GoogleDriveService.instance.debugDownloadBackupByIdOverride = null;
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('1. ضوابط الصلاحيات والمزامنة (Access & Sync Guards)', () {
    test('حصر الصلاحيات بمدير المنشأة والحساب الفردي، وحجبها عن الكاشير والموظفين', () async {
      final dbPath = p.join(tempDir.path, 'rbac_guard.db');
      final db = await _openFileDb(dbPath);
      final repo = Repo(databaseProvider: () async => db);
      await repo.initSyncInfra();

      // في الوضع المستقل (الفردي) بدون مستخدم موظف: مسموح
      expect(await BackupEngine.canAccessBackupAndRestore(repo), isTrue);

      // عند تسجيل موظف كاشير أو مدخل بيانات أو محاسب: محجوب تماماً
      for (final role in [
        UserRole.cashier,
        UserRole.dataentry,
        UserRole.viewer,
        UserRole.accountant,
      ]) {
        // القائمة الجانبية تخفي زر النسخ الاحتياطي بالكامل عن هذه الأدوار
        final drawerForEmployee = DrawerItems.of(
          user: AppUser(
            id: 10,
            name: 'موظف',
            role: role,
            createdAt: _testNow,
            updatedAt: _testNow,
          ),
          isOwner: true,
          workspaceMode: 'host',
        );
        expect(drawerForEmployee.contains(AppScreen.backup), isFalse,
            reason: 'Role $role must not see backup screen in drawer');

        final drawerStandaloneEmployee = DrawerItems.of(
          user: AppUser(
            id: 10,
            name: 'موظف',
            role: role,
            createdAt: _testNow,
            updatedAt: _testNow,
          ),
          isOwner: true,
          workspaceMode: 'standalone',
        );
        expect(drawerStandaloneEmployee.contains(AppScreen.backup), isFalse,
            reason: 'Role $role in standalone must not see backup screen');
      }

      // المدير (Owner / Admin) والحساب الفردي يظهر لهما النسخ الاحتياطي
      final drawerForAdmin = DrawerItems.of(
        user: AppUser(
          id: 1,
          name: 'المدير',
          role: UserRole.admin,
          createdAt: _testNow,
          updatedAt: _testNow,
        ),
        isOwner: true,
        workspaceMode: 'host',
      );
      expect(drawerForAdmin.contains(AppScreen.backup), isTrue);

      final drawerForStandalone = DrawerItems.of(
        user: null,
        isOwner: true,
        workspaceMode: 'standalone',
      );
      expect(drawerForStandalone.contains(AppScreen.backup), isTrue);

      // أجهزة الأعضاء (member) محجوبة دائماً حتى لو كان الدور admin
      final drawerForMember = DrawerItems.of(
        user: AppUser(
          id: 1,
          name: 'عضو',
          role: UserRole.admin,
          createdAt: _testNow,
          updatedAt: _testNow,
        ),
        isOwner: false,
        workspaceMode: 'member',
      );
      expect(drawerForMember.contains(AppScreen.backup), isFalse);

      await db.close();
    });

    testWidgets('BackupScreen يخفي أزرار النسخ والاستعادة عن الكاشير والموظفين ويعطل الاستعادة أثناء المزامنة النشطة',
        (tester) async {
      late Database db;
      late Repo repo;
      await tester.runAsync(() async {
        final dbPath = p.join(tempDir.path, 'ui_guard.db');
        db = await _openFileDb(dbPath);
        repo = Repo(databaseProvider: () async => db);
        await repo.initSyncInfra();
      });

      // 1) واجهة الكاشير: لا تظهر أزرار إنشاء نسخة أو استعادة إطلاقاً
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('scope_cashier'),
          overrides: [
            repoProvider.overrideWithValue(repo),
            countsProvider.overrideWith((ref) async => const <String, int>{}),
            trashProvider.overrideWith((ref) async => const <Map<String, Object?>>[]),
            workspaceModeProvider.overrideWith((ref) async => 'host'),
            isOwnerProvider.overrideWith((ref) async => false),
            currentUserProvider.overrideWith(
              (ref) async => AppUser(
                id: 5,
                name: 'كاشير 1',
                role: UserRole.cashier,
                createdAt: _testNow,
                updatedAt: _testNow,
              ),
            ),
          ],
          child: const Directionality(
            textDirection: TextDirection.rtl,
            child: MaterialApp(home: Scaffold(body: BackupScreen(embedded: true))),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();

      expect(find.text('النسخ والاستيراد مقيد'), findsOneWidget);
      expect(find.text('إنشاء نسخة'), findsNothing);
      expect(find.text('استعادة'), findsNothing);

      // 2) واجهة المدير أثناء تشغيل المزامنة السحابية النشطة:
      // يُسمح بـ "إنشاء نسخة" ويُعطّل زر "استعادة" مع ظهور الرسالة التنبيهية
      await tester.runAsync(() async {
        await repo.setSetting('workspace.mode', 'host');
        await repo.setSetting('cloudBackendUrl', 'https://example-sync.firebaseio.com');
      });

      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('scope_admin'),
          overrides: [
            repoProvider.overrideWithValue(repo),
            countsProvider.overrideWith((ref) async => const <String, int>{}),
            trashProvider.overrideWith((ref) async => const <Map<String, Object?>>[]),
            workspaceModeProvider.overrideWith((ref) async => 'host'),
            isOwnerProvider.overrideWith((ref) async => true),
            currentUserProvider.overrideWith(
              (ref) async => AppUser(
                id: 1,
                name: 'المدير العام',
                role: UserRole.admin,
                createdAt: _testNow,
                updatedAt: _testNow,
              ),
            ),
          ],
          child: const Directionality(
            textDirection: TextDirection.rtl,
            child: MaterialApp(
              home: Scaffold(
                body: BackupScreen(key: ValueKey('backup_admin'), embedded: true),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pumpAndSettle();

      expect(find.text('إنشاء نسخة'), findsOneWidget);
      expect(find.text(BackupEngine.syncActiveRestoreDisabledMessage), findsOneWidget);

      final restoreBtn = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('استعادة'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(restoreBtn.onPressed, isNull,
          reason: 'Restore button must be disabled when live cloud sync is active');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await db.close();
      });
      await tester.pump(const Duration(seconds: 11));
    });
  });

  group('2. واجهة استعراض نسخ Google Drive المدمجة (Drive Backup Picker)', () {
    testWidgets('تعرض النسخ المطابقة للبادئة مع الحجم وزر المشاركة وشريط البحث والفلترة اللحظية',
        (tester) async {
      final sampleBackups = [
        GoogleDriveBackupInfo(
          id: 'file_1',
          name: 'MyAccounts_Auto_V2_11-Oct-2026 07:38:25.nexora',
          modifiedTime: DateTime(2026, 10, 11, 7, 38, 25),
          sizeBytes: 256 * 1024, // 256.0 KB
        ),
        GoogleDriveBackupInfo(
          id: 'file_2',
          name: 'MyAccounts_Backup_V2_10-Oct-2026 19:12:00.nexora',
          modifiedTime: DateTime(2026, 10, 10, 19, 12, 0),
          sizeBytes: 2 * 1024 * 1024, // 2.00 MB
        ),
      ];

      GoogleDriveService.instance.debugListBackupsOverride =
          () async => sampleBackups;

      File? downloadedResult;
      GoogleDriveService.instance.debugDownloadBackupByIdOverride =
          (fileId, target) async {
        target.writeAsBytesSync([1, 2, 3, 4], flush: true);
        return target;
      };

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.rtl,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => ElevatedButton(
                  onPressed: () async {
                    downloadedResult = await showDriveBackupPickerDialog(ctx);
                  },
                  child: const Text('فتح استعراض درايف'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('فتح استعراض درايف'));
      await tester.pumpAndSettle();

      // التحقق من عنوان النافذة وعرض البطاقات المرتبة مع الاسم والحجم وأيقونة المشاركة وزر الإلغاء
      expect(find.text('نسخ Google Drive الاحتياطية'), findsOneWidget);
      expect(
        find.text('MyAccounts_Auto_V2_11-Oct-2026 07:38:25.nexora'),
        findsOneWidget,
      );
      expect(
        find.text('MyAccounts_Backup_V2_10-Oct-2026 19:12:00.nexora'),
        findsOneWidget,
      );
      expect(find.text('256.0 KB'), findsOneWidget);
      expect(find.text('2.00 MB'), findsOneWidget);
      expect(find.byIcon(Icons.share_outlined), findsNWidgets(2));
      expect(find.text('إلغاء'), findsOneWidget);

      // تجربة شريط البحث العلوي للفلترة اللحظية
      await tester.enterText(
        find.byType(TextField),
        '10-Oct-2026',
      );
      await tester.pumpAndSettle();

      expect(
        find.text('MyAccounts_Auto_V2_11-Oct-2026 07:38:25.nexora'),
        findsNothing,
      );
      expect(
        find.text('MyAccounts_Backup_V2_10-Oct-2026 19:12:00.nexora'),
        findsOneWidget,
      );

      // الضغط على البطاقة لتنزيلها تمهيداً للاستعادة
      await tester.tap(
        find.text('MyAccounts_Backup_V2_10-Oct-2026 19:12:00.nexora'),
      );
      await tester.pumpAndSettle();

      expect(downloadedResult, isNotNull);
      expect(downloadedResult!.existsSync(), isTrue);
    });
  });

  group('3 & 4. صيغة الحزمة المحمية (.nexora) وفحص التواريخ ولقطة الأمان الاحترازية', () {
    test('إنشاء حزمة .nexora مضغوطة (Gzip) تضم database.db (VACUUM INTO) و manifest.json بالمواصفات الدقيقة',
        () async {
      final dbPath = p.join(tempDir.path, 'source_store.db');
      final db = await _openFileDb(dbPath);
      final repo = Repo(databaseProvider: () async => db);
      await repo.initSyncInfra();
      await repo.setSetting('sync.groupId', 'ws_alpha_123');

      final accId = await repo.saveAccount(
        Account(
          name: 'شركة النور للتجارة',
          kind: AccountKind.customer,
          createdAt: _testNow,
          updatedAt: _testNow,
        ),
      );
      await repo.saveTx(
        Tx(
          accountId: accId,
          type: OpType.debit,
          amount: 15000,
          currency: 'YER',
          date: DateTime.utc(2026, 10, 10),
          notes: 'فاتورة مبيعات آجلة',
          createdAt: _testNow,
          updatedAt: _testNow,
        ),
      );

      final packageFile = await BackupEngine.createNexoraPackage(
        repo,
        outputDirectory: tempDir,
        auto: true,
      );

      expect(await packageFile.exists(), isTrue);
      expect(p.basename(packageFile.path), startsWith('MyAccounts_Auto_V2_'));
      expect(p.basename(packageFile.path), endsWith('.nexora'));

      // فك ضغط Gzip + Tar والتحقق من وجود database.db و manifest.json
      final rawBytes = await packageFile.readAsBytes();
      final tarBytes = const GZipDecoder().decodeBytes(rawBytes);
      final archive = TarDecoder().decodeBytes(tarBytes);

      final fileNames = archive.files.map((f) => f.name).toSet();
      expect(fileNames.contains('database.db'), isTrue);
      expect(fileNames.contains('manifest.json'), isTrue);

      final manifestEntry =
          archive.files.firstWhere((f) => f.name == 'manifest.json');
      final manifestJson = jsonDecode(
        utf8.decode(manifestEntry.content as List<int>),
      ) as Map<String, Object?>;

      expect(manifestJson['app'], equals('Nexora'));
      expect(manifestJson['version'], equals(kAppVersion));
      expect(manifestJson['workspace_id'], equals('ws_alpha_123'));
      expect(manifestJson['schema_version'], equals(AppDatabase.schemaVersion));
      expect((manifestJson['created_at'] as String).isNotEmpty, isTrue);
      expect(
        (manifestJson['last_transaction_time'] as String).isNotEmpty,
        isTrue,
      );

      await db.close();
    });

    test(
        'فحص التعارض الزمني (الأقدم من المحلي) + إنشاء لقطة الأمان Safety_Snapshot_Before_Restore + الاستبدال الآمن للقاعدة',
        () async {
      final dbPath = p.join(tempDir.path, 'live_store.db');
      final db = await _openFileDb(dbPath);
      final repo = Repo(databaseProvider: () async => db);
      await repo.initSyncInfra();
      await repo.setSetting('sync.groupId', 'ws_main_777');

      // 1) إنشاء بيانات في القاعدة وأخذ نسخة احتياطية (.nexora) في وقت T1
      final acc1 = await repo.saveAccount(
        Account(
          name: 'عميل قديم قبل النسخة',
          kind: AccountKind.customer,
          createdAt: _testNow,
          updatedAt: _testNow,
        ),
      );
      await repo.saveTx(
        Tx(
          accountId: acc1,
          type: OpType.debit,
          amount: 5000,
          currency: 'YER',
          date: DateTime.utc(2026, 10, 1),
          notes: 'حركة قديمة',
          createdAt: _testNow,
          updatedAt: _testNow,
        ),
      );
      // ضبط updated_at للحركة القديمة إلى تاريخ أقدم
      await db.execute(
        "UPDATE transactions SET created_at = '2026-10-01T10:00:00.000Z', updated_at = '2026-10-01T10:00:00.000Z'",
      );

      final olderBackupFile = await BackupEngine.createNexoraPackage(
        repo,
        outputDirectory: tempDir,
      );

      // 2) تسجيل حركة أحدث في قاعدة البيانات المحلية في وقت T2 > T1
      final acc2 = await repo.saveAccount(
        Account(
          name: 'عميل جديد بعد النسخة',
          kind: AccountKind.customer,
          createdAt: _testNow,
          updatedAt: _testNow,
        ),
      );
      await repo.saveTx(
        Tx(
          accountId: acc2,
          type: OpType.inflow,
          amount: 95000,
          currency: 'YER',
          date: DateTime.utc(2026, 10, 11),
          notes: 'حركة حديثة جداً',
          createdAt: _testNow,
          updatedAt: _testNow,
        ),
      );
      await db.execute(
        "UPDATE transactions SET created_at = '2026-10-11T12:30:00.000Z', updated_at = '2026-10-11T12:30:00.000Z' WHERE account_id = ?",
        [acc2],
      );

      // 3) فحص النسخة الأقدم والتحقق من اكتشاف أنها أقدم من البيانات الحالية ومن نص التحذير الحرج
      final inspection = await BackupEngine.inspectPackage(
        olderBackupFile,
        repo,
      );
      expect(inspection.isOlderThanLocal, isTrue);
      expect(
        inspection.criticalWarningMessage,
        contains(
          'تحذير مالي حرج: النسخة التي تحاول استعادتها أقدم من بياناتك الحالية.',
        ),
      );
      expect(
        inspection.criticalWarningMessage,
        contains('الاستمرار سيؤدي لفقدان العمليات المسجلة بعد تاريخ النسخة.'),
      );

      // 4) محاولة الاستعادة بدون تأكيد صريح من المدير يجب أن تُرفض
      await expectLater(
        () => BackupEngine.restoreFromInspection(
          inspection: inspection,
          repo: repo,
          safetySnapshotDirectory: tempDir,
        ),
        throwsA(isA<BackupImportException>()),
      );

      // 5) الاستعادة مع تأكيد صريح من المدير:
      // تنشئ لقطة الأمان التلقائية Safety_Snapshot_Before_Restore ثم تستبدل القاعدة بأمان وتعيد فتح الاتصال
      final restoreResult = await BackupEngine.restoreFromInspection(
        inspection: inspection,
        repo: repo,
        explicitConfirmationText: 'استعادة',
        safetySnapshotDirectory: tempDir,
      );

      // التحقق من لقطة الأمان التلقائية (Pre-Restore Snapshot)
      expect(await restoreResult.safetySnapshotFile.exists(), isTrue);
      expect(
        p.basename(restoreResult.safetySnapshotFile.path),
        startsWith('Safety_Snapshot_Before_Restore'),
      );

      // التحقق من أن قاعدة البيانات استُبدلت فعلياً وعادت لحالة النسخة المستعادة
      final accountsAfterRestore = await repo.accounts();
      final names = accountsAfterRestore.map((a) => a.name).toList();
      expect(names, contains('عميل قديم قبل النسخة'));
      expect(names, isNot(contains('عميل جديد بعد النسخة')));

      await inspection.cleanup();
      final currentDb = await repo.database;
      await currentDb.close();
    });
  });
}
