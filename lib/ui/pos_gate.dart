// بوابة الأقسام وشريط الفئات في نقطة البيع (2026-09-24).
//
// البنية الهرمية الجديدة:
//   المستوى 1 — **بوابة الأقسام**: شاشة المبيعات تفتح على الأقسام فقط.
//   المستوى 2 — **الأصناف والفئات**: شريط فئات علوي (6 كحد أقصى والباقي في
//                منسدلة أنيقة) + زرّا تنقل سريع بين الأقسام المجاورة.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/icon_catalog.dart';
import '../core/models.dart';
import '../core/theme.dart';
import 'hierarchy_filter.dart' show toneOf;

/// بلاطة قسم في البوابة — مربع منحني بلون باستيل خاص بالقسم.
class _SectionTile extends StatelessWidget {
  const _SectionTile({
    required this.label,
    required this.icon,
    required this.tone,
    required this.subtitle,
    this.count,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final AppTone tone;
  final String subtitle;
  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: tone.background,
      borderRadius: BorderRadius.circular(AppRadius.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceOf(context),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      icon,
                      // (PR-8) أيقونة القسم بلونه الحي الخاص — لا أسود موحد.
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white
                          : tone.foreground,
                      size: 20,
                    ),
                  ),
                  const Spacer(),
                  if (count != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceOf(context),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: tone.foreground,
                        ),
                      ),
                    ),
                ],
              ),
              const Spacer(),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textOf(context),
                ),
              ),
              const SizedBox(height: 1),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  color: AppColors.text3Of(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// بوابة الأقسام (المستوى 1) — تعرض الأقسام في لوحة منسدلة أو كشبكة، وبنقرة واحدة ندخل الأصناف.
class PosSectionsGate extends ConsumerWidget {
  const PosSectionsGate({
    super.key,
    required this.sections,
    required this.roots,
    required this.items,
    required this.onOpen,
    this.shrinkWrap = false,
    this.physics,
    this.padding,
    this.childAspectRatio = 1.15,
  });

  final List<Section> sections;
  final List<ItemCategory> roots;

  /// كل الأصناف (لحساب عدد الأصناف في كل قسم).
  final List<Item> items;

  /// يُستدعى باختيار القسم: `null` = كل الأقسام، `-1` = عام.
  final void Function(int? sectionId) onOpen;

  final bool shrinkWrap;
  final ScrollPhysics? physics;
  final EdgeInsetsGeometry? padding;
  final double childAspectRatio;

  int _countOf(int? sectionId) {
    final activeSecIds = sections.map((s) => s.id).toSet();
    return items.where((i) {
      if (sectionId == null) return true;
      final sid = i.sectionId ?? _sectionOfCategory(i.categoryId);
      if (sectionId == kGeneralSectionId) {
        return sid == null ||
            sid == kGeneralSectionId ||
            !activeSecIds.contains(sid) ||
            i.categoryId == null;
      }
      return sid == sectionId;
    }).length;
  }

  int? _sectionOfCategory(int? catId) {
    if (catId == null) return null;
    for (final c in roots) {
      if (c.id == catId) return c.sectionId;
      for (final child in c.children) {
        if (child.id == catId) return child.sectionId ?? c.sectionId;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allCount = _countOf(null);
    final generalCount = _countOf(kGeneralSectionId);

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final cross = w >= 760 ? 4 : (w >= 480 ? 3 : 2);
        return GridView.count(
          padding: padding ?? const EdgeInsets.fromLTRB(14, 8, 14, 96),
          crossAxisCount: cross,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          shrinkWrap: shrinkWrap,
          physics: physics,
          childAspectRatio: childAspectRatio,
          children: [
            _SectionTile(
              label: 'كل الأقسام',
              icon: IconCatalog.of('apps'),
              tone: AppTone.blue,
              subtitle: 'كل الأصناف في مكان واحد',
              count: allCount,
              onTap: () => onOpen(null),
            ),
            _SectionTile(
              label: 'عام',
              icon: IconCatalog.of('category'),
              tone: AppTone.sand,
              subtitle: 'القسم العام وأصناف بلا فئة/قسم',
              count: generalCount,
              onTap: () => onOpen(kGeneralSectionId),
            ),
            for (final s in sections)
              _SectionTile(
                label: s.name,
                icon: IconCatalog.of(s.effectiveIcon),
                tone: toneOf(s.colorHex.isNotEmpty ? s.colorHex : ''),
                subtitle:
                    '${roots.where((c) => c.sectionId == s.id).length} فئة',
                count: _countOf(s.id),
                onTap: () => onOpen(s.id),
              ),
          ],
        );
      },
    );
  }
}

/// شريط القسم النشط: اسم القسم + تنقّل سريع للقسم المجاور + زر طي/فتح اللوحة المنسدلة.
class PosSectionBar extends StatelessWidget {
  const PosSectionBar({
    super.key,
    required this.title,
    required this.onBackToGate,
    required this.onPrev,
    required this.onNext,
    this.isExpanded = false,
    this.onToggleExpand,
  });

  final String title;
  final VoidCallback onBackToGate;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final bool isExpanded;
  final VoidCallback? onToggleExpand;

  @override
  Widget build(BuildContext context) {
    final toggleAction = onToggleExpand ?? onBackToGate;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 1),
      child: Row(
        children: [
          // زر فتح/طي لوحة الأقسام المنسدلة (Collapsible Top Panel).
          _NavChip(
            icon: isExpanded
                ? Icons.expand_less_rounded
                : Icons.grid_view_rounded,
            tooltip: isExpanded ? 'طي الأقسام' : 'تصفح الأقسام',
            onTap: toggleAction,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: toggleAction,
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textOf(context),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    isExpanded
                        ? Icons.arrow_drop_up_rounded
                        : Icons.arrow_drop_down_rounded,
                    size: 18,
                    color: AppColors.text3Of(context),
                  ),
                ],
              ),
            ),
          ),
          // تنقّل سريع: القسم السابق / التالي بلا رجوع للبوابة.
          _NavChip(
            icon: Icons.keyboard_arrow_right_rounded,
            tooltip: 'القسم السابق',
            enabled: onPrev != null,
            onTap: onPrev ?? () {},
          ),
          const SizedBox(width: 6),
          _NavChip(
            icon: Icons.keyboard_arrow_left_rounded,
            tooltip: 'القسم التالي',
            enabled: onNext != null,
            onTap: onNext ?? () {},
          ),
        ],
      ),
    );
  }
}

