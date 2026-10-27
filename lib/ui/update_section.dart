// قسم التحديثات في الإعدادات + الفحص التلقائي عند بدء التشغيل.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_version.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/update_service.dart';
import 'widgets.dart';

/// خدمة التحديث (قابلة للاستبدال في الاختبارات).
final updateServiceProvider = Provider<UpdateService>((ref) => UpdateService());

/// فحص التحديث عند الطلب.
final updateCheckProvider = FutureProvider.autoDispose<UpdateInfo>((ref) async {
  ref.watch(refreshProvider);
  return ref.read(updateServiceProvider).check();
});

/// يفتح الرابط المباشر للحزمة من المستودع الرسمي خارج التطبيق (المتصفح / التنزيلات العادية).
Future<bool> openUpdateLink(UpdateInfo info) async {
  final candidates = <String>[
    if (info.downloadUrl != null && info.downloadUrl!.trim().isNotEmpty)
      info.downloadUrl!.trim(),
    if (info.fallbackDownloadUrl != null &&
        info.fallbackDownloadUrl!.trim().isNotEmpty)
      info.fallbackDownloadUrl!.trim(),
    if (info.releaseUrl != null && info.releaseUrl!.trim().isNotEmpty)
      info.releaseUrl!.trim(),
  ];
  for (final target in candidates) {
    final uri = Uri.tryParse(target);
    if (uri == null) continue;
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) return true;
    } catch (_) {}
  }
  return false;
}

/// يبدأ التحديث بفتح الرابط المباشر للحزمة من المستودع خارج التطبيق بشكل عادي
/// (عبر المتصفح أو مدير التنزيلات الخارجي للنظام دون حوار تحميل داخلي).
Future<void> startOneClickUpdate(
  BuildContext context,
  WidgetRef ref,
  UpdateInfo info,
) async {
  final ok = await openUpdateLink(info);
  if (!ok && context.mounted) {
    showSnack(context, 'تعذّر فتح رابط التحديث المباشر');
  }
}

/// قسم "التحديثات" داخل شاشة الإعدادات.
class UpdateSection extends ConsumerWidget {
  const UpdateSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(updateCheckProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionTitle('التحديثات'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.info_outline),
              title: const Text('الإصدار الحالي'),
              subtitle: Text(AppSemVer.current.toString()),
            ),
            const Divider(height: 1),
            async.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                ),
              ),
              error: (e, _) => _StatusRow(
                icon: Icons.wifi_off_outlined,
                color: AppColors.text3Of(context),
                title: 'تعذّر التحقق من التحديثات',
                subtitle: 'تحقّق من الاتصال ثم أعد المحاولة.',
              ),
              data: (info) => _UpdateBody(info: info),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => ref.invalidate(updateCheckProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('التحقق الآن'),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpdateBody extends ConsumerWidget {
  final UpdateInfo info;
  const _UpdateBody({required this.info});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (icon, color) = switch (info.status) {
      UpdateStatus.upToDate => (
          Icons.verified_outlined,
          AppColors.greenOf(context)
        ),
      UpdateStatus.available => (
          Icons.system_update_alt,
          AppColors.primaryOf(context)
        ),
      UpdateStatus.required_ => (
          Icons.priority_high_rounded,
          AppColors.dangerOf(context)
        ),
      UpdateStatus.unknown => (
          Icons.wifi_off_outlined,
          AppColors.text3Of(context)
        ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusRow(
          icon: icon,
          color: color,
          title: info.headline,
          subtitle: switch (info.status) {
            UpdateStatus.upToDate => 'لا توجد إصدارات أحدث.',
            UpdateStatus.available => 'الإصدار المتاح: ${info.latest}',
            UpdateStatus.required_ =>
              'الإصدار ${info.latest} إلزامي. الحد الأدنى المدعوم ${info.minSupported}.',
            UpdateStatus.unknown => info.error ?? 'سبب غير معروف.',
          },
        ),
        // (2026-09-24) أحدث إصدار فقط — ثلاثة أسطر كحد أقصى، بلا أي
        // دمج مع سجلات الإصدارات السابقة.
        if (info.notes.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surface2Of(context),
              borderRadius: BorderRadius.circular(10),
            ),
            child: _ReleaseNotesList(notes: info.notes),
          ),
        ],
        if (info.hasUpdate) ...[
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => startOneClickUpdate(context, ref, info),
            icon: const Icon(Icons.open_in_browser),
            label: const Text('تنزيل التحديث (رابط مباشر)'),
          ),
        ],
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  const _StatusRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: color),
        title: Text(title,
            style: TextStyle(fontWeight: FontWeight.w600, color: color)),
        subtitle: Text(subtitle),
      );
}

