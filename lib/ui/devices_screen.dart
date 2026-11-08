import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_names.dart';
import '../core/format.dart';
import '../core/sfx.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'widgets.dart';

class DeviceCard extends StatelessWidget {
  final Map<String, Object?> data;
  final List<AppUser> users;
  final Future<void> Function(int? userId) onAssign;
  final VoidCallback onRename;
  final VoidCallback onRevoke;
  final VoidCallback onRestore;
  final VoidCallback onExpel;
  final VoidCallback? onPermissions;
  final VoidCallback? onCloudLink;

  /// (دفعة 56) «حذف نهائي من السجل» — متاح للمالك أو الوكيل المخوّل.
  final VoidCallback? onPurge;

  /// (دفعة 51) تعديل الدور مباشرة من البطاقة دون فتح نافذة الصلاحيات.
  final Future<void> Function(UserRole role)? onRoleChanged;
  final bool isSelf;
  final bool isOwnerDevice;

  /// هل يملك المستخدم الحالي صلاحية إدارة أعضاء وأجهزة المجموعة (المالك أو الوكيل المخوّل)؟
  final bool canManageMembers;
  const DeviceCard({
    super.key,
    required this.data,
    required this.users,
    required this.onAssign,
    required this.onRename,
    required this.onRevoke,
    required this.onRestore,
    required this.onExpel,
    this.onPermissions,
    this.onCloudLink,
    this.onPurge,
    this.onRoleChanged,
    required this.isSelf,
    required this.isOwnerDevice,
    required this.canManageMembers,
  });

