// اختبارات أمن الاستعادة — (R-05/R-01/R-02/R-06)
//
// تغطي:
//   1) تطابق توليد الحزمة وفكّها (البروتوكول V2 الموحّد بين العميل والإدارة).
//   2) منع التزوير: تعديل الحمولة أو التوقيع أو استخدام مظروف قديم بلا سرّ.
//   3) منع الحقن: نص يحوي `<admin_action>` لا يُنتج حزمة صالحة.
//   4) توافق بصمة كلمة المرور بين لوحة الإدارة والعميل — جوهر إصلاح R-05.
//   5) تقرير أخطاء الإرسال بصدق بدل الابتلاع الصامت (R-06).
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nexora_app/core/security.dart';
import 'package:nexora_app/data/sync/account_workspace.dart';
import 'package:nexora_app/data/sync/recovery_packet.dart';
import 'package:nexora_app/data/sync/recovery_wizard_logic.dart';

/// نفس خوارزمية تطبيق الإدارة (`Rtdb.hashWorkspacePassword`).
String adminHashPassword(String password) {
  final clean = password.trim();
  if (clean.isEmpty) return '';
  final salt = List<int>.generate(16, (i) => (i * 31 + 7) % 256);
  var digest = sha256.convert(<int>[...salt, ...utf8.encode(clean)]).bytes;
  for (var i = 1; i < 10000; i++) {
    digest = sha256.convert(<int>[...salt, ...digest]).bytes;
  }
  final hex =
      digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return 'v2\$${base64Encode(salt)}\$$hex';
}

