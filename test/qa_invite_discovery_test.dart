// QA — اكتشاف مساحة العمل من رمز الدعوة وحده (المعمارية الصامتة).
//
// المنضم لا يعرف WS-XXXXXXXX الخاص بالمدير — يُدخل PIN/توكن فقط،
// وfindWorkspaceByInvite تمسح /workspaces (shallow) وتعيد المساحة
// صاحبة الدعوة الحية المطابقة.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';

void main() {
  const url = 'https://qa-disc.europe-west1.firebasedatabase.app';
  final live = DateTime.now().add(const Duration(hours: 12)).toIso8601String();
  final dead =
      DateTime.now().subtract(const Duration(hours: 1)).toIso8601String();

  http.Response js(Object? v) =>
      http.Response.bytes(utf8.encode(jsonEncode(v)), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});

  http.Client fake() => MockClient((req) async {
        final p = req.url.path;
        if (p == '/invite_index/pin_654321.json') {
          return js({'ws': 'WS-BBBB3333', 'expiresAt': live});
        }
        if (p == '/invite_index/tok_TOKLIVE1.json') {
          return js({'ws': 'WS-BBBB3333', 'expiresAt': live});
        }
        if (p == '/invite_index/pin_111222.json') {
          return js({'ws': 'WS-AAAA2222', 'expiresAt': dead});
        }
        if (p == '/workspaces.json') {
          // لو استُدعي المسح القديم بالخطأ سيفشل الاختبار، لأن legacyInviteScanFallback = false
          throw StateError('Should not scan /workspaces.json when legacyInviteScanFallback is false');
        }
        return js(null);
      });

  test('JOIN-DISC-01 PIN حي يحدد مساحة المدير الصحيحة', () async {
    final ws = await http.runWithClient(
      () => CloudJoin.findWorkspaceByInvite(
          backendUrl: url, tokenOrPin: '654321'),
      fake,
    );
    expect(ws, 'WS-BBBB3333');
  });

  test('JOIN-DISC-02 توكن كامل يحدد المساحة الصحيحة', () async {
    final ws = await http.runWithClient(
      () => CloudJoin.findWorkspaceByInvite(
          backendUrl: url, tokenOrPin: 'TOKLIVE1'),
      fake,
    );
    expect(ws, 'WS-BBBB3333');
  });

  test('JOIN-DISC-03 دعوة منتهية أو رمز خاطئ ⇒ null', () async {
    final expired = await http.runWithClient(
      () => CloudJoin.findWorkspaceByInvite(
          backendUrl: url, tokenOrPin: '111222'),
      fake,
    );
    expect(expired, isNull);
    final wrong = await http.runWithClient(
      () => CloudJoin.findWorkspaceByInvite(
          backendUrl: url, tokenOrPin: '000000'),
      fake,
    );
    expect(wrong, isNull);
  });
}