class _NavChip extends StatelessWidget {
  const _NavChip({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = enabled
        ? AppColors.primaryOf(context)
        : AppColors.text3Of(context).withValues(alpha: .4);
    return SizedBox(
      width: 32,
      height: 32,
      child: Material(
        color: c.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          iconSize: 18,
          onPressed: enabled ? onTap : null,
          icon: Icon(icon, color: c),
        ),
      ),
    );
  }
}

/// شريط الأقسام الأفقي الحديث (المستوى 1 في شاشة المبيعات) — بطاقات باستيل أفقية مع شارة عدد الفئات.
class PosSectionsStrip extends StatelessWidget {
  const PosSectionsStrip({
    super.key,
    required this.sections,
    required this.categories,
    required this.selectedId,
    required this.onSelect,
    this.onAllTap,
    this.onShowAll,
  });

  final List<Section> sections;
  final List<ItemCategory> categories;
  final int? selectedId;
  final void Function(int? sectionId) onSelect;
  final VoidCallback? onAllTap;
  final VoidCallback? onShowAll;

  int _categoryCountOf(int? sectionId) {
    if (sectionId == null) return categories.length;
    final activeSecIds = sections.map((s) => s.id).toSet();
    if (sectionId == kGeneralSectionId) {
      return categories
          .where((c) =>
              c.sectionId == null || !activeSecIds.contains(c.sectionId))
          .length;
    }
    return categories.where((c) => c.sectionId == sectionId).length;
  }

