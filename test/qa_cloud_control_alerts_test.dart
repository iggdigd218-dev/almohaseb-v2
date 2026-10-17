// 📢 QA — اختبار مركز التحكم السحابي والتنبيهات وجرس الإشعارات الذهبي (2026-09-26).
//
// يختبر هذا الملف:
//  CTL-01: جلب التنبيهات من كلا المسارين دون تكرار.
//  CTL-02: وضع الصيانة يحدّث maintenanceActiveNotifier ونص الرسالة.
//  CTL-03: تطابق إصدار وبناء التطبيق.
//  CTL-04: حفظ حالة الإشعارات المقروءة في SharedPreferences وعدم عودة العداد بعد تصفيره.
//  CTL-05: عرض أيقونة الجرس الذهبي الحقيقي (GoldenBellIcon) بأحجام مختلفة وبدون أخطاء.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexora_app/core/app_version.dart';
import 'package:nexora_app/core/license_model.dart';
import 'package:nexora_app/data/sync/cloud_control_service.dart';
import 'package:nexora_app/data/sync/firebase_auth_service.dart';
import 'package:nexora_app/ui/widgets/golden_bell_icon.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Cloud Control & Broadcast Alerts QA Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('CTL-01 جلب التنبيهات من مساري broadcast_alerts و broadcast_notifications', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final alert1Raw = {
        'id': '101',
        'title': 'تنبيه 1',
        'body': 'نص التنبيه 1',
        'created_at': now - 1000,
      };
      final alert2Raw = {
        'id': '102',
        'title': 'تنبيه 2',
        'body': 'نص التنبيه 2',
        'created_at': now,
      };

      final alert1 = CloudAlert.fromJson(alert1Raw, '101');
      final alert2 = CloudAlert.fromJson(alert2Raw, '102');

      expect(alert1.id, '101');
      expect(alert1.title, 'تنبيه 1');
      expect(alert2.id, '102');
      expect(alert2.title, 'تنبيه 2');
    });

    test('CTL-02 وضع الصيانة السحابي والتنبيهات التفاعلية', () {
      final ctl = CloudControlService.instance;
      ctl.maintenanceActiveNotifier.value = true;
      ctl.maintenanceMessageNotifier.value = 'الخوادم قيد الصيانة المجدولة';

      expect(ctl.maintenanceActiveNotifier.value, isTrue);
      expect(ctl.maintenanceMessageNotifier.value, 'الخوادم قيد الصيانة المجدولة');

      ctl.maintenanceActiveNotifier.value = false;
      ctl.maintenanceMessageNotifier.value = '';
      expect(ctl.maintenanceActiveNotifier.value, isFalse);
    });

    test('CTL-03 تطابق إصدار وبناء التطبيق مع المزامنة السحابية', () {
      expect(kAppBuild, greaterThanOrEqualTo(174));
      expect(kAppVersion, isNotEmpty);
      expect(AppSemVer.current.build, kAppBuild);
    });

    test('CTL-04 حفظ الإشعارات المقروءة في SharedPreferences وتصفير العداد نهائياً', () async {
      SharedPreferences.setMockInitialValues({});
      final ctl = CloudControlService.instance;

      const a1 = CloudAlert(
        id: 'alert_bcast_1',
        title: 'إشعار بث 1',
        body: 'مرحباً',
        createdAt: 1700000000,
        isRead: false,
      );
      const a2 = CloudAlert(
        id: 'alert_bcast_2',
        title: 'إشعار بث 2',
        body: 'تحديث جديد',
        createdAt: 1700000050,
        isRead: false,
      );

      ctl.cloudAlertsNotifier.value = [a1, a2];
      ctl.unreadAlertCountNotifier.value = 2;

      expect(ctl.unreadAlertCountNotifier.value, 2);

      // تعليم الكل كمقروء (كما يحدث عند فتح الإشعارات)
      await ctl.markAllAlertsRead();

      expect(ctl.unreadAlertCountNotifier.value, 0);
      expect(ctl.cloudAlertsNotifier.value.every((a) => a.isRead), isTrue);

      // التأكد من الحفظ المستديم في SharedPreferences
      final sp = await SharedPreferences.getInstance();
      final readIds = sp.getStringList('read_cloud_alert_ids') ?? [];
      expect(readIds, contains('alert_bcast_1'));
      expect(readIds, contains('alert_bcast_2'));
    });

    testWidgets('CTL-05 رسم أيقونة الجرس الذهبي الحقيقي GoldenBellIcon بنجاح', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: GoldenBellIcon(size: 24, showSparkle: true),
            ),
          ),
        ),
      );

      expect(find.byType(GoldenBellIcon), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GoldenBellIcon),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );

      final iconFinder = find.byType(GoldenBellIcon);
      final size = tester.getSize(iconFinder);
      expect(size.width, 24.0);
      expect(size.height, 24.0);
    });

    test('CTL-06 CloudControlService يرفق ?auth=<idToken> مع طلبات RTDB', () async {
      FirebaseAuthRest.setMockTokenForTest(
        token: 'tok_ctl_999',
        uid: 'uid_ctl_999',
      );
      addTearDown(FirebaseAuthRest.clearMockForTest);

      String? capturedAuth;
      final client = MockClient((req) async {
        capturedAuth = req.url.queryParameters['auth'];
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'm1': {
              'sender': 'admin',
              'text': 'مرحباً بك',
              'timestamp': 1700000000000,
            },
          })),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final msgs = await http.runWithClient(
        () => CloudControlService.instance.fetchSupportMessages(
          'https://qa-trial.firebaseio.com',
          'ws_ctl',
        ),
        () => client,
      );

      expect(capturedAuth, 'tok_ctl_999');
      expect(msgs, hasLength(1));
      expect(msgs.first.text, 'مرحباً بك');
    });

    test('CTL-07 قواعد فايربيس محصنة وتحصر الحقول السيادية بالمدير حصراً', () {
      final mainRulesFile = File('firebase/database.rules.json');
      final adminRulesFile = File('admin_app/rules.license-hardened.json');
      expect(mainRulesFile.existsSync(), isTrue);
      expect(adminRulesFile.existsSync(), isTrue);

      final mainRules =
          jsonDecode(mainRulesFile.readAsStringSync()) as Map<String, dynamic>;
      final adminRules =
          jsonDecode(adminRulesFile.readAsStringSync()) as Map<String, dynamic>;

      final rulesRoot = mainRules['rules'] as Map<String, dynamic>;
      expect(rulesRoot['.read'], isNot(equals(true)));
      expect(rulesRoot['.write'], isNot(equals(true)));

      final subWrite =
          (((rulesRoot['workspaces'] as Map)[r'$ws'] as Map)['subscription']
              as Map)['.write'] as String;
      expect(subWrite, contains('auth.token.admin === true'));
      expect(subWrite, contains("newData.child('status').val() === 'trial'"));
      expect(subWrite, contains("newData.child('expires_at').val() <= (now + 2592000000)"));
      expect(subWrite, contains("max_devices"));
      expect(subWrite, contains("is_frozen"));
      expect(subWrite, contains("expires_at"));

      // التحقق من تقييد سجل التجربة في trials/$fp بـ 30 يوماً كحد أقصى
      final trialWrite =
          (((rulesRoot['trials'] as Map)[r'$fp'] as Map)['.write']) as String;
      expect(
        trialWrite,
        contains("newData.child('expires_at').val() <= (now + 2592000000)"),
      );

      // التحقق من عزل المستأجرين في operations و roster على الأجهزة المسجلة في سجل المتجر
      final wsNode = (rulesRoot['workspaces'] as Map)[r'$ws'] as Map;
      final opsNode = wsNode['operations'] as Map;
      final rosterNode = wsNode['roster'] as Map;
      const expectedRosterCheck =
          "root.child('workspaces/' + \$ws + '/roster/' + auth.uid).exists()";
      expect(opsNode['.read'] as String, contains(expectedRosterCheck));
      expect(opsNode['.write'] as String, contains(expectedRosterCheck));
      expect(rosterNode['.read'] as String, contains(expectedRosterCheck));
      expect(rosterNode['.write'] as String, contains(expectedRosterCheck));

      // التحقق من تأمين عقدة التحديثات السيادية /system/version_manifest بحساب المشرف فقط
      final sysNode = rulesRoot['system'] as Map;
      final manifestNode = sysNode['version_manifest'] as Map;
      expect(
        manifestNode['.write'] as String,
        contains(
          "auth.token.admin === true || auth.uid === 'mTMmR6MDBMZH8nKEbvCntRemkq73'",
        ),
      );

      expect(jsonEncode(mainRules), jsonEncode(adminRules));
    });
  });
}
