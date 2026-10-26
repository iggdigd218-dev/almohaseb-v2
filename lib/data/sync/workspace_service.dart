// Workspace bootstrap.
// (المعمارية الصامتة) يُولّد لكل تثبيت جديد معرف مساحة عمل فريداً وعشوائياً
// بصيغة WS-XXXXXXXX — فتعمل كل منشأة في مسار سحابي معزول تماماً
// /workspaces/{WS_ID}/ ولا تتصادم بياناتها مع أي منشأة أخرى على قاعدة
// النظام الرسمية المشتركة (كان الجميع سابقاً على 'default' الواحد).
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../repository.dart';

const defaultWorkspaceId = 'default';
const _workspaceIdSetting = 'sync.workspaceId';

/// (اختبارات فقط) إبقاء المعرف القديم 'default': حزم كثيرة تبني
/// فرضياتها على مسارات workspaces/default — تضبطه على true في main().
bool debugForceLegacyWorkspaceId = false;

/// أبجدية آمنة بلا حروف ملتبسة (0/O، 1/I/L) — قراءة ونسخ بلا أخطاء.
const _wsAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

/// يولّد معرف مساحة فريداً: WS- تليها 8 خانات عشوائية آمنة (Random.secure).
String generateWorkspaceId() {
  final rnd = Random.secure();
  final b = StringBuffer('WS-');
  for (var i = 0; i < 8; i++) {
    b.write(_wsAlphabet[rnd.nextInt(_wsAlphabet.length)]);
  }
  return b.toString();
}

/// هل المعرف من الجيل القديم المشترك ('default' أو فارغ)؟
bool isLegacyWorkspaceId(String? id) {
  final t = (id ?? '').trim();
  return t.isEmpty || t == defaultWorkspaceId;
}

