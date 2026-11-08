// QA — (3.98.39 / الملاحظة 1) اسم المدير/المالك: حفظ محلي + سحابي وثباته.
//
// العلة: الاسم المخصّص الذي يكتبه المالك من أيقونة ✎ في القائمة الجانبية
// كان يُحفظ في `devices.name` و`sync.deviceName` فقط، بينما هوية المنشأة
// السحابية (`account.name` / `profile.owner_name`) تبقى على القيمة القديمة
// «المدير 🫡»، فتعود عند أول مزامنة/ترميم.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/device_names.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('تطبيع الأسماء الافتراضية المزخرفة', () {
    test('NAME-01 «المدير 🫡» و«المدير 👑» اسم مكان شاغر لا هوية', () {
      expect(isPlaceholderDeviceName('المدير 🫡'), isTrue);
      expect(isPlaceholderDeviceName('المدير  👑'), isTrue);
      expect(isPlaceholderDeviceName('مستخدم جديد 🙂'), isTrue);
      expect(isCustomDeviceName('المدير 🫡'), isFalse);
    });

    test('NAME-02 الاسم المخصّص يبقى مخصّصاً حتى مع رمز تعبيري', () {
      expect(isCustomDeviceName('أحمد — فرع الجملة'), isTrue);
      expect(isCustomDeviceName('أحمد 🫡'), isTrue);
      expect(isCustomDeviceName('مكتبة النور'), isTrue);
    });

    test('NAME-03 resolveOwnerDisplayName يفضّل الاسم المخصّص على المزخرف',
        () {
      expect(
        resolveOwnerDisplayName(
          profileOwnerName: 'أحمد الشرعبي',
          accountName: 'المدير 🫡',
          deviceName: 'المدير',
          userName: 'المدير',
        ),
        'أحمد الشرعبي',
      );
      // لا اسم مخصّص في أي مصدر ⇒ الحد الأدنى «المدير» لا «المدير 🫡».
      expect(
        resolveOwnerDisplayName(
          profileOwnerName: 'المدير 🫡',
          accountName: 'المدير',
          deviceName: 'المدير',
        ),
        'المدير',
      );
    });
  });

  group('renameSelfDevice على قاعدة حقيقية', () {
    late Directory tmp;
    late Database db;
    late Repo repo;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('nexora_owner_name_');
      db = await databaseFactory.openDatabase('${tmp.path}/qa.db',
          options: OpenDatabaseOptions(
            onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          ));
      await AppDatabase.createSchema(db);
      AppDatabase.overrideForTest(db);
      repo = Repo();
      await repo.initSyncInfra();
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
      await tmp.delete(recursive: true);
    });

    test('NAME-04 إعادة التسمية تحفظ profile.owner_name و account.name', () async {
      await repo.renameSelfDevice('أحمد — الجملة');
      final st = await repo.settings();
      expect(st['profile.owner_name'], 'أحمد — الجملة',
          reason: 'يُرفع سحابياً ويُجلب عند الفتح والمزامنة');
      expect(st['account.name'], 'أحمد — الجملة',
          reason: 'هوية المنشأة السحابية يجب أن تُحدَّث مع الاسم');
      expect(st['sync.deviceName'], 'أحمد — الجملة');
    });

    test('NAME-05 التسمية المزخرفة «المدير 🫡» لا تُعدّ تخصيصاً', () {
      // الحارس المستخدم في ownDeviceNameProvider وروستر السحابة.
      expect(isCustomDeviceName('المدير 🫡'), isFalse);
    });

    test('NAME-06 ترميم المالك عند الفتح لا يمحو الاسم المخصّص', () async {
      await repo.renameSelfDevice('سالم العمري');
      // محاكاة تلوّث: users.name صار اسم جهاز عضو + devices.name مزخرف.
      await db.insert(
        'devices',
        {
          'id': 'DEVICE-MEMBER-1',
          'workspace_id': await repo.activeWorkspaceId(),
          'name': 'سالم العمري', // اسم العضو يساوي اسم المالك (تلوّث)
          'is_owner': 0,
          'is_paired': 1,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await db.update('users', {'name': 'سالم العمري'},
          where: 'is_me = 1');

      await AppDatabase.repairOwnerAdminStatus(db);

      final owner = await db.query('users', where: 'is_me = 1', limit: 1);
      expect('${owner.first['name']}', 'سالم العمري',
          reason: 'المصدر الأول profile.owner_name يجب أن يعيد الاسم الصحيح '
              'ولا يرتد إلى «المدير»');
    });
  });
}