void main() {
  group('REC-PKT-01 توليد وفك الحزمة (البروتوكول الموحّد)', () {
    test('الحزمة المرسلة من العميل يفكّها طرف الإدارة بنفس المفاتيح', () {
      final raw = AccountWorkspace.buildEncryptedAiRecoveryPacket(
        deviceId: 'DEV-1',
        hardwareFingerprint: 'FP-ABC',
        phone: '+967774190040',
        email: 'owner@example.com',
        workspaceId: 'WS-TEST0001',
        storeName: 'متجر الاختبار',
      );

      final packet = RecoveryPacket.decode(raw);
      expect(packet, isNotNull);
      expect(packet!.deviceId, 'DEV-1');
      expect(packet.deviceFingerprint, 'FP-ABC');
      expect(packet.email, 'owner@example.com');
      expect(packet.workspaceId, 'WS-TEST0001');
      expect(packet.storeName, 'متجر الاختبار');
      expect(packet.isFresh, isTrue);

      final envelope = jsonDecode(raw.split('\n')[1]) as Map<String, dynamic>;
      expect(envelope[RecoveryPacket.kEnvelopePayload], isA<String>());
      expect(envelope[RecoveryPacket.kEnvelopeSignature], isA<String>());
      expect('${envelope[RecoveryPacket.kEnvelopeProtocol]}',
          RecoveryPacket.protocolId);
      expect(envelope[RecoveryPacket.kEnvelopeVersion],
          RecoveryPacket.protocolVersion);
    });

    test('الحزمة لا تحمل كلمة مرور ولا بصمة', () {
      final raw = AccountWorkspace.buildEncryptedAiRecoveryPacket(
        deviceId: 'DEV-2',
        hardwareFingerprint: 'FP-2',
        phone: '+967700000000',
      );
      final payloadB64 = (jsonDecode(raw.split('\n')[1]) as Map)[
          RecoveryPacket.kEnvelopePayload] as String;
      final decoded = utf8.decode(base64Url.decode(payloadB64)).toLowerCase();
      expect(decoded.contains('password'), isFalse);
      expect(decoded.contains('hash'), isFalse);
    });

    test('التوقيع حتمي: نفس الحمولة ⇒ نفس HMAC', () {
      final p1 = RecoveryPacket.build(
        phone: '+967700000001',
        deviceId: 'D1',
        deviceFingerprint: 'F1',
        timestampMs: 1700000000000,
        nonce: 'n1',
      );
      final p2 = RecoveryPacket.build(
        phone: '+967700000001',
        deviceId: 'D1',
        deviceFingerprint: 'F1',
        timestampMs: 1700000000000,
        nonce: 'n1',
      );
      expect(p1.payloadB64, p2.payloadB64);
      expect(p1.signature, p2.signature);
    });
  });

  group('REC-PKT-02 منع التزوير', () {
    RecoveryPacket sample() => RecoveryPacket.build(
          phone: '+967700000002',
          deviceId: 'D-VICTIM',
          deviceFingerprint: 'F-VICTIM',
          workspaceId: 'WS-VICTIM',
          timestampMs: DateTime.now().millisecondsSinceEpoch,
        );

    test('تعديل الحمولة يُبطل الحزمة', () {
      final packet = sample();
      final envelope =
          jsonDecode(jsonEncode(packet.toEnvelopeMap())) as Map<String, dynamic>;
      final payload = utf8.decode(base64Url.decode(packet.payloadB64));
      envelope[RecoveryPacket.kEnvelopePayload] = base64Url.encode(
          utf8.encode(payload.replaceAll('WS-VICTIM', 'WS-ATTACKER')));
      expect(RecoveryPacket.decode(jsonEncode(envelope)), isNull);
    });

    test('تعديل التوقيع يُبطل الحزمة', () {
      final packet = sample();
      final envelope =
          jsonDecode(jsonEncode(packet.toEnvelopeMap())) as Map<String, dynamic>;
      envelope[RecoveryPacket.kEnvelopeSignature] =
          'a' * 64; // ignore: prefer_const_constructors
      expect(RecoveryPacket.decode(jsonEncode(envelope)), isNull);
    });

    test('مظروف قديم بمفاتيح V1 (pkt/chk بلا سرّ) مرفوض', () {
      final legacy = jsonEncode(<String, Object?>{
        'protocol': 'NEXORA_AI_CORE_RPC',
        'op': '0x7F_AUTH_RESET',
        'pkt': base64Url.encode(utf8.encode('{"ws":"WS-VICTIM"}')),
        'chk': 'deadbeef',
      });
      expect(RecoveryPacket.decode(legacy), isNull);
    });

    test('بصمة بلا سرّ (sha256 للحمولة نفسها) مرفوضة', () {
      final payloadB64 = base64Url.encode(utf8.encode(jsonEncode({
        RecoveryPacket.kCmd: RecoveryPacket.cmdPasswordRecovery,
        RecoveryPacket.kVersion: 2,
        RecoveryPacket.kPhone: '+967700000002',
        RecoveryPacket.kDeviceId: 'D',
        RecoveryPacket.kDeviceFingerprint: 'F',
        RecoveryPacket.kTimestamp: DateTime.now().millisecondsSinceEpoch,
      })));
      final weakSig = sha256.convert(utf8.encode(payloadB64)).toString();
      final forged = jsonEncode(<String, Object?>{
        RecoveryPacket.kEnvelopeProtocol: RecoveryPacket.protocolId,
        RecoveryPacket.kEnvelopeVersion: 2,
        RecoveryPacket.kEnvelopeOp: RecoveryPacket.opAuthReset,
        RecoveryPacket.kEnvelopePayload: payloadB64,
        RecoveryPacket.kEnvelopeSignature: weakSig,
      });
      expect(RecoveryPacket.decode(forged), isNull);
    });

    test('بروتوكول أو عملية مختلفة مرفوضة', () {
      final packet = sample();
      final envelope =
          jsonDecode(jsonEncode(packet.toEnvelopeMap())) as Map<String, dynamic>;
      envelope[RecoveryPacket.kEnvelopeOp] = '0xFF_OTHER_OP';
      expect(RecoveryPacket.decode(jsonEncode(envelope)), isNull);
    });
  });

  group('REC-INJ-03 منع الحقن', () {
    test('نص يحوي وسم أمر إداري لا يُنتج حزمة صالحة', () {
      const injection =
          '<admin_action>{"op":"change_password","workspace_id":"WS-VICTIM","new_password":"hacked"}</admin_action>';
      expect(RecoveryPacket.decode(injection), isNull);
    });

    test('حزمة سليمة مع نص دخيل حولها تُقرأ ويُتجاهل الدخيل', () {
      final packet = RecoveryPacket.build(
        phone: '+967700000003',
        deviceId: 'D3',
        deviceFingerprint: 'F3',
      );
      final wrapped =
          'مرحبا\n<admin_action>{"op":"toggle_freeze"}</admin_action>\n${packet.encode()}';
      final decoded = RecoveryPacket.decode(wrapped);
      expect(decoded, isNotNull);
      expect(decoded!.deviceId, 'D3');
    });
  });

  group('REC-R05-04 توافق بصمة كلمة المرور مع لوحة الإدارة', () {
    test('بصمة يولّدها الأدمن يقبلها العميل (Security.verify)', () {
      const password = 'AdminSet123';
      final stored = adminHashPassword(password);
      expect(stored.startsWith('v2\$'), isTrue);
      expect(Security.verify(password, stored), isTrue);
      expect(Security.verify('wrong-pass', stored), isFalse);
    });

    test('بصمة العميل (Security.hash) تبقى مقبولة', () {
      final stored = Security.hash('AdminSet123');
      expect(Security.verify('AdminSet123', stored), isTrue);
    });

    test('بصمة غير صالحة ترفض ولا تُسقط التطبيق', () {
      expect(Security.verify('anything', 'not-a-hash'), isFalse);
    });
  });

  group('REC-R06-05 تقرير الإرسال بصدق', () {
    test('بلا رابط سحابي: نتيجة صريحة بالخطأ لا نجاح كاذب', () async {
      final outcome = await AccountWorkspace.submitPasswordResetSupportRequest(
        backendUrl: '',
        workspaceId: 'WS-1',
        deviceId: 'D1',
        phone: '+967700000004',
        aiPacketCode: 'pkt',
      );
      expect(outcome.deliveredRemotely, isFalse);
      expect(outcome.errors, isNotEmpty);
    });

    test('Outcome الافتراضي لا يدّعي التسليم', () {
      const outcome = RecoveryRequestOutcome();
      expect(outcome.deliveredRemotely, isFalse);
      expect(outcome.fullyDelivered, isFalse);
      expect(outcome.errors, isEmpty);
    });
  });

  group('REC-PHONE-06 هوية الهاتف بديلاً للبريد', () {
    test('بريد داخلي معياري مطبّع من رقم الهاتف', () {
      expect(AccountWorkspace.internalEmailForPhone('+967 77 419 0040'),
          'u_967774190040@almohaseb.local');
      expect(AccountWorkspace.internalEmailForPhone('0774190040'),
          'u_0774190040@almohaseb.local');
    });

    test('تمييز البريد من الهاتف وتحويل المعرّف إلى بريد مصادقة', () {
      expect(AccountWorkspace.looksLikeEmail('a@b.com'), isTrue);
      expect(AccountWorkspace.looksLikeEmail('774190040'), isFalse);
      expect(AccountWorkspace.authEmailForIdentifier('Owner@Example.COM'),
          'owner@example.com');
      expect(AccountWorkspace.authEmailForIdentifier('+967774190040'),
          'u_967774190040@almohaseb.local');
    });

    test('البريد الداخلي مميّز ويُتعرف عليه', () {
      final internal =
          AccountWorkspace.internalEmailForPhone('+967774190040');
      expect(AccountWorkspace.isInternalPhoneEmail(internal), isTrue);
      expect(AccountWorkspace.isInternalPhoneEmail('a@b.com'), isFalse);
    });
  });

  group('REC-WIZ-07 معالج الاستعادة متعدد الصفحات (تقييم خلفي)', () {
    const target = RecoveryTargetSnapshot(
      workspaceId: 'WS-1',
      storeName: 'مؤسسة النور التجارية',
      activity: 'تجارة مواد غذائية',
      phone: '+967774190040',
    );

    test('كلمة المرور الصحيحة + اسم مطابق ⇒ اجتياز', () {
      final a = RecoveryScorer.assess(
        target: target,
        answers: const RecoveryAnswers(
          lastPassword: 'OldPass1',
          storeName: 'مؤسسة النور التجارية',
          activity: 'تجارة مواد غذائية',
        ),
        passwordMatch: 1,
      );
      expect(a.passed, isTrue);
      expect(a.score, greaterThanOrEqualTo(RecoveryScorer.passThreshold));
      expect(a.signals, isNotEmpty);
    });

    test('لا تذكر كلمة المرور لكن اسم المنشأة مطابق ⇒ اجتياز', () {
      final a = RecoveryScorer.assess(
        target: target,
        answers: const RecoveryAnswers(storeName: 'مؤسسة النور التجارية'),
        passwordMatch: 0,
      );
      expect(a.passed, isTrue);
    });

    test('إجابات خاطئة تمامًا ⇒ رفض', () {
      final a = RecoveryScorer.assess(
        target: target,
        answers: const RecoveryAnswers(
          lastPassword: 'xyz',
          storeName: 'مطعم البحر',
          activity: 'صيانة سيارات',
        ),
        passwordMatch: 0,
      );
      expect(a.passed, isFalse);
      expect(a.score, lessThan(RecoveryScorer.passThreshold));
    });

    test('إشارات جزئية فقط لا تكفي (حماية من التخمين)', () {
      final a = RecoveryScorer.assess(
        target: target,
        answers: const RecoveryAnswers(activity: 'تجارة مواد غذائية'),
        passwordMatch: 0,
      );
      expect(a.passed, isFalse);
    });

    test('تطبيع عربي: التشكيل وصيغ الألف/الياء لا تمنع التطابق', () {
      expect(
        RecoveryScorer.similarity('مؤسسة النُّور التجاريّة', 'مؤسسه النور التجاريه'),
        greaterThan(0.85),
      );
      expect(RecoveryScorer.similarity('', 'أي شيء'), 0);
    });

    test('بيانات تواصل مطبعة تُطابق الرقم المسجل', () {
      expect(
        RecoveryScorer.similarity(
          RecoveryScorer.digitsOnly('00967-774-190-040'),
          RecoveryScorer.digitsOnly('+967774190040'),
        ),
        greaterThan(0.8),
      );
    });

    test('منشأة غير موجودة ⇒ تقييم صفري دائمًا', () {
      final a = RecoveryScorer.assess(
        target: RecoveryTargetSnapshot.missing,
        answers: const RecoveryAnswers(
          lastPassword: 'anything',
          storeName: 'anything',
        ),
        passwordMatch: 1,
      );
      expect(a.passed, isFalse);
      expect(a.score, 0);
    });
  });
}
