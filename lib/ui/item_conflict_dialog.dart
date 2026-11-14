import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/item_conflict.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/repository.dart';
import 'widgets.dart';

/// شريط تنبيه واضح (Banner) يظهر عند وجود تعارض أصناف أو باركود غير محلول بعد المزامنة.
class ItemConflictBanner extends ConsumerWidget {
  const ItemConflictBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conflictsAsync = ref.watch(pendingItemConflictsProvider);
    return conflictsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (conflicts) {
        if (conflicts.isEmpty) return const SizedBox.shrink();
        final c = conflicts.first;
        final extraCount = conflicts.length - 1;
        return Container(
          key: const ValueKey('item_conflict_banner'),
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.amber.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: AppColors.amber.withValues(alpha: 0.55),
              width: 1.2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: AppColors.amber,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'تنبيه تعارض أصناف: ${c.conflictTypeLabel}'
                      '${extraCount > 0 ? ' (+$extraCount أخرى)' : ''}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13.5,
                        color: AppColors.amber,
                      ),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    key: const ValueKey('resolve_conflict_banner_btn'),
                    onPressed: () => showItemConflictResolutionDialog(
                      context,
                      ref,
                      conflictKey: c.key,
                    ),
                    icon: const Icon(Icons.build_circle_outlined, size: 17),
                    label: const Text(
                      'معالجة التعارض',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.amber.withValues(alpha: 0.22),
                      foregroundColor: AppColors.amber,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '• الصنف الأول: ${c.item1Name} — أُدخل بواسطة: ${c.item1Creator}\n'
                '• الصنف الثاني: ${c.item2Name} — أُدخل بواسطة: ${c.item2Creator}'
                '${c.sharedSku.trim().isNotEmpty ? '\n• الباركود المشترك: ${c.sharedSku.trim()}' : ''}',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              if (extraCount > 0) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const ValueKey('show_all_conflicts_banner_btn'),
                    onPressed: () =>
                        showAllPendingItemConflictsSheet(context, ref),
                    icon: const Icon(Icons.list_alt_rounded, size: 16),
                    label: Text(
                      'عرض بقية التعارضات (+$extraCount)',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.amber,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// نافذة عرض جميع تعارضات الأصناف المعلّقة ليتمكن المدير من استعراضها وحل أي منها.
Future<void> showAllPendingItemConflictsSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Consumer(
      builder: (ctx, sheetRef, __) {
        final conflictsAsync = sheetRef.watch(pendingItemConflictsProvider);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          minChildSize: 0.35,
          maxChildSize: 0.9,
          builder: (__, scrollCtrl) {
            final list =
                conflictsAsync.valueOrNull ?? const <OfflineItemConflict>[];
            if (list.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('لا توجد تعارضات معلّقة حالياً.'),
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: AppColors.amber,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'جميع تعارضات الأصناف المعلّقة (${list.length})',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.all(12),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, idx) {
                      final item = list[idx];
                      return Card(
                        key: ValueKey('pending_conflict_tile_${item.key}'),
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          title: Text(
                            '${item.item1Name} (#${item.item1Id}) ⇄ ${item.item2Name} (#${item.item2Id})',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                            ),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '• ${item.conflictTypeLabel}'
                              '${item.sharedSku.trim().isNotEmpty ? ' — الباركود: ${item.sharedSku.trim()}' : ''}\n'
                              '• ${item.item1Creator} / ${item.item2Creator}',
                              style: const TextStyle(fontSize: 12, height: 1.35),
                            ),
                          ),
                          trailing: FilledButton.tonal(
                            key: ValueKey('open_conflict_btn_${item.key}'),
                            onPressed: () async {
                              await showItemConflictResolutionDialog(
                                ctx,
                                sheetRef,
                                conflictKey: item.key,
                              );
                            },
                            child: const Text('معالجة'),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    ),
  );
  ref.invalidate(pendingItemConflictsProvider);
  ref.invalidate(itemsProvider);
  ref.invalidate(notificationsProvider);
  ref.invalidate(unreadCountProvider);
  bump(ref);
}

/// نافذة المعالجة الفورية لتعارض الأصناف والباركود من الإشعار أو الـ Banner.
Future<bool> showItemConflictResolutionDialog(
  BuildContext context,
  WidgetRef ref, {
  required String conflictKey,
}) async {
  final repo = ref.read(repoProvider);
  OfflineItemConflict? conflict = await repo.itemConflictByKey(conflictKey);
  if (conflict == null) {
    final all = await repo.allItemConflicts();
    if (all.isNotEmpty) {
      conflict = all.firstWhere(
        (c) => c.key == conflictKey,
        orElse: () => all.first,
      );
    }
  }
  if (!context.mounted) return false;
  if (conflict == null) {
    showSnack(context, 'لم يتم العثور على بيانات التعارض', error: true);
    return false;
  }

  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) => _ItemConflictResolutionDialog(
      conflict: conflict!,
      repo: repo,
      parentRef: ref,
    ),
  );
  if (res == true) {
    bump(ref);
  }
  return res == true;
}

class _ItemConflictResolutionDialog extends StatefulWidget {
  final OfflineItemConflict conflict;
  final Repo repo;
  final WidgetRef parentRef;

  const _ItemConflictResolutionDialog({
    required this.conflict,
    required this.repo,
    required this.parentRef,
  });

  @override
  State<_ItemConflictResolutionDialog> createState() =>
      _ItemConflictResolutionDialogState();
}

class _ItemConflictResolutionDialogState
    extends State<_ItemConflictResolutionDialog> {
  late int _selectedItemForBarcode;
  late bool _keepItem1OnMerge;
  final TextEditingController _barcodeCtrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _selectedItemForBarcode = widget.conflict.item2Id;
    _keepItem1OnMerge = true;
  }

  @override
  void dispose() {
    _barcodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _generatePreviewBarcode() async {
    final code = await widget.repo.generateUniqueItemBarcode();
    if (!mounted) return;
    setState(() {
      _barcodeCtrl.text = code;
    });
  }

  Future<void> _handleChangeBarcode() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final newSku = await widget.repo.resolveItemConflictChangeBarcode(
        conflictKey: widget.conflict.key,
        targetItemId: _selectedItemForBarcode,
        newBarcode: _barcodeCtrl.text.trim(),
      );
      bump(widget.parentRef);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      showSnack(
        context,
        'تم تحديث الباركود إلى ($newSku) وإنهاء التعارض بنجاح',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, '$e', error: true);
    }
  }

  Future<void> _handleMergeItems() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.repo.resolveItemConflictMergeItems(
        conflictKey: widget.conflict.key,
        keepItemId:
            _keepItem1OnMerge ? widget.conflict.item1Id : widget.conflict.item2Id,
      );
      bump(widget.parentRef);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      showSnack(
        context,
        'تم دمج الصنفين وجمع الكميات وتوحيد الحركات والفواتير بنجاح',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, '$e', error: true);
    }
  }

  Future<void> _handleKeepSeparate() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.repo.resolveItemConflictKeepSeparate(
        conflictKey: widget.conflict.key,
      );
      bump(widget.parentRef);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      showSnack(
        context,
        'تم اعتماد فصل الصنفين؛ سيظهر خيار تحديد الصنف للكاشير عند مسح الباركود المشترك',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.conflict;
    final cs = Theme.of(context).colorScheme;

    return AlertDialog(
      key: const ValueKey('item_conflict_resolution_dialog'),
      titlePadding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
      contentPadding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
      title: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: AppColors.amber),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'معالجة تعارض الأصناف والباركود',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.amber.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.amber.withValues(alpha: 0.4),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'نوع التعارض: ${c.conflictTypeLabel}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: AppColors.amber,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _itemInfoRow(
                      label: 'الصنف الأول (#${c.item1Id})',
                      name: c.item1Name,
                      creator: c.item1Creator,
                    ),
                    const Divider(height: 14),
                    _itemInfoRow(
                      label: 'الصنف الثاني (#${c.item2Id})',
                      name: c.item2Name,
                      creator: c.item2Creator,
                    ),
                    if (c.originalCollidingId != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'ملاحظة: كان الصنفان يحملان الرقم (#${c.originalCollidingId}) وتم فصل الصنف الأصغر تلقائياً إلى (#${c.item2Id}) مع تحديث فواتيره وحركاته.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (c.sharedSku.trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'الباركود المشترك: ${c.sharedSku.trim()}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              // الخيار 1: توليد/تعديل الباركود
              _optionCard(
                context,
                title: '1. توليد / تعديل الباركود',
                subtitle:
                    'تغيير باركود أحد الصنفين أو توليد باركود جديد تلقائياً لإنهاء الاشتراك في الباركود.',
                icon: Icons.qr_code_2_rounded,
                accent: AppColors.primary,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<int>(
                      initialValue: _selectedItemForBarcode,
                      decoration: const InputDecoration(
                        labelText: 'الصنف المراد تغيير باركوده',
                        isDense: true,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: c.item1Id,
                          child: Text(
                            '${c.item1Name} (#${c.item1Id})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem(
                          value: c.item2Id,
                          child: Text(
                            '${c.item2Name} (#${c.item2Id})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) {
                              if (v != null) {
                                setState(() => _selectedItemForBarcode = v);
                              }
                            },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('conflict_new_barcode_field'),
                            controller: _barcodeCtrl,
                            enabled: !_busy,
                            decoration: const InputDecoration(
                              labelText:
                                  'الباركود الجديد (اتركه فارغاً للتوليد التلقائي)',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          tooltip: 'توليد باركود تلقائي',
                          onPressed: _busy ? null : _generatePreviewBarcode,
                          icon: const Icon(Icons.autorenew_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      key: const ValueKey('conflict_action_change_barcode'),
                      onPressed: _busy ? null : _handleChangeBarcode,
                      icon: const Icon(Icons.qr_code_rounded, size: 18),
                      label: const Text('توليد/تعديل الباركود'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // الخيار 2: دمج الصنفين في صنف واحد
              _optionCard(
                context,
                title: '2. دمج الصنفين في صنف واحد',
                subtitle:
                    'اعتبارهما صنفاً واحداً، وجمع كميتيهما وتوحيد حركات المخزون والفواتير تحت بطاقة واحدة.',
                icon: Icons.merge_type_rounded,
                accent: AppColors.green,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<bool>(
                      initialValue: _keepItem1OnMerge,
                      decoration: const InputDecoration(
                        labelText: 'بطاقة الصنف المعتمدة بعد الدمج',
                        isDense: true,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: true,
                          child: Text(
                            'الاحتفاظ بـ: ${c.item1Name} (#${c.item1Id})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem(
                          value: false,
                          child: Text(
                            'الاحتفاظ بـ: ${c.item2Name} (#${c.item2Id})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) {
                              if (v != null) {
                                setState(() => _keepItem1OnMerge = v);
                              }
                            },
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      key: const ValueKey('conflict_action_merge_items'),
                      onPressed: _busy ? null : _handleMergeItems,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.green,
                      ),
                      icon: const Icon(Icons.merge_rounded, size: 18),
                      label: const Text('دمج الصنفين في صنف واحد'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // الخيار 3: اعتماد الفصل
              _optionCard(
                context,
                title: '3. اعتماد الفصل',
                subtitle:
                    'الإبقاء على الصنفين منفصلين، وإذا بقي الباركود مشتركاً بينهما ستظهر للكاشير في نقطة البيع نافذة مصغرة فورية لاختيار الصنف المقصود عند المسح.',
                icon: Icons.call_split_rounded,
                accent: AppColors.amber,
                child: OutlinedButton.icon(
                  key: const ValueKey('conflict_action_keep_separate'),
                  onPressed: _busy ? null : _handleKeepSeparate,
                  icon: const Icon(Icons.call_split_rounded, size: 18),
                  label: const Text('اعتماد الفصل'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('إغلاق مؤقتاً'),
        ),
      ],
    );
  }

  Widget _itemInfoRow({
    required String label,
    required String name,
    required String creator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(
          'الاسم: $name',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
        ),
        Text(
          'الجهاز / المستخدم المُدخِل: $creator',
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  Widget _optionCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accent,
    required Widget child,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13.5,
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