/// حوار التحديث الذي يظهر تلقائيًا. الإلزامي لا يمكن إغلاقه.
Future<void> showUpdateDialog(
  BuildContext context,
  WidgetRef ref,
  UpdateInfo info,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: !info.isMandatory,
    builder: (ctx) => PopScope(
      canPop: !info.isMandatory,
      child: AlertDialog(
        icon: Icon(
          info.isMandatory
              ? Icons.priority_high_rounded
              : Icons.system_update_alt,
          color: info.isMandatory
              ? AppColors.dangerOf(ctx)
              : AppColors.primaryOf(ctx),
        ),
        title: Text(info.headline),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('الإصدار الحالي: ${info.current}'),
            Text('الإصدار الجديد: ${info.latest}'),
            if (info.isMandatory) ...[
              const SizedBox(height: 8),
              const Text(
                'هذا التحديث إلزامي لمواصلة استخدام التطبيق بأمان.',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
            if (info.notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              // (2026-09-24) ملخّص أحدث إصدار: ثلاثة أسطر، النص الكامل
              // يظهر في قسم التحديثات داخل الإعدادات لمن أراد التفاصيل.
              _ReleaseNotesList(notes: info.notes),
            ],
          ],
        ),
        actions: [
          if (!info.isMandatory)
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('لاحقًا'),
            ),
          FilledButton.icon(
            onPressed: () async {
              if (!info.isMandatory) Navigator.pop(ctx);
              await startOneClickUpdate(context, ref, info);
            },
            icon: const Icon(Icons.open_in_browser),
            label: const Text('تنزيل التحديث (رابط مباشر)'),
          ),
        ],
      ),
    ),
  );
}

/// (دفعة 58 — متطلب 12) حوار «الجديد في هذا التحديث» الديناميكي:
/// يظهر مرة واحدة فقط بعد كل ترقية، ويعرض حصراً ملاحظات الإصدار
/// المثبَّت حالياً (من بيان version.json حين يطابق رقمه إصدارنا) —
/// لا نص قديم مخزّن في الكود، ويتجدد تلقائياً مع كل إصدار جديد.
Future<void> showWhatsNewDialog(
  BuildContext context,
  String version,
  String notes,
) {
  // (2026-09-24) أحدث إصدار فقط: ثلاثة أسطر، بلا سجل تاريخي متراكم.
  final items = releaseNoteLines(notes);
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.celebration_outlined, color: AppColors.primaryOf(ctx)),
      title: const Text('الجديد في هذا التحديث'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 380, maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'الإصدار $version',
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              for (final it in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.check_circle_outline,
                          size: 16, color: AppColors.greenOf(ctx)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          it,
                          style:
                              const TextStyle(fontSize: 12.5, height: 1.6),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('رائع!'),
        ),
      ],
    ),
  );
}

/// (2026-09-24) يعرض ملاحظات أحدث إصدار فقط: ثلاثة أسطر كحد أقصى،
/// كل سطر بنقطة خضراء — بلا أي دمج مع الإصدارات السابقة.
class _ReleaseNotesList extends StatelessWidget {
  const _ReleaseNotesList({required this.notes});

  final String notes;

  @override
  Widget build(BuildContext context) {
    final items = releaseNoteLines(notes);
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final it in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_circle_outline,
                    size: 15, color: AppColors.greenOf(context)),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    it,
                    style: const TextStyle(fontSize: 12.5, height: 1.6),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