  @override
  Widget build(BuildContext context) {
    final generalCatCount = _categoryCountOf(kGeneralSectionId);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 12, 4),
          child: Row(
            children: [
              // (PR-8) رأس حيوي صافٍ — بلا أي كحلي قاتم.
              const Icon(
                Icons.folder_outlined,
                size: 18,
                color: Color(0xFF2563EB),
              ),
              const SizedBox(width: 6),
              Text(
                'الأقسام',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textOf(context),
                ),
              ),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onShowAll ?? () => onSelect(null),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'عرض الكل',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF2563EB),
                        ),
                      ),
                      SizedBox(width: 3),
                      Icon(
                        Icons.arrow_forward_rounded,
                        size: 13,
                        color: Color(0xFF2563EB),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 92,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsetsDirectional.fromSTEB(12, 2, 12, 2),
            children: [
              _HorizontalSectionTile(
                label: 'كل الأقسام',
                icon: IconCatalog.of('basket'),
                tone: AppTone.blue,
                catCount: categories.length,
                active: selectedId == null,
                onTap: onAllTap ?? () => onSelect(null),
              ),
              for (var i = 0; i < sections.length; i++)
                _HorizontalSectionTile(
                  label: sections[i].name,
                  icon: IconCatalog.of(sections[i].effectiveIcon),
                  tone: IconCatalog.resolveTone(
                    colorHex: sections[i].colorHex,
                    iconKey: sections[i].effectiveIcon,
                    fallbackSeed: i + 1,
                  ),
                  catCount: _categoryCountOf(sections[i].id),
                  active: selectedId == sections[i].id,
                  onTap: () => onSelect(sections[i].id),
                ),
              if (generalCatCount > 0 || sections.isEmpty)
                _HorizontalSectionTile(
                  label: 'عام',
                  icon: IconCatalog.of('category'),
                  tone: AppTone.sand,
                  catCount: generalCatCount,
                  active: selectedId == kGeneralSectionId,
                  onTap: () => onSelect(kGeneralSectionId),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HorizontalSectionTile extends StatelessWidget {
  const _HorizontalSectionTile({
    required this.label,
    required this.icon,
    required this.tone,
    required this.catCount,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final AppTone tone;
  final int catCount;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // (PR-8) الطابع الحيوي: خلفية باستيل نقية للقسم بلونه الخاص — النشط
    // يتعمق قليلاً بنفس اللون (لا غسلة زرقاء موحدة)، وأيقونة حية بلون
    // القسم بدل الأسود الداكن الموحد.
    final bg = active
        ? (dark
            ? tone.foreground.withValues(alpha: 0.22)
            : Color.lerp(tone.background, tone.foreground, 0.10)!)
        : (dark
            ? tone.foreground.withValues(alpha: 0.14)
            : tone.background);
    final borderColor = active
        ? tone.foreground
        : (dark
            ? AppColors.borderOf(context)
            : tone.foreground.withValues(alpha: 0.28));
    final glyphColor = dark ? Colors.white : tone.foreground;

    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: 90,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: borderColor,
                width: active ? 1.8 : 1.0,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: dark
                        ? Colors.white.withValues(alpha: 0.12)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 19, color: glyphColor),
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textOf(context),
                  ),
                ),
                const SizedBox(height: 2),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: tone.foreground.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$catCount فئات',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: tone.foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// شريط الفئات (المستوى 2): بطاقات فئات أفقية أنيقة مع أيقونة ملونة وشارة عدد الأصناف.
class PosCategoryStrip extends StatelessWidget {
  const PosCategoryStrip({
    super.key,
    required this.categories,
    required this.selectedId,
    required this.onPick,
    this.itemCountOf,
    this.allItemsCount,
    this.showHeader = false,
    this.onShowAll,
  });

  /// فئات القسم النشط مرتّبة كما تظهر للمستخدم.
  final List<ItemCategory> categories;

  final int? selectedId;

  /// يُستدعى باختيار فئة (`null` = كل الفئات).
  final void Function(int? categoryId) onPick;

  /// دالة اختيارية لحساب عدد الأصناف في كل فئة.
  final int Function(ItemCategory category)? itemCountOf;

  /// إجمالي الأصناف في خيار «الكل».
  final int? allItemsCount;

  /// هل يظهر سطر العنوان «الفئات ... عرض الكل ←» فوق البطاقات؟
  final bool showHeader;

  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    final strip = SizedBox(
      height: 86,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsetsDirectional.fromSTEB(12, 2, 12, 2),
        children: [
          _CatChip(
            label: 'الكل',
            icon: Icons.widgets_outlined,
            tone: AppTone.blue,
            countLabel: allItemsCount != null
                ? '$allItemsCount صنف'
                : '${categories.length} فئة',
            active: selectedId == null,
            onTap: () => onPick(null),
          ),
          for (var i = 0; i < categories.length; i++)
            _CatChip(
              label: categories[i].name,
              icon: IconCatalog.of(categories[i].iconKey),
              tone: IconCatalog.resolveTone(
                colorHex: categories[i].colorHex,
                iconKey: categories[i].iconKey,
                fallbackSeed: i + 1,
              ),
              countLabel: itemCountOf != null
                  ? '${itemCountOf!(categories[i])} أصناف'
                  : 'أصناف',
              active: categories[i].id == selectedId,
              onTap: () => onPick(categories[i].id),
            ),
        ],
      ),
    );

    if (!showHeader) return strip;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 3),
          child: Row(
            children: [
              // (PR-8) رأس حيوي صافٍ — بلا أي كحلي قاتم.
              const Icon(
                Icons.grid_view_rounded,
                size: 18,
                color: Color(0xFF2563EB),
              ),
              const SizedBox(width: 6),
              Text(
                'الفئات',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textOf(context),
                ),
              ),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onShowAll ?? () => _openSheet(context),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'عرض الكل',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF2563EB),
                        ),
                      ),
                      SizedBox(width: 3),
                      Icon(
                        Icons.arrow_forward_rounded,
                        size: 13,
                        color: Color(0xFF2563EB),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        strip,
      ],
    );
  }

  Future<void> _openSheet(BuildContext context) async {
    final pick = await showModalBottomSheet<int?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _CategoriesSheet(
        categories: categories,
        selectedId: selectedId,
      ),
    );
    onPick(pick);
  }
}

