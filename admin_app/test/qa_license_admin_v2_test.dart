// 🔑 QA — ترقية بطاقات المشتركين والبحث وبيانات التراخيص (2026-09-24).
//
// يختبر هذا الملف:
//  LIC-ADM01: تحويل وقراءة حقول المشترك (اسم المحل، العميل، الهاتف، كود الترخيص، معرف الجهاز)
//  LIC-ADM02: تحويل السجلات وتوليد المفتاح التلقائي عند غيابه عبر fromSubscriptionMap
//  LIC-ADM03: تصميم بطاقة المشترك الجديد (اسم المحل بارز مع الأيقونة، أزرار الاتصال وواتساب، أزرار النسخ)
//  LIC-ADM04: بطاقة بدون اسم منشأة تعرض الاسم الافتراضي بسلاسة
//  LIC-ADM05: توسيع البحث ليشمل اسم المحل والعميل والهاتف ومعرف الجهاز وكود الترخيص
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:license_admin/main.dart';
import 'package:license_admin/rtdb.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ar', null);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('License Admin Data Layer Tests', () {
    test('LIC-ADM01 قراءة وتحويل حقول المشترك كاملة في SubscriberEntry', () {
      const entry = SubscriberEntry(
        workspaceId: 'WS-TEST-001',
        clientName: 'عبدالرحمن باوزير',
        storeName: 'مركز المدينة التجاري',
        phone: '777000111',
        deviceId: 'DEVICE-ABCD1234',
        licenseKey: 'NX-ABCD-1234-EF56',
        deviceRef: 'DEVICE-ABCD1234',
        planType: 'enterprise',
        maxDevices: 5,
        expiresAtMs: 1800000000000,
        status: 'active',
        activatedAtMs: 1700000000000,
      );

      expect(entry.clientName, 'عبدالرحمن باوزير');
      expect(entry.storeName, 'مركز المدينة التجاري');
      expect(entry.phone, '777000111');
      expect(entry.deviceId, 'DEVICE-ABCD1234');
      expect(entry.licenseKey, 'NX-ABCD-1234-EF56');
      expect(entry.workspaceId, 'WS-TEST-001');
      expect(entry.maxDevices, 5);
      expect(entry.status, 'active');
    });

    test('LIC-ADM02 تحويل السجلات وتوليد المفتاح التلقائي عند غيابه', () {
      final entry = SubscriberEntry.fromSubscriptionMap(
        'WS-FALLBACK',
        {
          'clientName': 'سالم صالح',
          'storeName': 'بقالة البركة',
          'phone': '733123456',
          'device_id': 'DEVICE-XYZ999',
          'plan_type': 'individual',
          'max_devices': 1,
          'expires_at': 1800000000000,
          'status': 'trial',
        },
      );

      expect(entry.clientName, 'سالم صالح');
      expect(entry.storeName, 'بقالة البركة');
      expect(entry.phone, '733123456');
      expect(entry.deviceId, 'DEVICE-XYZ999');
      // بما أن licenseKey لم يُحدد، يجب توليده تلقائياً من معرف الجهاز
      expect(entry.licenseKey.startsWith('NX-'), isTrue);
      expect(entry.status, 'trial');
    });
  });

  group('SubscriberCard Widget Tests', () {
    testWidgets('LIC-ADM03 عرض اسم المحل بارزاً والعميل والهاتف وأزرار التواصل والنسخ',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final entry = SubscriberEntry(
        workspaceId: 'WS-CARD-01',
        clientName: 'طارق الأهدل',
        storeName: 'صيدلية النور الحديثة',
        phone: '777888999',
        deviceId: 'DEVICE-CARD-001',
        licenseKey: 'NX-CARD-0001-2026',
        deviceRef: 'DEVICE-CARD-001',
        planType: 'enterprise',
        maxDevices: 3,
        expiresAtMs: DateTime.now().add(const Duration(days: 45)).millisecondsSinceEpoch,
        status: 'active',
        activatedAtMs: DateTime.now().subtract(const Duration(days: 10)).millisecondsSinceEpoch,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubscriberCard(
              entry: entry,
              onExtend: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. اسم المحل بارز مع أيقونة المحل
      expect(find.text('صيدلية النور الحديثة'), findsOneWidget);
      expect(find.byIcon(Icons.storefront_rounded), findsOneWidget);

      // 2. اسم العميل ورقم الهاتف
      expect(find.text('طارق الأهدل'), findsOneWidget);
      expect(find.text('777888999'), findsOneWidget);

      // 3. أزرار التواصل (اتصال سريع + واتساب بنقرة)
      expect(find.byIcon(Icons.phone_in_talk), findsOneWidget);
      expect(find.text('اتصال سريع'), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
      expect(find.text('واتساب بنقرة'), findsOneWidget);

      // 4. كود الترخيص ومعرف الجهاز وأزرار النسخ
      expect(find.text('NX-CARD-0001-2026'), findsOneWidget);
      expect(find.text('DEVICE-CARD-001'), findsOneWidget);
      expect(find.byIcon(Icons.copy), findsNWidgets(2));

      // 5. زر التمديد السريع وشارة الخطة
      expect(find.text('تمديد بنقرة'), findsOneWidget);
      expect(find.text('فعّال'), findsOneWidget);
      expect(find.text('باقة مؤسسة (3 أجهزة مصرحة)'), findsOneWidget);
    });

    testWidgets('LIC-ADM04 بطاقة بدون اسم منشأة تعرض الاسم الافتراضي بسلاسة',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final entry = SubscriberEntry(
        workspaceId: 'WS-ANON-01',
        clientName: '',
        storeName: '',
        phone: '',
        deviceId: 'DEVICE-ANON-01',
        licenseKey: 'NX-ANON-0000-0001',
        deviceRef: 'DEVICE-ANON-01',
        planType: 'individual',
        maxDevices: 1,
        expiresAtMs: DateTime.now().add(const Duration(days: 5)).millisecondsSinceEpoch,
        status: 'trial',
        activatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubscriberCard(
              entry: entry,
              onExtend: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // التحقق من التراجع التلقائي
      expect(find.text('WS-ANON-01'), findsOneWidget);
      expect(find.text('مسؤول غير محدد'), findsOneWidget);
      expect(find.text('تجريبي'), findsOneWidget);
      expect(find.text('باقة فردية (جهاز واحد مصرح)'), findsOneWidget);
    });
  });

  group('Search Filtering Logic Tests', () {
    test('LIC-ADM05 التحقق من تغطية البحث لكافة الحقول الخمسة', () {
      const entries = [
        SubscriberEntry(
          workspaceId: 'WS-SEARCH-01',
          clientName: 'ياسر الشميري',
          storeName: 'سوبرماركت البركة',
          phone: '771122334',
          deviceId: 'DEVICE-DEV01-ABC',
          licenseKey: 'NX-ALBR-0001-2026',
          deviceRef: 'DEVICE-DEV01-ABC',
          planType: 'enterprise',
          maxDevices: 5,
          expiresAtMs: 1800000000000,
          status: 'active',
          activatedAtMs: 1700000000000,
        ),
        SubscriberEntry(
          workspaceId: 'WS-SEARCH-02',
          clientName: 'فؤاد المخلافي',
          storeName: 'مكتبة الفجر',
          phone: '733445566',
          deviceId: 'DEVICE-DEV02-XYZ',
          licenseKey: 'NX-FAJR-0002-2026',
          deviceRef: 'DEVICE-DEV02-XYZ',
          planType: 'individual',
          maxDevices: 1,
          expiresAtMs: 1800000000000,
          status: 'trial',
          activatedAtMs: 1700000000000,
        ),
      ];

      // 1. البحث باسم المحل
      bool filter(SubscriberEntry e, String q) {
        final query = q.trim().toLowerCase();
        return e.storeName.toLowerCase().contains(query) ||
            e.clientName.toLowerCase().contains(query) ||
            e.phone.toLowerCase().contains(query) ||
            e.deviceId.toLowerCase().contains(query) ||
            e.licenseKey.toLowerCase().contains(query) ||
            e.workspaceId.toLowerCase().contains(query);
      }

      expect(entries.where((e) => filter(e, 'البركة')).length, 1);
      expect(entries.where((e) => filter(e, 'البركة')).first.storeName, 'سوبرماركت البركة');

      // 2. البحث باسم العميل
      expect(entries.where((e) => filter(e, 'المخلافي')).length, 1);
      expect(entries.where((e) => filter(e, 'المخلافي')).first.clientName, 'فؤاد المخلافي');

      // 3. البحث برقم الهاتف
      expect(entries.where((e) => filter(e, '771122334')).length, 1);
      expect(entries.where((e) => filter(e, '771122334')).first.phone, '771122334');

      // 4. البحث بمعرف الجهاز
      expect(entries.where((e) => filter(e, 'DEV02-XYZ')).length, 1);
      expect(entries.where((e) => filter(e, 'DEV02-XYZ')).first.deviceId, 'DEVICE-DEV02-XYZ');

      // 5. البحث بكود الترخيص
      expect(entries.where((e) => filter(e, 'NX-FAJR')).length, 1);
      expect(entries.where((e) => filter(e, 'NX-FAJR')).first.licenseKey, 'NX-FAJR-0002-2026');
    });

    test('LIC-ADM06 فلترة الكبسولات تستبعد التجريبي من النشط وتعزل المنتهي وخلال 7 أيام', () {
      final now = 1700000000000;
      final entries = [
        SubscriberEntry(
          workspaceId: 'WS-ACTIVE',
          clientName: 'عميل نشط',
          storeName: 'متجر نشط',
          phone: '777111222',
          deviceId: 'DEV-1',
          licenseKey: 'KEY-1',
          deviceRef: 'DEV-1',
          planType: 'individual',
          maxDevices: 1,
          expiresAtMs: now + 30 * 86400000,
          status: 'active',
          activatedAtMs: now - 86400000,
        ),
        SubscriberEntry(
          workspaceId: 'WS-TRIAL',
          clientName: 'عميل تجريبي',
          storeName: 'متجر تجريبي',
          phone: '777222333',
          deviceId: 'DEV-2',
          licenseKey: 'KEY-2',
          deviceRef: 'DEV-2',
          planType: 'individual',
          maxDevices: 1,
          expiresAtMs: now + 3 * 86400000,
          status: 'trial',
          activatedAtMs: now - 86400000,
        ),
        SubscriberEntry(
          workspaceId: 'WS-EXPIRED',
          clientName: 'عميل منتهي',
          storeName: 'متجر منتهي',
          phone: '777333444',
          deviceId: 'DEV-3',
          licenseKey: 'KEY-3',
          deviceRef: 'DEV-3',
          planType: 'individual',
          maxDevices: 1,
          expiresAtMs: now - 86400000,
          status: 'active',
          activatedAtMs: now - 40 * 86400000,
        ),
        SubscriberEntry(
          workspaceId: 'WS-EXPIRING-7D',
          clientName: 'عميل وشيك الانتهاء',
          storeName: 'متجر وشيك',
          phone: '777444555',
          deviceId: 'DEV-4',
          licenseKey: 'KEY-4',
          deviceRef: 'DEV-4',
          planType: 'individual',
          maxDevices: 1,
          expiresAtMs: now + 4 * 86400000,
          status: 'active',
          activatedAtMs: now - 26 * 86400000,
        ),
      ];

      // فلتر النشطين: يستبعد التجريبي والمجمد والمنتهي
      final activeList = entries.where((s) =>
          !s.isFrozen &&
          s.status == 'active' &&
          (s.expiresAtMs > now || s.expiresAtMs > DateTime(2090).millisecondsSinceEpoch)).toList();
      expect(activeList.map((e) => e.workspaceId), containsAll(['WS-ACTIVE', 'WS-EXPIRING-7D']));
      expect(activeList.any((e) => e.workspaceId == 'WS-TRIAL'), isFalse);
      expect(activeList.any((e) => e.workspaceId == 'WS-EXPIRED'), isFalse);

      // فلتر التجريبيين: يعزل التجريبي بدقة
      final trialList = entries.where((s) => s.status == 'trial' || s.planType == 'trial').toList();
      expect(trialList.length, 1);
      expect(trialList.first.workspaceId, 'WS-TRIAL');

      // فلتر المنتهين: يعزل من انتهى ترخيصه
      final expiredList = entries.where((s) =>
          !s.isFrozen &&
          s.status != 'trial' &&
          s.expiresAtMs <= now &&
          s.expiresAtMs < DateTime(2090).millisecondsSinceEpoch).toList();
      expect(expiredList.length, 1);
      expect(expiredList.first.workspaceId, 'WS-EXPIRED');

      // فلتر خلال 7 أيام
      final sevenDays = now + 7 * 86400000;
      final expiring7dList = entries.where((s) =>
          !s.isFrozen && s.expiresAtMs > now && s.expiresAtMs <= sevenDays).toList();
      expect(expiring7dList.map((e) => e.workspaceId), containsAll(['WS-TRIAL', 'WS-EXPIRING-7D']));
    });

    testWidgets('LIC-ADM07 شاشة التفعيل الذكي تعرض البحث الذكي، بطاقة معاينة المنشأة، نوع الخطة، عدد الأجهزة، وتاريخ الانتهاء وزر التفعيل الموحد', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ActivationScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // التحقق من وجود حقل البحث الذكي
      expect(
        find.text('بحث ذكي (كود الجهاز device_id أو المساحة ws_id أو الهاتف)'),
        findsOneWidget,
      );

      // 1. بطاقة معاينة بيانات المنشأة المسترجعة تلقائياً
      expect(find.text('معاينة بيانات المنشأة المسترجعة تلقائياً'), findsOneWidget);

      // 2. اختيار نوع الخطة (سنوي / شهري / تجريبي)
      expect(find.text('نوع الخطة:'), findsOneWidget);
      expect(find.text('سنوي'), findsOneWidget);
      expect(find.text('شهري'), findsOneWidget);
      expect(find.text('تجريبي'), findsOneWidget);

      // 3. عدد الأجهزة المسموحة (max_devices)
      expect(find.text('عدد الأجهزة المسموحة (max_devices):'), findsOneWidget);

      // 4. تاريخ الانتهاء (expires_at)
      expect(find.text('تاريخ الانتهاء (expires_at)'), findsOneWidget);

      // زر واحد للتنفيذ: «تفعيل وترقية الترخيص»
      expect(find.text('تفعيل وترقية الترخيص'), findsOneWidget);
    });

    test('LIC-ADM13 تجميع سجلات المشتركين بنفس الهاتف أو معرف مساحة العمل وعرض الأجهزة المدمجة وآخر ظهور موحد', () {
      final entry1 = SubscriberEntry(
        workspaceId: 'ws_store_1',
        clientName: 'محمد العريقي',
        storeName: 'محلات العريقي التجارية',
        phone: '+967 771-234-567',
        deviceId: 'DEVICE-OWNER-01',
        licenseKey: 'NX-1111-2222-3333',
        deviceRef: 'DEVICE-OWNER-01',
        planType: 'enterprise',
        maxDevices: 3,
        activeDevices: 1,
        lastSeenAtMs: 1700000100000,
        expiresAtMs: 1800000000000,
        status: 'active',
        activatedAtMs: 1700000000000,
        rosterDevices: const [
          ConnectedDevice(
            deviceId: 'DEVICE-OWNER-01',
            deviceName: 'هاتف المالك',
            lastSeenAt: 1700000100000,
            isOwner: true,
          ),
        ],
      );

      final entry2 = SubscriberEntry(
        workspaceId: 'ws_store_dup',
        clientName: 'محمد العريقي',
        storeName: 'محلات العريقي التجارية',
        phone: '0771234567',
        deviceId: 'DEVICE-CASHIER-02',
        licenseKey: 'NX-4444-5555-6666',
        deviceRef: 'DEVICE-CASHIER-02',
        planType: 'enterprise',
        maxDevices: 5,
        activeDevices: 1,
        lastSeenAtMs: 1700000900000,
        expiresAtMs: 1850000000000,
        status: 'active',
        activatedAtMs: 1700000500000,
        rosterDevices: const [
          ConnectedDevice(
            deviceId: 'DEVICE-CASHIER-02',
            deviceName: 'كاشير الفرع',
            lastSeenAt: 1700000900000,
          ),
        ],
      );

      expect(normalizeSubscriberPhone(entry1.phone), normalizeSubscriberPhone(entry2.phone));
      final merged = entry1.mergeWith(entry2);
      expect(merged.maxDevices, 5);
      expect(merged.activeDevices, 2);
      expect(merged.rosterDevices.length, 2);
      expect(merged.lastSeenAtMs, 1700000900000);
      expect(merged.expiresAtMs, 1850000000000);
    });

    test('LIC-ADM08 محرك الذكاء الاصطناعي الشامل (Universal OpenAI-Compatible Client): حفظ الإعدادات ودرجة الحرارة 0.7', () async {
      SharedPreferences.setMockInitialValues({});
      await Rtdb.instance.load();
      expect(Rtdb.instance.deepSeekApiKey, isEmpty);
      expect(DualPersonaAiEngine.instance.hasApiKey, isFalse);
      expect(DualPersonaAiEngine.instance.baseUrl,
          'https://openrouter.ai/api/v1/chat/completions');
      expect(DualPersonaAiEngine.instance.modelId, 'deepseek/deepseek-chat');

      // حفظ الإعدادات الشاملة في SharedPreferences
      await Rtdb.instance.saveAiSettings(
        baseUrl: 'https://openrouter.ai/api/v1/chat/completions',
        apiKey: 'sk-or-v1-test-key-123',
        modelId: 'deepseek/deepseek-chat',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('deepseek_api_key'), 'sk-or-v1-test-key-123');
      expect(prefs.getString('ai_api_key'), 'sk-or-v1-test-key-123');
      expect(prefs.getString('ai_base_url'),
          'https://openrouter.ai/api/v1/chat/completions');
      expect(prefs.getString('ai_model_id'), 'deepseek/deepseek-chat');
      expect(DualPersonaAiEngine.instance.apiKey, 'sk-or-v1-test-key-123');
      expect(DualPersonaAiEngine.instance.hasApiKey, isTrue);

      // التحقق من ثوابت المحرك الشامل
      expect(kDefaultAiEndpoint,
          'https://openrouter.ai/api/v1/chat/completions');
      expect(kDefaultAiModel, 'deepseek/deepseek-chat');
      expect(kOwnerTemperature, 0.7);
      expect(kDeepSeekMaxTokens, 2048);

      // التحقق من موجه النظام الجديد (Persona: الرفيق العفوي متعدد الاهتمامات)
      final ownerSession = DualPersonaAiEngine.instance.ownerSession;
      expect(ownerSession.temperature, 0.7);
      expect(ownerSession.maxTokens, 2048);
      expect(ownerSession.systemInstruction,
          contains('أنت رفيق شخصي تفاعلي، ذكي، وخفيف الظل'));
      expect(
          ownerSession.systemInstruction,
          contains(
              'إنسان واسع الاطلاع، سريع البديهة، حاضر الفكاهة، وتجيد خوض الأحاديث في شتى مجالات الحياة'));
      expect(
          ownerSession.systemInstruction,
          contains(
              'ولا تجرّ الحديث أبداً نحو البرمجة أو الأكواد ما لم يطلب هو ذلك صراحة.'));
      expect(
          ownerSession.systemInstruction,
          contains(
              'تحدث بلهجة عربية عفوية وودودة، بلا مقدمات ترحيبية رسمية مكررة'));
      expect(ownerSession.systemInstruction,
          contains('كن موجزاً ومركزاً وذا لمسة ذكية'));

      // التحقق من النمط الثاني: الدعم الفني للمستخدمين (Client Support Mode)
      final supportSession =
          DualPersonaAiEngine.instance.supportSessionFor('WS-CLIENT-01');
      expect(supportSession.temperature, 0.2);
      expect(
          supportSession.systemInstruction,
          contains(
              'أنت موظف دعم فني بشري محترف لمنظومة "المحاسب" وتطبيق التراخيص'));
      expect(supportSession.systemInstruction,
          contains(kMandatoryEscalationText));

      // استقلال الجلستين وتفريغهما المباشر
      ownerSession.seedHistory([
        const AiChatMessage(
            id: '1', role: 'user', text: 'مساء الخير يا صديقي', timestamp: 100),
      ]);
      expect(ownerSession.history.length, 1);
      expect(supportSession.history, isEmpty);
      DualPersonaAiEngine.instance.clearOwnerSession();
      expect(ownerSession.history, isEmpty);

      // التحقق من إمكانية تفريغ المفتاح
      await Rtdb.instance.saveDeepSeekApiKey('');
      expect(Rtdb.instance.deepSeekApiKey, isEmpty);
      expect(DualPersonaAiEngine.instance.hasApiKey, isFalse);
    });

    testWidgets(
        'LIC-ADM09 واجهة رفيق المالك تعرض تنبيه إدخال مفتاح API عند غيابه ونافذة الإعدادات الشاملة (الرابط، المفتاح، النموذج، موجه النظام)',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await Rtdb.instance.load();
      await Rtdb.instance.saveDeepSeekApiKey('');

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: OwnerCompanionScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('رفيقك الشخصي الذكي (Universal AI Chat)'), findsOneWidget);
      expect(find.text('تفريغ الجلسة'), findsOneWidget);
      expect(find.text('إدخال المفتاح'), findsOneWidget);
      expect(find.textContaining('API Key'), findsWidgets);

      // فتح نافذة الإعدادات عبر أيقونة الترس والتحقق من وجود الحقول الأربعة
      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();
      expect(find.text('رابط الخدمة (Base URL / Endpoint)'), findsOneWidget);
      expect(find.text('مفتاح الواجهة (API Key)'), findsOneWidget);
      expect(find.text('اسم النموذج (Model ID)'), findsOneWidget);
      expect(find.text('موجه النظام (System Prompt)'), findsOneWidget);
    });

    testWidgets(
        'LIC-ADM10 تفريغ حقل الإدخال فور الضغط على زر الإرسال وبقاء الرسالة مع تنبيه لطيف وزر إعادة المحاولة عند الخطأ',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await Rtdb.instance.load();
      await Rtdb.instance.saveDeepSeekApiKey('');
      DualPersonaAiEngine.instance.clearOwnerSession();

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: OwnerCompanionScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // كتابة رسالة في حقل الإدخال
      final textField = find.byType(TextField);
      expect(textField, findsOneWidget);
      await tester.enterText(
          textField, 'رسالة تجريبية لاختبار عدم الحذف عند الفشل');
      await tester.pump();

      // الضغط على زر الإرسال
      final sendBtn = find.byIcon(Icons.send_rounded);
      expect(sendBtn, findsOneWidget);
      await tester.tap(sendBtn);
      await tester.pumpAndSettle();

      // 1. التحقق من تفريغ حقل الإدخال النصي فوراً
      final tfWidget = tester.widget<TextField>(textField);
      expect(tfWidget.controller?.text, isEmpty);

      // 2. التحقق من بقاء رسالة المستخدم معروضة بشكل دائم وعدم حذفها عند فشل الاستدعاء
      expect(find.text('رسالة تجريبية لاختبار عدم الحذف عند الفشل'),
          findsOneWidget);

      // 3. التحقق من ظهور التنبيه اللطيف وزر "إعادة المحاولة"
      expect(find.text('إعادة المحاولة'), findsOneWidget);

      // 4. التحقق من بقاء الرسالة محفوظة داخل سجل الجلسة مع حالة الخطأ
      final history = DualPersonaAiEngine.instance.ownerSession.history;
      expect(history.length, 1);
      expect(history.first.text, 'رسالة تجريبية لاختبار عدم الحذف عند الفشل');
      expect(history.first.hasError, isTrue);

      // 5. التحقق من إمكانية الضغط المطول على الرسالة لنسخ نصها
      await tester
          .longPress(find.text('رسالة تجريبية لاختبار عدم الحذف عند الفشل'));
      await tester.pumpAndSettle();
      expect(find.textContaining('تم نسخ'), findsOneWidget);
    });

    test(
        'LIC-ADM11 المرسل الديناميكي الشامل (Dynamic Request Dispatcher): الترويسات القياسية ومعالجة أخطاء 401/404/429',
        () async {
      SharedPreferences.setMockInitialValues({});
      await Rtdb.instance.load();
      await Rtdb.instance.saveAiSettings(
        baseUrl: 'https://openrouter.ai/api/v1/chat/completions',
        apiKey: 'sk-or-v1-live-999',
        modelId: 'deepseek/deepseek-chat',
      );
      final engine = DualPersonaAiEngine.instance;
      engine.clearOwnerSession();

      final mockClient = MockClient((request) async {
        expect(request.url.toString(),
            'https://openrouter.ai/api/v1/chat/completions');
        expect(request.headers['Authorization'], 'Bearer sk-or-v1-live-999');
        expect(request.headers['Content-Type'], contains('application/json'));
        expect(request.headers['HTTP-Referer'], 'https://nexora.app');
        expect(request.headers['X-Title'], 'Nexora Admin');

        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], 'deepseek/deepseek-chat');
        expect(body['temperature'], 0.7);

        final messages = body['messages'] as List<dynamic>;
        expect(messages.length, 2);
        final sysMsg = messages.first as Map<String, dynamic>;
        expect(sysMsg['role'], 'system');
        expect(sysMsg['content'], kOwnerSystemInstruction.trim());

        final userMsg = messages[1] as Map<String, dynamic>;
        expect(userMsg['role'], 'user');
        expect(userMsg['content'], 'ما رأيك في جلسة سمر الليلة مع كوب شاي؟');

        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'id': 'chatcmpl-123',
            'choices': [
              {
                'index': 0,
                'message': {
                  'role': 'assistant',
                  'content':
                      'يا سلام! جلسة السمر مع الشاي الموزون هي أفضل استراحة بعد يوم طويل، حدثني كيف كان يومك؟'
                },
                'finish_reason': 'stop'
              }
            ]
          })),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final reply = await engine.ownerSession.sendMessage(
        'ما رأيك في جلسة سمر الليلة مع كوب شاي؟',
        httpClient: mockClient,
      );

      expect(
          reply,
          'يا سلام! جلسة السمر مع الشاي الموزون هي أفضل استراحة بعد يوم طويل، حدثني كيف كان يومك؟');
      expect(engine.ownerSession.history.length, 2);
      expect(engine.ownerSession.history[0].isUser, isTrue);
      expect(engine.ownerSession.history[1].isAssistant, isTrue);

      // فحص معالجة رموز الأخطاء 401 و 404 و 429 بوضوح
      expect(
          DualPersonaAiEngine.parseOpenAiError(401, '{"error":{"message":"Invalid key"}}'),
          contains('المفتاح غير صحيح'));
      expect(
          DualPersonaAiEngine.parseOpenAiError(404, '{"error":{"message":"Model not found"}}', 'gpt-99'),
          contains('النموذج غير موجود'));
      expect(
          DualPersonaAiEngine.parseOpenAiError(429, '{"error":{"message":"Rate limit"}}'),
          contains('نفاد الرصيد'));
    });

    test(
        'LIC-ADM12 (R1) تطهير تطبيق الإدارة من الرمز المضمن واستخدام String.fromEnvironment(ADMIN_REFRESH_TOKEN) مع رسالة خطأ واضحة محلياً',
        () async {
      SharedPreferences.setMockInitialValues({});
      final rtdb = Rtdb.instance;
      await rtdb.load();

      // عند التشغيل محلياً بدون تمرير ADMIN_REFRESH_TOKEN يظهر التنبيه الواضح
      expect(kAdminRefreshTokenDefault, isEmpty);
      expect(rtdb.isAdminTokenMissing, isTrue);
      expect(rtdb.lastAuthError, contains('ADMIN_REFRESH_TOKEN'));
    });
  });
}