  @override
  Widget build(BuildContext context) {
    final isOwnerRow = ((data['is_owner'] as int?) ?? 0) == 1 || isOwnerDevice;
    final name = resolveMemberUnifiedName(
      deviceName: data['name'] as String?,
      userName: data['user_name'] as String?,
      isOwner: isOwnerRow,
    );
    final platform = (data['platform'] ?? '') as String;
    final expelled = ((data['expelled_at'] ?? '') as String).isNotEmpty;
    final revoked =
        ((data['revoked_at'] ?? '') as String).isNotEmpty && !expelled;
    final inactive = expelled || revoked;
    final lastSeen = (data['last_seen_at'] ?? '') as String;
    final userRole = data['user_role'] as String?;

    // تحديد الأجهزة الخاملة لأكثر من شهر (للتنبيه البصري).
    final lastSeenDt = DateTime.tryParse(lastSeen);
    final staleForMonth = lastSeenDt != null &&
        DateTime.now().difference(lastSeenDt) > const Duration(days: 30);
    // (دفعة 56) مؤشر الاتصال السحابي: ظهور خلال آخر 5 دقائق = متصل.
    final cloudOnline = lastSeenDt != null &&
        DateTime.now().difference(lastSeenDt) < const Duration(minutes: 5);
    // دور الجهاز الفعلي (شارة ملونة عالية التباين).
    final role = isOwnerDevice
        ? UserRole.admin
        : (userRole == null || userRole.isEmpty
            ? null
            : UserRole.fromCode(userRole));

    final Widget statusBadge;
    if (expelled) {
      statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.red.shade900.withValues(alpha: .15),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          'مطرود',
          style: TextStyle(
            fontSize: 10,
            color: Colors.red,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    } else if (revoked) {
      statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          'محظور',
          style: TextStyle(
            fontSize: 10,
            color: Colors.deepOrange,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    } else if (staleForMonth) {
      statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          'خامل ⚠️',
          style: TextStyle(
            fontSize: 10,
            color: Colors.redAccent,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    } else {
      statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: (cloudOnline || isSelf ? Colors.green : Colors.blueGrey)
              .withValues(alpha: .12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          cloudOnline || isSelf ? 'متصل سحابياً ☁️' : 'غائب (غير متصل)',
          style: TextStyle(
            fontSize: 10,
            color: cloudOnline || isSelf ? Colors.green : Colors.blueGrey,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    final metadataItems = <Widget>[
      _smallLabel(
        'البصمة',
        (data['id'] as String? ?? '').length > 10
            ? (data['id'] as String).substring(0, 10)
            : (data['id'] as String? ?? '—'),
      ),
      if (lastSeen.isNotEmpty)
        _smallLabel(
          'آخر ظهور',
          DateTime.tryParse(lastSeen) == null
              ? lastSeen
              : Fmt.relative(DateTime.parse(lastSeen)),
        ),
      if ('${data['last_sync_at'] ?? ''}'.isNotEmpty)
        _smallLabel(
          'آخر مزامنة ☁️',
          DateTime.tryParse('${data['last_sync_at']}') == null
              ? '${data['last_sync_at']}'
              : Fmt.relative(DateTime.parse('${data['last_sync_at']}')),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(_iconFor(platform), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      softWrap: true,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  if (!inactive && (canManageMembers || isSelf))
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      padding: EdgeInsets.zero,
                      tooltip: 'تعديل اسم العضو',
                      icon: const Icon(Icons.edit_outlined, size: 17),
                      onPressed: onRename,
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (role != null) _RoleBadge(role: role),
                  statusBadge,
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (var i = 0; i < metadataItems.length; i++) ...[
                    if (i > 0)
                      const Text(
                        '•',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.black38,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    metadataItems[i],
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  // متاح للمالك أو الوكيل المخوّل (canManageMembers) لتعديل صلاحيات أعضاء المجموعة.
                  if (!isSelf && !isOwnerDevice && canManageMembers && onPermissions != null)
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          alignment: AlignmentDirectional.centerStart,
                        ),
                        onPressed: inactive ? null : onPermissions,
                        icon: const Icon(Icons.verified_user_outlined, size: 18),
                        label: Text(
                          role != null
                              ? 'تعيين الدور والصلاحيات (${role.label})'
                              : 'تعيين الدور والصلاحيات',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  const SizedBox(width: 6),
                  // كل إجراءات الجهاز مجمّعة في قائمة ثلاث نقاط واحدة
                  // بدل صف الأيقونات الصغيرة المبعثرة.
                  _buildActionsMenu(
                    context,
                    expelled: expelled,
                    revoked: revoked,
                    inactive: inactive,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// قائمة ثلاث نقاط تجمع كل إجراءات الجهاز في مكان واحد مرتب:
  /// صلاحيات/تسمية/حظر-سماح/إعادة رمز/طرد/حذف نهائي + ربط العضو عبر السحابة.
  /// الخيارات الإدارية الحساسة متاحة للمالك أو الوكيل المخوّل (`canManageMembers`).
  Widget _buildActionsMenu(
    BuildContext context, {
    required bool expelled,
    required bool revoked,
    required bool inactive,
  }) {
    final items = <PopupMenuEntry<String>>[];

    void add(String value, IconData icon, Color color, String label,
        {bool enabled = true}) {
      items.add(PopupMenuItem<String>(
        value: value,
        enabled: enabled,
        child: Row(
          children: [
            Icon(icon, size: 18, color: enabled ? color : Colors.grey),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ));
    }

    // إدارة الصلاحيات متاحة للمالك أو الوكيل المخوّل (canManageMembers).
    if (!expelled && !isSelf && canManageMembers && onPermissions != null) {
      add('perms', Icons.verified_user_outlined, Colors.teal,
          'إدارة صلاحيات الجهاز',
          enabled: !inactive);
    }
    if (canManageMembers || isSelf) {
      add('rename', Icons.edit_outlined, Colors.blueGrey, 'تعديل اسم العضو',
          enabled: !inactive);
    }
    if (!expelled) {
      if (revoked) {
        add('restore', Icons.verified_user_outlined, Colors.green,
            'إعادة السماح (إلغاء الحظر)',
            enabled: !isSelf);
      } else {
        add('revoke', Icons.block, Colors.orange, 'حظر الجهاز',
            enabled: !isSelf);
      }
    }
    // (دفعة 58 — متطلب 19) «ربط العضو عبر السحابة» يظهر للمالك أو الوكيل المخوّل
    // عندما يكون الجهاز موقوفاً/غير مرتبط — جهاز نشط مرتبط فعلاً لا يحتاج إعادة ربط.
    if (!expelled && !isSelf && canManageMembers && onCloudLink != null && revoked) {
      add('cloudlink', Icons.cloud_sync_outlined, const Color(0xFF0EA5E9),
          'ربط العضو عبر السحابة');
    }
    if (!expelled && !isSelf && !isOwnerDevice) {
      add('expel', Icons.person_remove, Colors.red, 'طرد من المجموعة');
    }
    // (للمالك أو الوكيل المخوّل) «حذف نهائي من السجل» متاح لكل جهاز عدا
    // جهازك أنت (لا تنتحر) وجهاز مالك المساحة (الهوية الثابتة) — بلا شرط
    // «مطرود»: الأجهزة الوهمية (DEV-*) والقديمة قابلة للمسح النهائي.
    if (!isSelf && !isOwnerDevice && canManageMembers && onPurge != null) {
      if (items.isNotEmpty) items.add(const PopupMenuDivider());
      add('purge', Icons.delete_forever, Colors.red.shade700,
          'حذف نهائي من السجل');
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return PopupMenuButton<String>(
      tooltip: 'إجراءات الجهاز',
      icon: const Icon(Icons.more_vert, size: 22),
      itemBuilder: (_) => items,
      onSelected: (v) {
        switch (v) {
          case 'perms':
            onPermissions?.call();
          case 'rename':
            onRename();
          case 'restore':
            onRestore();
          case 'revoke':
            onRevoke();
          case 'cloudlink':
            onCloudLink?.call();
          case 'expel':
            onExpel();
          case 'purge':
            onPurge?.call();
        }
      },
    );
  }

  IconData _iconFor(String p) => switch (p) {
        'android' => Icons.phone_android,
        'ios' => Icons.phone_iphone,
        'windows' => Icons.laptop_windows,
        'linux' || 'macos' => Icons.computer,
        _ => Icons.devices,
      };

  Widget _smallLabel(String k, String v) => RichText(
        text: TextSpan(
          style:
              const TextStyle(fontSize: 11, color: Colors.black54, height: 1.4),
          children: [
            TextSpan(
              text: '$k: ',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            TextSpan(text: v),
          ],
        ),
      );
}

/// (دفعة 56) شارة الدور الديناميكية عالية التباين:
/// مدير ذهبية، وكيل بنفسجية داكنة، كاشير زمردية، محاسب زرقاء،
/// مدخل بيانات بنفسجية، عرض فقط رمادية.
class _RoleBadge extends StatelessWidget {
  final UserRole role;
  const _RoleBadge({required this.role});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (role) {
      UserRole.admin => (const Color(0xFFF59E0B), Colors.white), // ذهبي
      UserRole.agent => (const Color(0xFF7C3AED), Colors.white), // وكيل
      UserRole.accountant => (const Color(0xFF10B981), Colors.white), // محاسب
      UserRole.cashier => (const Color(0xFFF97316), Colors.white), // كاشير
      UserRole.dataentry => (const Color(0xFFA855F7), Colors.white), // إدخال
      UserRole.viewer => (const Color(0xFF6B7280), Colors.white), // عرض
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: bg.withValues(alpha: .35),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(
        '${role.icon} ${role.label}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10,
          color: fg,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// نافذة موحدة لتعيين دور وصلاحيات الجهاز المرتبط بشكل مستقل ومباشر لكل عضو.
Future<void> showDevicePermissionsDialog(
  BuildContext context,
  WidgetRef ref,
  Map<String, Object?> device,
) async {
  final users = ref.read(usersProvider).valueOrNull ?? const <AppUser>[];
  final uid = device['user_id'] as int?;
  AppUser? current;
  if (uid != null) {
    try {
      current = users.firstWhere((u) => u.id == uid);
    } catch (_) {
      current = null;
    }
  }
  final rawRoleCode = (device['user_role'] as String?) ?? '';
  var role = current?.role ??
      (rawRoleCode.isNotEmpty && rawRoleCode != UserRole.admin.code
          ? UserRole.fromCode(rawRoleCode)
          : UserRole.cashier);
  if (role == UserRole.admin) {
    role = UserRole.agent;
  }
  var perms = <String>{
    if (current != null)
      ...kPerms
          .where((p) => (current!.permissions[p.key] ?? false))
          .map((p) => p.key)
    else
      ...defaultPerms(role).entries.where((e) => e.value).map((e) => e.key),
  };
  final repo = ref.read(repoProvider);
  final engine = ref.read(syncEngineProvider);

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlg) {
        void setRole(UserRole r) {
          setDlg(() {
            role = r;
            perms = defaultPerms(r)
                .entries
                .where((e) => e.value)
                .map((e) => e.key)
                .toSet();
          });
        }

        final isAgent = role == UserRole.agent;
        return AlertDialog(
          title: Text('تعيين صلاحيات: ${device['name'] ?? 'الجهاز'}'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('الدور الوظيفي',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final r in UserRole.values)
                        if (r != UserRole.admin)
                          ChoiceChip(
                            label: Text('${r.icon} ${r.label}'),
                            selected: role == r,
                            onSelected: (_) => setRole(r),
                          ),
                    ],
                  ),
                  if (isAgent)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '🛡️ الوكيل يقوم بعمل المدير أثناء غيابه — يملك كل '
                        'الصلاحيات، ويمكنك تعديلها بدقة أدناه.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: AppColors.infoOf(ctx),
                        ),
                      ),
                    ),
                  const SizedBox(height: 14),
                  const Text('الصلاحيات التفصيلية',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  for (final p in kPerms)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: perms.contains(p.key),
                      title: Text(p.label),
                      onChanged: (v) => setDlg(() {
                        if (v == true) {
                          perms.add(p.key);
                        } else {
                          perms.remove(p.key);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await repo.setDevicePermissions(
                      device['id'] as String, role, perms);
                  await engine.broadcastRosterChange();
                  // (دفعة التدقيق) تحديث المزودات فوراً — كان الحوار يغلق
                  // دون bump فتبقى الأدوار/الصلاحيات المعروضة قديمة حتى
                  // إعادة الدخول للشاشة.
                  bump(ref);
                  if (ctx.mounted) Navigator.pop(ctx);
                  Sfx.success();
                } catch (e) {
                  Sfx.error();
                  if (ctx.mounted) {
                    showSnack(ctx, 'تعذّر حفظ الصلاحيات: $e', error: true);
                  }
                }
              },
              child: const Text('حفظ الصلاحيات'),
            ),
          ],
        );
      },
    ),
  );
}