class _CategoriesSheet extends StatefulWidget {
  const _CategoriesSheet({
    required this.categories,
    required this.selectedId,
  });

  final List<ItemCategory> categories;
  final int? selectedId;

  @override
  State<_CategoriesSheet> createState() => _CategoriesSheetState();
}

class _CategoriesSheetState extends State<_CategoriesSheet> {
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.text.trim();
    final list = q.isEmpty
        ? widget.categories
        : widget.categories
            .where((c) => c.name.contains(q) || c.name.toLowerCase().contains(q))
            .toList();

    return DraggableScrollableSheet(
      initialChildSize: .55,
      minChildSize: .3,
      maxChildSize: .85,
      builder: (ctx, scroll) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceOf(context),
          borderRadius: AppRadius.sheetTop,
        ),
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.borderOf(context),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Row(
                children: [
                  Icon(Icons.category_outlined,
                      color: AppColors.primaryOf(context)),
                  const SizedBox(width: 8),
                  const Text(
                    'اختر الفئة',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
            if (widget.categories.length > 8)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _q,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'بحث…',
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.field),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.only(bottom: 12),
                itemCount: list.length + 1,
                itemBuilder: (ctx, i) {
                  if (i == 0) {
                    return _CatRow(
                      label: 'كل الفئات',
                      icon: Icons.widgets_outlined,
                      tone: AppTone.blue,
                      active: widget.selectedId == null,
                      onTap: () => Navigator.pop(context, null),
                    );
                  }
                  final c = list[i - 1];
                  return _CatRow(
                    label: c.name,
                    icon: IconCatalog.of(c.iconKey),
                    tone: IconCatalog.resolveTone(
                      colorHex: c.colorHex,
                      iconKey: c.iconKey,
                      fallbackSeed: i,
                    ),
                    active: c.id == widget.selectedId,
                    onTap: () => Navigator.pop(context, c.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CatRow extends StatelessWidget {
  const _CatRow({
    required this.label,
    required this.icon,
    required this.tone,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final AppTone tone;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: dark ? tone.foreground.withValues(alpha: 0.2) : tone.background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          icon,
          // (PR-8) أيقونات الفئات كحلية أنيقة موحدة.
          color: dark ? Colors.white : const Color(0xFF1E3A8A),
          size: 20,
        ),
      ),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      trailing: active
          ? Icon(Icons.check_circle_rounded, color: AppColors.primaryOf(context))
          : null,
    );
  }
}

class _CatChip extends StatelessWidget {
  const _CatChip({
    required this.label,
    required this.icon,
    required this.tone,
    required this.countLabel,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final AppTone tone;
  final String countLabel;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // (PR-8) بطاقات الفئات: أبيض ناصع نقي تماماً بلا أي تلوين خلفي،
    // بإطار ثلجي دقيق (E2E8F0) وأيقونات كحلية أنيقة موحدة — والنشط
    // يتميز بحد كحلي أوضح.
    const catNavy = Color(0xFF1E3A8A);
    const catNavyActive = Color(0xFF1E40AF);
    final bg = dark
        ? (active
            ? catNavyActive.withValues(alpha: 0.22)
            : tone.foreground.withValues(alpha: 0.14))
        : Colors.white;
    final borderColor = active
        ? (dark ? AppColors.primaryOf(context) : catNavyActive)
        : (dark
            ? AppColors.borderOf(context)
            : const Color(0xFFE2E8F0));
    final glyphColor = dark ? Colors.white : catNavy;

    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: 90,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: borderColor,
                width: active ? 1.8 : 1.0,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(4.5),
                  decoration: BoxDecoration(
                    color: dark
                        ? Colors.white.withValues(alpha: 0.12)
                        : const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 18, color: glyphColor),
                ),
                const SizedBox(height: 2.5),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textOf(context),
                  ),
                ),
                const SizedBox(height: 2),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: active
                        ? catNavyActive.withValues(alpha: 0.10)
                        : AppColors.surface2Of(context),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    countLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: active
                          ? (dark ? AppColors.primaryOf(context) : catNavyActive)
                          : AppColors.text2Of(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