Future<String> ensureWorkspace(Database db, {Repo? repo}) async {
  // ══ (2026-09-30) قاعدة سيادية صارمة: المساحة مرتبطة حصراً ببريد المدير ══
  // مساحة عمل واحدة فقط لكل بريد في السحابة وممنوع المزامنة خارجها.

  // 1. فحص الإعداد الصريح المحفوظ والبريد الإلكتروني
  String? preferredId;
  String? accountEmail;
  String? rawPref;
  String accountType = '';
  try {
    if (repo != null) {
      final stPref = await repo.settings();
      accountType = (stPref['account.type'] ?? '').trim();
      accountEmail = (stPref['account.email'] ?? stPref['email'] ?? '').trim();
      // للمستخدم المحلي المستقل بدون حساب جوجل/بريد: ممنوع إنشاء مساحة عمل WS-*، ويبقى دائماً على 'default'.
      if (accountType == 'individual' && accountEmail.isEmpty) {
        final now = DateTime.now().toIso8601String();
        await db.insert(
          'workspaces',
          {
            'id': defaultWorkspaceId,
            'name': (stPref['businessName'] ?? 'متجري').trim().isNotEmpty
                ? (stPref['businessName'] ?? 'متجري').trim()
                : 'متجري',
            'owner_google_id': '',
            'owner_email': '',
            'owner_name': '',
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        await repo.setSetting(_workspaceIdSetting, defaultWorkspaceId);
        repo.debugSetWorkspaceId(defaultWorkspaceId);
        return defaultWorkspaceId;
      }
      final p = (stPref[_workspaceIdSetting] ?? '').trim();
      rawPref = p;
      if (p.isNotEmpty && p != 'default') {
        final hit = await db.query('workspaces',
            columns: ['id'], where: 'id = ?', whereArgs: [p], limit: 1);
        if (hit.isNotEmpty) preferredId = p;
      }
    }
  } catch (_) {}

  // 1. إذا كان لدينا معرف معتمد وموجود بالفعل في جدول workspaces (أو تم اختياره صراحة)، نعتمده فوراً ولا نتجاوزه!
  if (preferredId != null && preferredId.isNotEmpty) {
    if (accountEmail != null && accountEmail.isNotEmpty) {
      await db.update('workspaces',
          {'owner_email': accountEmail},
          where: 'id = ? AND (owner_email IS NULL OR TRIM(owner_email) = \'\')',
          whereArgs: [preferredId]);
    }
    await repo?.setSetting(_workspaceIdSetting, preferredId);
    return preferredId;
  }

  // 2. إذا لم يكن هناك معرف صريح ولكن لدينا بريد إلكتروني، نبحث عن المنشأة الحقيقية للمستخدم
  // مع إعطاء الأولوية القصوى للمنشأة التي تحمل اسماً تجارياً حقيقياً (وليست منشأة افتراضية فارغة)
  if (accountEmail != null && accountEmail.isNotEmpty) {
    final emailRows = await db.query(
      'workspaces',
      where: debugForceLegacyWorkspaceId
          ? 'owner_email = ?'
          : "owner_email = ? AND id != 'default'",
      whereArgs: [accountEmail],
      orderBy: "CASE WHEN name != 'متجري' AND name != 'منشأتي' AND TRIM(name) != '' THEN 0 ELSE 1 END, rowid DESC",
      limit: 1,
    );
    if (emailRows.isNotEmpty) {
      final emailWsId = emailRows.first['id'] as String;
      await repo?.setSetting(_workspaceIdSetting, emailWsId);
      return emailWsId;
    }
  }

  // 3. فحص جدول workspaces لأي مساحة حقيقية (غير default) ناتجة عن انضمام أو استيراد
  final realRows = await db.query(
    'workspaces',
    where: "id != 'default'",
    orderBy: "CASE WHEN name != 'متجري' AND name != 'منشأتي' AND TRIM(name) != '' THEN 0 ELSE 1 END, rowid DESC",
    limit: 1,
  );
  if (realRows.isNotEmpty) {
    final selectedId = realRows.first['id'] as String;
    if (accountEmail != null && accountEmail.isNotEmpty) {
      await db.update('workspaces',
          {'owner_email': accountEmail},
          where: 'id = ? AND (owner_email IS NULL OR TRIM(owner_email) = \'\')',
          whereArgs: [selectedId]);
    }
    await repo?.setSetting(_workspaceIdSetting, selectedId);
    return selectedId;
  }

  // 3. إذا لم توجد مساحة في الجدول ولكن كان هناك معرف في الإعدادات:
  if (rawPref != null && rawPref.isNotEmpty && rawPref != 'default') {
    final now = DateTime.now().toIso8601String();
    await db.insert(
      'workspaces',
      {
        'id': rawPref,
        'name': 'متجري',
        'owner_google_id': '',
        'owner_email': accountEmail ?? '',
        'owner_name': '',
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return rawPref;
  }

  // 4. مساحة افتراضية إن وُجدت: في بيئة الاختبار نُبقيها، وفي الإنتاج نُرقّيها لمعرّف WS- فريد معزول
  final defaultRows = await db.query(
    'workspaces',
    where: "id = 'default'",
    limit: 1,
  );
  if (defaultRows.isNotEmpty) {
    if (debugForceLegacyWorkspaceId) {
      return defaultWorkspaceId;
    }
    final newId = generateWorkspaceId();
    final now = DateTime.now().toIso8601String();
    final baseRow = defaultRows.first;
    await db.insert(
      'workspaces',
      {
        'id': newId,
        'name': (baseRow['name'] as String?)?.isNotEmpty == true
            ? baseRow['name']
            : 'متجري',
        'owner_google_id': baseRow['owner_google_id'] ?? '',
        'owner_email': (accountEmail != null && accountEmail.isNotEmpty)
            ? accountEmail
            : (baseRow['owner_email'] ?? ''),
        'owner_name': baseRow['owner_name'] ?? '',
        'created_at': baseRow['created_at'] ?? now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    for (final t in const [
      'devices',
      'users',
      'accounts',
      'transactions',
      'vouchers',
      'items',
      'item_categories',
      'sections',
      'stock_moves',
      'conversations',
      'messages',
      'notifications',
      'operations',
    ]) {
      try {
        await db.update(t, {'workspace_id': newId},
            where:
                "workspace_id = 'default' OR workspace_id IS NULL OR workspace_id = ''");
      } catch (_) {}
    }
    await repo?.setSetting(_workspaceIdSetting, newId);
    repo?.debugSetWorkspaceId(newId);
    return newId;
  }

  // 5. إنشاء مساحة المنشأة للمرة الأولى فقط عند أول تشغيل خام
  final now = DateTime.now().toIso8601String();
  final id =
      debugForceLegacyWorkspaceId ? defaultWorkspaceId : generateWorkspaceId();
  await db.insert(
    'workspaces',
    {
      'id': id,
      'name': 'متجري',
      'owner_google_id': '',
      'owner_email': accountEmail ?? '',
      'owner_name': '',
      'created_at': now,
      'updated_at': now,
    },
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
  await repo?.setSetting(_workspaceIdSetting, id);
  return id;
}

Future<String?> currentWorkspaceId(Repo repo) async {
  final st = await repo.settings();
  return st[_workspaceIdSetting];
}

Future<void> linkWorkspaceToGoogle(
  Database db, {
  required String workspaceId,
  required String googleId,
  required String email,
  required String name,
}) async {
  await db.update(
    'workspaces',
    {
      'owner_google_id': googleId,
      'owner_email': email,
      'owner_name': name,
      'updated_at': DateTime.now().toIso8601String(),
    },
    where: 'id = ?',
    whereArgs: [workspaceId],
  );
}
