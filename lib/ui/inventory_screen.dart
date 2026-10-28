import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../core/format.dart';
import '../core/icon_catalog.dart';
import '../core/media_paths.dart';
import '../core/models.dart';
import '../core/pdf_fonts.dart';
import '../core/theme.dart';
import '../data/pos_cart.dart';
import '../data/providers.dart';
import '../data/sync/sync_activity.dart';
import 'barcode_scanner.dart';
import 'hierarchy_filter.dart';
import 'calculator.dart';
import 'widgets.dart';

/// مزود عام لتفعيل تبويب «قسم النواقص» مباشرة عند فتح شاشة المخزون.
final inventoryShortagesModeProvider = StateProvider<bool>((ref) => false);

/// هل الصنف ضمن النواقص (وصل أو نزل تحت حد التنبيه أو نفدت كميته)؟
bool isShortageItem(Item it) =>
    !it.isDeleted && !it.archived && (it.low || it.out);


/// شاشة بيانات الأصناف والفئات فقط.
///
/// تبدأ الفئات/الأقسام هنا أولًا. يمكن إنشاء عدد غير محدود من الفئات،
/// ثم إضافة الأصناف داخل كل فئة. لا تُسجّل هذه الشاشة شراءً أو بيعًا أو
/// مرتجعًا أو تسوية أو أي حركة مخزنية؛ فهي مخصّصة للبيانات الأساسية فقط.
// ══════════════════════════════════════════════════════════════════════════
// (2026-09-22) تطوير شاشة المخزون والأصناف
//   • شريط أدوات: بحث نصي لحظي + زر كاميرا لمسح الباركود.
//   • فلاتر شجرية: فئات رئيسية (Chips) ← فئات فرعية («الكل» + الأبناء).
//   • فرز متقدم بتسعة معايير، يُطبَّق محلياً فوراً بلا شبكة.
//   • نمطا عرض: قائمة تفصيلية / شبكة بطاقات، مع حفظ التفضيل محلياً.
// ══════════════════════════════════════════════════════════════════════════

/// مفتاح حفظ نمط العرض المفضل في جدول settings.
const String kInventoryViewModeKey = 'inventory.viewMode';

// (kGeneralSectionId مُعرَّف في core/models.dart — تجميعة «عام» للفئات
// بلا قسم، وتُستخدم في المخزون ونقطة البيع).

/// معايير الفرز المتاحة في شاشة الأصناف.
enum _SortKey {
  nameAsc('الاسم (أ - ي)', Icons.sort_by_alpha),
  nameDesc('الاسم (ي - أ)', Icons.sort_by_alpha),
  qtyAsc('الأقل كمية', Icons.trending_down),
  qtyDesc('الأكثر كمية', Icons.trending_up),
  outFirst('المنتهية أولاً', Icons.remove_shopping_cart_outlined),
  priceDesc('الأعلى سعراً', Icons.arrow_upward_rounded),
  priceAsc('الأقل سعراً', Icons.arrow_downward_rounded),
  newest('الأحدث إضافةً', Icons.fiber_new_outlined),
  oldest('الأقدم', Icons.history_toggle_off_outlined);

  const _SortKey(this.label, this.icon);

  final String label;
  final IconData icon;

  /// هل هذا الفرز يتعلق بالكمية/المخزون؟
  bool get isStock =>
      this == _SortKey.qtyAsc ||
      this == _SortKey.qtyDesc ||
      this == _SortKey.outFirst;
}

/// مقارنة صنفين حسب المفتاح — كلها محلية وبلا أي شبكة.
int _compareItems(Item a, Item b, _SortKey key) {
  int byName(String x, String y) =>
      x.trim().toLowerCase().compareTo(y.trim().toLowerCase());
  return switch (key) {
    _SortKey.nameAsc => byName(a.name, b.name),
    _SortKey.nameDesc => byName(b.name, a.name),
    _SortKey.qtyAsc => a.quantity.compareTo(b.quantity),
    _SortKey.qtyDesc => b.quantity.compareTo(a.quantity),
    // المنتهية أولاً: الكمية صفر في المقدمة، ثم الأقرب لحد الطلب.
    _SortKey.outFirst => () {
        final ao = a.quantity <= 0 ? 0 : 1;
        final bo = b.quantity <= 0 ? 0 : 1;
        final c = ao.compareTo(bo);
        return c != 0 ? c : a.quantity.compareTo(b.quantity);
      }(),
    _SortKey.priceDesc => b.sellPrice.compareTo(a.sellPrice),
    _SortKey.priceAsc => a.sellPrice.compareTo(b.sellPrice),
    _SortKey.newest => b.createdAt.compareTo(a.createdAt),
    _SortKey.oldest => a.createdAt.compareTo(b.createdAt),
  };
}

/// شاشة بيانات الأصناف والفئات فقط.
///
/// تبدأ الفئات/الأقسام هنا أولًا (فئة رئيسية وفئات فرعية)، ثم تُسجَّل
/// الأصناف داخلها. لا تُسجّل هذه الشاشة شراءً أو بيعًا أو مرتجعًا أو
/// تسوية أو أي حركة مخزنية؛ فهي مخصّصة للبيانات الأساسية فقط.
class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  String _mode = 'list';
  _SortKey _sort = _SortKey.nameAsc;
  int? _sectionId; // القسم المختار (null = الكل، -1 = «عام/بدون قسم»)
  int? _rootId; // الفئة الرئيسية المختارة (null = الكل)
  int? _subId; // الفئة الفرعية المختارة (null = كل ما تحت الرئيسية)
  StreamSubscription<int>? _syncBusSub;

  @override
  void initState() {
    super.initState();
    _loadPreferredMode();
    _syncBusSub = SyncActivityBus.instance.stream.listen((_) {
      if (!mounted) return;
      ref.invalidate(itemsProvider);
      ref.invalidate(itemCategoriesProvider);
      ref.invalidate(itemCategoryTreeProvider);
      ref.invalidate(sectionsProvider);
      ref.invalidate(inventorySummaryProvider);
      setState(() {});
    });
  }

  @override
  void dispose() {
    _syncBusSub?.cancel();
    super.dispose();
  }

  /// نمط العرض المفضل محفوظ في التفضيلات المحلية (settings).
  Future<void> _loadPreferredMode() async {
    try {
      final st = await ref.read(repoProvider).settings();
      final m = (st[kInventoryViewModeKey] ?? '').trim();
      if (!mounted || (m != 'grid' && m != 'list')) return;
      setState(() => _mode = m);
    } catch (_) {}
  }

  Future<void> _setMode(String mode) async {
    if (_mode == mode) return;
    setState(() => _mode = mode);
    try {
      await ref.read(repoProvider).setSetting(kInventoryViewModeKey, mode);
    } catch (_) {}
  }

  void _selectSection(int? id) => setState(() {
        _sectionId = id;
        _rootId = null;
        _subId = null;
      });

  void _selectRoot(int? id) => setState(() {
        _rootId = id;
        _subId = null;
      });

  void _selectSub(int? id) => setState(() => _subId = id);

  /// معرّفات الفئات المطلوب عرضها (null = كل الأصناف).
  Set<int>? _selectedIds(List<ItemCategory> roots) {
    if (_subId != null) return <int>{_subId!};
    // قسم محدد بلا فئة: كل أصناف فئاته (أو الفئات بلا قسم في «عام»).
    if (_rootId == null && _sectionId != null) {
      final ids = <int>{
        for (final c in _rootsOfSection(roots))
          if (c.id != null) c.id!,
      };
      for (final c in _rootsOfSection(roots)) {
        for (final sub in c.children) {
          if (sub.id != null) ids.add(sub.id!);
        }
      }
      return ids;
    }
    if (_rootId == null) return null;
    final ids = <int>{_rootId!};
    for (final r in roots) {
      if (r.id != _rootId) continue;
      for (final c in r.children) {
        if (c.id != null) ids.add(c.id!);
      }
    }
    return ids;
  }

  /// فئات القسم المختار: قسم محدد ⇒ فئاته؛ «عام» ⇒ الفئات بلا قسم؛
  /// «الكل» ⇒ كل الفئات الرئيسية.
  List<ItemCategory> _rootsOfSection(List<ItemCategory> roots) {
    if (_sectionId == null) return roots;
    if (_sectionId == kGeneralSectionId) {
      return roots.where((c) => c.sectionId == null).toList();
    }
    return roots.where((c) => c.sectionId == _sectionId).toList();
  }

  List<Item> _visibleItems(List<ItemCategory> roots, List<Item> items) {
    final ids = _selectedIds(roots);
    final q = ref.read(itemQueryProvider).trim().toLowerCase();
    final out = items.where((it) {
      // استثناء صريح للأصناف المحذوفة
      if (it.isDeleted) return false;
      if (ids != null) {
        if (_sectionId == kGeneralSectionId && _rootId == null) {
          final isUncategorized = it.categoryId == null || it.categoryId == 0;
          final isGeneralSection = it.sectionId == null || it.sectionId == 0;
          final inGeneralCat =
              it.categoryId != null && ids.contains(it.categoryId);
          if (!isUncategorized && !isGeneralSection && !inGeneralCat) {
            return false;
          }
        } else if (it.categoryId == null || !ids.contains(it.categoryId)) {
          return false;
        }
      }
      if (q.isEmpty) return true;
      return it.name.toLowerCase().contains(q) ||
          it.sku.toLowerCase().contains(q) ||
          it.category.toLowerCase().contains(q) ||
          it.notes.toLowerCase().contains(q);
    }).toList()
      ..sort((a, b) => _compareItems(a, b, _sort));
    return out;
  }

  /// شارة التصنيف: «اسم القسم • اسم الفئة» (القسم يُحذف إن لم يوجد، وبديل «بدون قسم» عند غيابه).
  String _badgeOf(
    Item item,
    List<ItemCategory> roots,
    List<Section> sections,
  ) {
    String catName = item.category.trim();
    int? sectionId;
    final cid = item.categoryId;
    if (cid != null) {
      for (final r in roots) {
        if (r.id == cid) {
          catName = r.name;
          sectionId = r.sectionId;
          break;
        }
        for (final c in r.children) {
          if (c.id == cid) {
            catName = c.name;
            sectionId = c.sectionId ?? r.sectionId;
            break;
          }
        }
      }
    }
    sectionId ??= item.sectionId;
    String? secName;
    for (final sec in sections) {
      if (sec.id == sectionId) {
        secName = sec.name;
        break;
      }
    }
    if (secName != null && secName.isNotEmpty) {
      return catName.isEmpty ? secName : '$secName • $catName';
    }
    if (catName.isNotEmpty) return catName;
    return 'بدون قسم';
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(itemCategoryTreeProvider);
    final itemsAsync = ref.watch(itemsProvider);
    final sectionsAsync = ref.watch(sectionsProvider);
    final openShortagesRequest = ref.watch(inventoryShortagesModeProvider);
    final sections = sectionsAsync.valueOrNull ?? const <Section>[];
    final allItems = itemsAsync.valueOrNull ?? const <Item>[];
    final shortagesCount = allItems.where(isShortageItem).length;

    if (openShortagesRequest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(inventoryShortagesModeProvider.notifier).state = false;
        openShortagesListSheet(context, ref);
      });
    }

    return Stack(
      children: [
        Column(
          children: [
            _InventoryToolbar(
              mode: _mode,
              sort: _sort,
              shortagesCount: shortagesCount,
              onModeChanged: _setMode,
              onSortChanged: (k) => setState(() => _sort = k),
              onAddCategory: () => openItemCategoryForm(context, ref),
              onOpenShortages: () => openShortagesListSheet(context, ref),
            ),
            categoriesAsync.when(
              skipLoadingOnReload: true,
              skipLoadingOnRefresh: true,
              loading: () => const SizedBox(height: 54),
              error: (_, __) => const SizedBox.shrink(),
              data: (roots) => _HierarchyFilterBar(
                sections: sections,
                roots: roots,
                sectionId: _sectionId,
                rootId: _rootId,
                subId: _subId,
                onSection: _selectSection,
                onRoot: _selectRoot,
                onSub: _selectSub,
                onAddCategory: (sectionId) => openItemCategoryForm(
                  context,
                  ref,
                  parentId: null,
                  sectionId: sectionId,
                ),
                onAddSection: () => openSectionForm(context, ref),
                onManage: () =>
                    openCategoryManager(context, ref, roots, sections),
              ),
            ),
            Expanded(
              child: categoriesAsync.when(
                skipLoadingOnReload: true,
                skipLoadingOnRefresh: true,
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => EmptyState(
                  icon: Icons.error_outline,
                  title: 'تعذّر تحميل الفئات',
                  message: '$e',
                ),
                data: (roots) => itemsAsync.when(
                  skipLoadingOnReload: true,
                  skipLoadingOnRefresh: true,
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => EmptyState(
                    icon: Icons.error_outline,
                    title: 'تعذّر تحميل المنتجات',
                    message: '$e',
                  ),
                  data: (items) => _buildBody(context, roots, items, sections),
                ),
              ),
            ),
          ],
        ),
        // زر الإضافة العائم الذكي: نقرة = صنف جديد، ضغطة مطوّلة = قائمة.
        PositionedDirectional(
          bottom: 16,
          end: 16,
          child: _SmartInventoryFab(
            onAddItem: () => openItemForm(context, ref,
                categoryId: _subId ?? _rootId, sectionId: _sectionId),
            onAddCategory: () => openItemCategoryForm(context, ref,
                sectionId: _sectionId == kGeneralSectionId ? null : _sectionId),
            onAddSection: () => openSectionForm(context, ref),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    List<ItemCategory> roots,
    List<Item> items,
    List<Section> sections,
  ) {
    if (roots.isEmpty && items.isEmpty) {
      return EmptyState(
        icon: Icons.create_new_folder_outlined,
        title: 'ابدأ بإضافة فئة',
        message: 'أنشئ أقسامًا غير محدودة، وبعدها أضف كل صنف داخل قسمه.',
        action: FilledButton.icon(
          onPressed: () => openItemCategoryForm(context, ref),
          icon: const Icon(Icons.add),
          label: const Text('إضافة أول فئة'),
        ),
      );
    }
    final visible = _visibleItems(roots, items);
    if (visible.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: 'لا توجد نتائج',
        message: 'جرّب كلمة بحث أخرى أو بدّل الفئة.',
        action: FilledButton.tonalIcon(
          onPressed: () {
            ref.read(itemQueryProvider.notifier).state = '';
            setState(() {
              _rootId = null;
              _subId = null;
              _sectionId = null;
            });
          },
          icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
          label: const Text('مسح الفلاتر'),
        ),
      );
    }
    const pad = EdgeInsets.fromLTRB(12, 4, 12, 96);
    // عدد الأعمدة حسب العرض: هاتف 2 · لوحي 3 · حاسوب 4.
    final w = MediaQuery.sizeOf(context).width;
    final cols = w >= 900 ? 4 : (w >= 600 ? 3 : 2);
    final child = _mode == 'grid'
        ? GridView.builder(
            padding: pad,
            itemCount: visible.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: cols >= 4 ? .95 : .82,
            ),
            itemBuilder: (_, i) => _ItemGridCard(
                  item: visible[i],
                  badge: _badgeOf(visible[i], roots, sections),
                ),
          )
        : ListView.builder(
            padding: pad,
            itemCount: visible.length,
            itemBuilder: (_, i) => _ItemTile(
                  item: visible[i],
                  badge: _badgeOf(visible[i], roots, sections),
                ),
          );
    return RefreshIndicator(
      onRefresh: () async => bump(ref),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
            child: Row(
              children: [
                Text(
                  '${visible.length} من ${items.length} صنف',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text2Of(context),
                  ),
                ),
                const Spacer(),
                Text(
                  '${sections.length} قسم · ${roots.length} فئة',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.text3Of(context),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// شريط الأدوات: بحث + باركود + أيقونة قائمة النواقص + فرز + تبديل نمط العرض.
class _InventoryToolbar extends ConsumerWidget {
  final String mode;
  final _SortKey sort;
  final int shortagesCount;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<_SortKey> onSortChanged;
  final VoidCallback onAddCategory;
  final VoidCallback onOpenShortages;

  const _InventoryToolbar({
    required this.mode,
    required this.sort,
    required this.shortagesCount,
    required this.onModeChanged,
    required this.onSortChanged,
    required this.onAddCategory,
    required this.onOpenShortages,
  });

  Future<void> _scan(BuildContext context, WidgetRef ref) async {
    try {
      final code = await scanBarcode(context);
      if (code == null || code.isEmpty || !context.mounted) return;
      ref.read(itemQueryProvider.notifier).state = code;
      showSnack(context, '🔎 تم مسح الرمز: $code');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(itemQueryProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ترويسة زرقاء أنيقة: بحث بيضاوي أبيض + أيقونة قائمة النواقص + ماسح باركود.
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: dark
                  ? const [Color(0xFF0B2A5B), Color(0xFF14407E)]
                  : [AppColors.primary2, AppColors.primary],
            ),
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(AppRadius.sheet),
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: .26),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 14),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: TextField(
                        controller: TextEditingController(text: q)
                          ..selection = TextSelection.collapsed(offset: q.length),
                        style: const TextStyle(
                            fontSize: 14.5, color: Color(0xFF12223A)),
                        textAlignVertical: TextAlignVertical.center,
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          hintText: 'ابحث بالاسم أو الباركود أو الفئة',
                          hintStyle: const TextStyle(
                              color: Color(0xFF9AA6B8), fontSize: 13.5),
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 14),
                          prefixIcon: const Icon(Icons.search_rounded,
                              size: 20, color: Color(0xFF9AA6B8)),
                          prefixIconConstraints: const BoxConstraints(
                              minWidth: 40, minHeight: 40),
                          border: _pill(Colors.transparent),
                          enabledBorder: _pill(Colors.transparent),
                          focusedBorder: _pill(Colors.transparent),
                          suffixIcon: q.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'مسح البحث',
                                  icon: const Icon(Icons.clear,
                                      size: 18, color: Color(0xFF9AA6B8)),
                                  onPressed: () => ref
                                      .read(itemQueryProvider.notifier)
                                      .state = '',
                                ),
                        ),
                        onChanged: (v) =>
                            ref.read(itemQueryProvider.notifier).state = v,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // أيقونة النواقص المنفصلة مع شارة العدد — تفتح قائمة النواقص المرتبة
                  SizedBox(
                    width: 46,
                    height: 46,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: Material(
                            color: shortagesCount > 0
                                ? const Color(0xFFF59E0B).withValues(alpha: 0.28)
                                : Colors.white.withValues(alpha: .18),
                            shape: const CircleBorder(),
                            clipBehavior: Clip.antiAlias,
                            child: IconButton(
                              tooltip: 'قائمة النواقص ($shortagesCount)',
                              onPressed: onOpenShortages,
                              icon: const Icon(
                                Icons.assignment_late_outlined,
                                color: Colors.white,
                                size: 21,
                              ),
                            ),
                          ),
                        ),
                        if (shortagesCount > 0)
                          PositionedDirectional(
                            top: -2,
                            start: -2,
                            child: IgnorePointer(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5.5,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEF4444),
                                  borderRadius: BorderRadius.circular(99),
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 1.5,
                                  ),
                                ),
                                child: Text(
                                  '$shortagesCount',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 46,
                    height: 46,
                    child: Material(
                      color: Colors.white.withValues(alpha: .18),
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: IconButton(
                        tooltip: 'مسح الباركود',
                        onPressed: () => _scan(context, ref),
                        icon: const Icon(Icons.qr_code_scanner_rounded,
                            color: Colors.white, size: 21),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // صفّ الفرز وأيقونة قائمة النواقص ونمط العرض يبقى على الخلفية الثلجية.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 380;
              return Row(
                children: [
                  Expanded(
                    child: _SortButton(
                        sort: sort, wide: wide, onChanged: onSortChanged),
                  ),
                  const SizedBox(width: 8),
                  _ViewModeToggle(
                      mode: mode, wide: wide, onChanged: onModeChanged),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

OutlineInputBorder _pill(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(999), borderSide: BorderSide(color: c));

/// زر الفرز المنسدل [⇅ فرز حسب...].
class _SortButton extends StatelessWidget {
  final _SortKey sort;
  final bool wide;
  final ValueChanged<_SortKey> onChanged;

  const _SortButton(
      {required this.sort, required this.wide, required this.onChanged});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: wide ? 210 : 150),
        child: PopupMenuButton<_SortKey>(
          tooltip: 'ترتيب النتائج',
          initialValue: sort,
          onSelected: onChanged,
          itemBuilder: (_) => [
            for (final k in _SortKey.values)
              PopupMenuItem<_SortKey>(
                value: k,
                child: Row(
                  children: [
                    Icon(k.icon, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(k.label)),
                    if (k == sort)
                      Icon(Icons.check,
                          size: 18, color: AppColors.primaryOf(context)),
                  ],
                ),
              ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.borderOf(context)),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('⇅', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    wide ? 'فرز: ${sort.label}' : sort.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                const Icon(Icons.arrow_drop_down, size: 20),
              ],
            ),
          ),
        ),
      );
}

/// مبدّل نمط العرض (قائمة / شبكة) — أيقونات فقط على الشاشات الضيقة.
class _ViewModeToggle extends StatelessWidget {
  final String mode;
  final bool wide;
  final ValueChanged<String> onChanged;

  const _ViewModeToggle(
      {required this.mode, required this.wide, required this.onChanged});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 36,
        child: SegmentedButton<String>(
          segments: [
            ButtonSegment<String>(
              value: 'list',
              icon: const Icon(Icons.view_list_rounded, size: 18),
              label: wide ? const Text('قائمة') : null,
            ),
            ButtonSegment<String>(
              value: 'grid',
              icon: const Icon(Icons.grid_view_rounded, size: 18),
              label: wide ? const Text('شبكة') : null,
            ),
          ],
          selected: <String>{mode},
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            textStyle: const TextStyle(fontSize: 12.5),
          ),
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      );
}

/// (2026-09-22) لوح إدارة الفئات: تعديل الاسم، إضافة فئة فرعية، والحذف
/// مع ترقية الأبناء — كان الوصول إليها من بطاقة الفئة القديمة فقط.
Future<void> openCategoryManager(
  BuildContext context,
  WidgetRef ref,
  List<ItemCategory> roots,
  List<Section> sections,
) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        // ارتفاع صريح (70٪ من الشاشة) بدل DraggableScrollableSheet داخل
        // صحيفة سفلية — الأخير ينهار إلى صفر حين يقيس نفسه بلا قيد.
        final h = MediaQuery.sizeOf(ctx).height * .70;
        return SizedBox(
          height: h,
          child: _CategoryManager(roots: roots, sections: sections),
        );
      },
    ).whenComplete(() => bump(ref));

/// (2026-09-22) شريط التنقل المزدوج (Dual-Pill):
///   الصف الأول: أقسام المتجر [الكل] [عام] [قسم…] + زر [+ قسم].
///   الصف الثاني: فئات القسم المختار + [كل الفئات].
///   الصف الثالث: الفئات الفرعية للفئة المختارة (إن وُجدت).
class _HierarchyFilterBar extends StatelessWidget {
  final List<Section> sections;
  final List<ItemCategory> roots;
  final int? sectionId;
  final int? rootId;
  final int? subId;
  final ValueChanged<int?> onSection;
  final ValueChanged<int?> onRoot;
  final ValueChanged<int?> onSub;
  final void Function(int? sectionId) onAddCategory;
  final VoidCallback onAddSection;
  final VoidCallback onManage;

  const _HierarchyFilterBar({
    required this.sections,
    required this.roots,
    required this.sectionId,
    required this.rootId,
    required this.subId,
    required this.onSection,
    required this.onRoot,
    required this.onSub,
    required this.onAddCategory,
    required this.onAddSection,
    required this.onManage,
  });

  List<ItemCategory> _rootsOfSection() {
    if (sectionId == null) return roots;
    final activeSectionIds = sections.map((s) => s.id).toSet();
    if (sectionId == kGeneralSectionId) {
      return roots
          .where((c) =>
              c.sectionId == null || !activeSectionIds.contains(c.sectionId))
          .toList();
    }
    return roots.where((c) => c.sectionId == sectionId).toList();
  }

  @override
  Widget build(BuildContext context) {
    final activeSectionIds = sections.map((s) => s.id).toSet();
    final visibleRoots = _rootsOfSection();
    final selectedRoot = visibleRoots.cast<ItemCategory?>().firstWhere(
          (c) => c?.id == rootId,
          orElse: () => null,
        );
    final subs = selectedRoot?.children ?? const <ItemCategory>[];

    final sec = sections.cast<Section?>().firstWhere(
          (x) => x?.id == sectionId,
          orElse: () => null,
        );
    final sub = subs.cast<ItemCategory?>().firstWhere(
          (c) => c?.id == subId,
          orElse: () => null,
        );

    final sectionOptions = <HierarchyOption>[
      HierarchyOption(
        id: null,
        label: 'كل الأقسام',
        icon: IconCatalog.of('apps'),
        tone: AppTone.blue,
        badge: '${roots.length} فئة',
      ),
      HierarchyOption(
        id: kGeneralSectionId,
        label: 'عام',
        icon: IconCatalog.of('category'),
        tone: AppTone.sand,
        badge:
            '${roots.where((c) => c.sectionId == null || !activeSectionIds.contains(c.sectionId)).length} فئة',
      ),
      for (final x in sections)
        HierarchyOption(
          id: x.id,
          label: x.name,
          icon: IconCatalog.of(x.effectiveIcon),
          tone: toneOf(x.colorHex.isNotEmpty ? x.colorHex : ''),
          badge: '${roots.where((c) => c.sectionId == x.id).length} فئة',
        ),
    ];
    final rootOptions = <HierarchyOption>[
      HierarchyOption(
        id: null,
        label: 'كل الفئات',
        icon: IconCatalog.of('widgets'),
        tone: AppTone.blue,
        badge: '${visibleRoots.length} فئة',
      ),
      for (final c in visibleRoots)
        HierarchyOption(
          id: c.id,
          label: c.name,
          icon: IconCatalog.of(c.iconKey),
          tone: toneOf(c.colorHex.isNotEmpty ? c.colorHex : ''),
          badge: c.hasChildren ? '${c.children.length} فرع' : 'فئة',
        ),
    ];
    final subOptions = <HierarchyOption>[
      const HierarchyOption(
        id: null,
        label: 'كل الفروع',
        icon: Icons.account_tree_outlined,
        tone: AppTone.blue,
      ),
      for (final c in subs)
        HierarchyOption(
          id: c.id,
          label: c.name,
          icon: IconCatalog.of(c.iconKey),
          tone: toneOf(c.colorHex.isNotEmpty ? c.colorHex : ''),
        ),
    ];

    Future<void> pickSection() async {
      final pick = await showHierarchySheet(
        context: context,
        title: 'اختر القسم',
        titleIcon: Icons.storefront_outlined,
        selectedId: sectionId,
        options: sectionOptions,
        actions: <HierarchyAction>[
          HierarchyAction(
            label: 'قسم جديد',
            icon: Icons.add_business_outlined,
            onTap: onAddSection,
          ),
          HierarchyAction(
            label: 'إدارة',
            icon: Icons.tune_rounded,
            onTap: onManage,
          ),
        ],
      );
      if (pick != null) onSection(pick.id);
    }

    Future<void> pickRoot() async {
      final pick = await showHierarchySheet(
        context: context,
        title: 'اختر الفئة',
        titleIcon: Icons.category_outlined,
        selectedId: rootId,
        options: rootOptions,
        actions: <HierarchyAction>[
          HierarchyAction(
            label: 'فئة جديدة',
            icon: Icons.add,
            onTap: () => onAddCategory(
              sectionId == kGeneralSectionId ? null : sectionId,
            ),
          ),
          HierarchyAction(
            label: 'إدارة',
            icon: Icons.tune_rounded,
            onTap: onManage,
          ),
        ],
      );
      if (pick != null) onRoot(pick.id);
    }

    Future<void> pickSub() async {
      final pick = await showHierarchySheet(
        context: context,
        title: 'اختر الفرع',
        titleIcon: Icons.account_tree_outlined,
        selectedId: subId,
        options: subOptions,
        actions: <HierarchyAction>[
          HierarchyAction(
            label: 'فرع جديد',
            icon: Icons.add,
            onTap: () => onAddCategory(
              sectionId == kGeneralSectionId ? null : sectionId,
            ),
          ),
        ],
      );
      if (pick != null) onSub(pick.id);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      // قياس العرض: الأزرار الجانبية تُخفى على الشاشات الضيقة (360px) بدل
      // أن تفيض — وتبقى متاحة دائماً داخل الورقة المنسدلة.
      child: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 400;
        return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
          Row(
            children: [
              Expanded(
                child: HierarchyDropdown(
                label: sec?.name ??
                    (sectionId == kGeneralSectionId ? 'عام' : 'كل الأقسام'),
                icon: sec == null
                    ? IconCatalog.of(
                        sectionId == kGeneralSectionId ? 'category' : 'apps')
                    : IconCatalog.of(sec.effectiveIcon),
                tone: sec == null
                    ? AppTone.blue
                    : toneOf(sec.colorHex.isNotEmpty ? sec.colorHex : ''),
                badge: '${visibleRoots.length} فئة',
                active: sectionId != null,
                onTap: pickSection,
              )),
              const SizedBox(width: 8),
              Expanded(
                child: HierarchyDropdown(
                label: selectedRoot?.name ?? 'كل الفئات',
                icon: selectedRoot == null
                    ? IconCatalog.of('widgets')
                    : IconCatalog.of(selectedRoot.iconKey),
                tone: selectedRoot == null
                    ? AppTone.blue
                    : toneOf(selectedRoot.colorHex.isNotEmpty
                        ? selectedRoot.colorHex
                        : ''),
                badge: selectedRoot == null
                    ? '${visibleRoots.length}'
                    : (selectedRoot.hasChildren
                        ? '${selectedRoot.children.length} فرع'
                        : 'فئة'),
                active: rootId != null,
                onTap: pickRoot,
              )),
              if (wide) ...[
              const SizedBox(width: 8),
              // إجراءات سريعة: قسم جديد · فئة جديدة · إدارة الهرمية.
              SizedBox(
                width: 46,
                height: 46,
                child: IconButton.outlined(
                  tooltip: 'قسم جديد',
                  style: IconButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                  ),
                  onPressed: onAddSection,
                  icon: const Icon(Icons.add_business_outlined, size: 20),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 46,
                height: 46,
                child: IconButton.outlined(
                  tooltip: 'إدارة الأقسام والفئات',
                  style: IconButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                  ),
                  onPressed: onManage,
                  icon: const Icon(Icons.tune_rounded, size: 20),
                ),
              ),
              ],
            ],
          ),
          // الفرع يظهر فقط للفئة المختارة التي تملك فروعاً — إفصاح تدريجي.
          if (subs.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: HierarchyDropdown(
                  label: sub?.name ?? 'كل الفروع',
                  icon: sub == null
                      ? Icons.account_tree_outlined
                      : IconCatalog.of(sub.iconKey),
                  tone: sub == null
                      ? AppTone.blue
                      : toneOf(sub.colorHex.isNotEmpty ? sub.colorHex : ''),
                  badge: '${subs.length}',
                  active: subId != null,
                  onTap: pickSub,
                  )),
              ],
            ),
          ],
        ],
      );
      }),
    );
  }
}

class _CategoryManager extends ConsumerWidget {
  final List<ItemCategory> roots;
  final List<Section> sections;

  const _CategoryManager({required this.roots, required this.sections});

  Future<void> _deleteCategory(
      BuildContext context, WidgetRef ref, ItemCategory c) async {
    final ok = await confirmDialog(
      context,
      title: 'حذف الفئة',
      message: c.hasChildren
          ? 'سيتم حذف «${c.name}» وترقية ${c.children.length} فئة فرعية '
              'إلى فئات رئيسية (لا تُحذف).'
          : 'سيتم حذف الفئة «${c.name}» وفك ربط أصنافها بها — '
              'الأصناف نفسها لن تُحذف.',
      confirmText: 'حذف الفئة',
      danger: true,
    );
    if (ok != true || c.id == null) return;
    await ref.read(repoProvider).deleteItemCategory(c.id!);
    bump(ref);
    if (context.mounted) {
      Navigator.pop(context);
      showSnack(context, 'حُذفت الفئة وبقيت الأصناف محفوظة');
    }
  }

  Future<void> _deleteSection(
      BuildContext context, WidgetRef ref, Section sec) async {
    final owned = roots.where((c) => c.sectionId == sec.id).length;
    final ok = await confirmDialog(
      context,
      title: 'حذف القسم',
      message: owned > 0
          ? 'سيتم حذف القسم «${sec.name}» وجميع الفئات التابعة له ($owned فئة) نهائياً.\n'
              'لن تُحذف المنتجات وسيتم فك ارتباطها.'
          : 'سيتم حذف القسم «${sec.name}».',
      confirmText: 'حذف القسم وفئاته',
      danger: true,
    );
    if (ok != true || sec.id == null) return;
    await ref.read(repoProvider).deleteSection(sec.id!);
    bump(ref);
    if (context.mounted) {
      Navigator.pop(context);
      showSnack(context, 'حُذف القسم وكافة فئاته التابعة');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (roots.isEmpty && sections.isEmpty) {
      return const EmptyState(
        icon: Icons.folder_off_outlined,
        title: 'لا توجد أقسام أو فئات بعد',
        message: 'أضف قسماً رئيسياً، ثم فئاته، ثم أصنافه.',
      );
    }
    final activeSectionIds = sections.map((s) => s.id).toSet();
    // تجميع الفئات حسب القسم (الفئات بلا قسم أو تابعة لقسم محذوف ⇒ مجموعة «عام»).
    final bySection = <int?, List<ItemCategory>>{};
    for (final c in roots) {
      final secId =
          (c.sectionId != null && activeSectionIds.contains(c.sectionId))
              ? c.sectionId
              : null;
      bySection.putIfAbsent(secId, () => <ItemCategory>[]).add(c);
    }
    // (2026-09-24) أيقونة القسم تُرافق اسمه في ترويسة المجموعة.
    final groups = <({int? id, String name, IconData icon})>[
      for (final sec in sections)
        (id: sec.id, name: sec.name, icon: IconCatalog.of(sec.effectiveIcon)),
      if (bySection.containsKey(null))
        (id: null, name: 'عام (بدون قسم)', icon: IconCatalog.of('category')),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 18),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            children: [
              const Icon(Icons.account_tree_outlined),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'الأقسام والفئات',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
              TextButton.icon(
                onPressed: () => openSectionForm(context, ref),
                icon: const Icon(Icons.add_business_outlined, size: 18),
                label: const Text('قسم'),
              ),
            ],
          ),
        ),
        for (final g in groups) ...[
          // بطاقة القسم: زر سريع لإضافة فئة لهذا القسم.
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            color: AppColors.primarySoftOf(context).withValues(alpha: .45),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Row(
                children: [
                  Icon(g.icon, size: 20, color: AppColors.primaryOf(context)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      g.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 14.5),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => openItemCategoryForm(context, ref,
                        sectionId: g.id),
                    icon: const Icon(Icons.add, size: 17),
                    label: const Text('فئة', style: TextStyle(fontSize: 12.5)),
                  ),
                  if (g.id != null) ...[
                    IconButton(
                      tooltip: 'تعديل القسم',
                      icon: const Icon(Icons.edit_outlined, size: 19),
                      onPressed: () {
                        final sec = sections.firstWhere(
                            (x) => x.id == g.id,
                            orElse: () => Section(
                                id: g.id,
                                name: g.name,
                                createdAt: DateTime.now(),
                                updatedAt: DateTime.now()));
                        openSectionForm(context, ref, section: sec);
                      },
                    ),
                    IconButton(
                      tooltip: 'حذف القسم',
                      icon: Icon(Icons.delete_outline,
                          size: 19, color: AppColors.dangerOf(context)),
                      onPressed: () {
                        final sec = sections.firstWhere(
                            (x) => x.id == g.id,
                            orElse: () => Section(
                                id: g.id,
                                name: g.name,
                                createdAt: DateTime.now(),
                                updatedAt: DateTime.now()));
                        _deleteSection(context, ref, sec);
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
          // فئات هذا القسم: لكل فئة «+ إضافة صنف مباشرة هنا».
          for (final c in bySection[g.id] ?? const <ItemCategory>[])
            _CategoryManagerTile(
              category: c,
              level: 0,
              sectionId: g.id,
              onAddItem: () => openItemForm(context, ref,
                  categoryId: c.id, sectionId: g.id),
              onEdit: () => openItemCategoryForm(context, ref, category: c),
              onAddSub: () =>
                  openItemCategoryForm(context, ref, parentId: c.id),
              onDelete: () => _deleteCategory(context, ref, c),
            ),
          if ((bySection[g.id] ?? const []).isEmpty)
            const Padding(
              padding: EdgeInsetsDirectional.only(start: 12, bottom: 8),
              child: Text('لا توجد فئات في هذا القسم',
                  style: TextStyle(fontSize: 12)),
            ),
        ],
      ],
    );
  }
}

class _CategoryManagerTile extends StatelessWidget {
  final ItemCategory category;
  final int level;
  final int? sectionId;
  final VoidCallback onAddItem;
  final VoidCallback onEdit;
  final VoidCallback onAddSub;
  final VoidCallback onDelete;

  const _CategoryManagerTile({
    required this.category,
    required this.level,
    required this.onAddItem,
    required this.onEdit,
    required this.onAddSub,
    required this.onDelete,
    this.sectionId,
  });

  @override
  Widget build(BuildContext context) {
    final indent = level * 22.0;
    return Padding(
      padding: EdgeInsetsDirectional.only(start: indent, bottom: 6),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          contentPadding: const EdgeInsetsDirectional.only(
              start: 10, end: 4, top: 2, bottom: 2),
          leading: Icon(
            level == 0 ? Icons.folder_outlined : Icons.subdirectory_arrow_left,
            color: AppColors.primaryOf(context),
          ),
          title: Text(
            category.name,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: category.hasChildren
              ? Text('${category.children.length} فئة فرعية')
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // إضافة صنف مباشرة داخل الفئة (بلا تنقل بين الشاشات).
              IconButton(
                tooltip: 'إضافة صنف هنا',
                icon: const Icon(Icons.add_box_outlined, size: 20),
                onPressed: onAddItem,
              ),
              IconButton(
                tooltip: 'إضافة فئة فرعية',
                icon: const Icon(Icons.add_circle_outline, size: 20),
                onPressed: onAddSub,
              ),
              IconButton(
                tooltip: 'تعديل الاسم',
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: onEdit,
              ),
              IconButton(
                tooltip: 'حذف الفئة',
                icon: Icon(Icons.delete_outline,
                    size: 20, color: AppColors.dangerOf(context)),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// زر الإضافة العائم الذكي: نقرة = صنف جديد، ضغطة مطوّلة = قائمة خيارات.
class _SmartInventoryFab extends StatelessWidget {
  final VoidCallback onAddItem;
  final VoidCallback onAddCategory;
  final VoidCallback onAddSection;

  const _SmartInventoryFab({
    required this.onAddItem,
    required this.onAddCategory,
    required this.onAddSection,
  });

  Future<void> _menu(BuildContext context) async {
    await HapticFeedback.mediumImpact();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: const Text('إضافة صنف جديد'),
              onTap: () {
                Navigator.pop(ctx);
                onAddItem();
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('إضافة فئة سريعة'),
              onTap: () {
                Navigator.pop(ctx);
                onAddCategory();
              },
            ),
            ListTile(
              leading: const Icon(Icons.add_business_outlined),
              title: const Text('إضافة قسم جديد'),
              onTap: () {
                Navigator.pop(ctx);
                onAddSection();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FloatingActionButton(
        heroTag: 'inventoryFab',
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        tooltip: 'إضافة صنف (اضغط مطولاً للخيارات)',
        onPressed: () async {
          await HapticFeedback.lightImpact();
          onAddItem();
        },
        child: GestureDetector(
          onLongPress: () => _menu(context),
          child: const Icon(Icons.add_rounded, size: 28),
        ),
      );
}

/// نموذج إضافة/تعديل قسم (ورقة سفلية سريعة).
Future<int?> openSectionForm(
  BuildContext context,
  WidgetRef ref, {
  Section? section,
}) =>
    showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _SectionForm(section: section),
      ),
    ).then((id) {
      if (id != null) bump(ref);
      return id;
    });

class _SectionForm extends ConsumerStatefulWidget {
  final Section? section;
  const _SectionForm({this.section});

  @override
  ConsumerState<_SectionForm> createState() => _SectionFormState();
}

class _SectionFormState extends ConsumerState<_SectionForm> {
  late final TextEditingController _name;
  String? _error;
  bool _saving = false;

  /// (2026-09-24) الهوية البصرية للقسم: مفتاح أيقونة + لون كرت.
  late String _iconKey;
  late String _color;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.section?.name ?? '');
    _iconKey = widget.section?.iconKey ?? '';
    _color = widget.section?.colorHex ?? '';
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'اسم القسم مطلوب');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final now = DateTime.now();
      final section = (widget.section ??
              Section(name: name, createdAt: now, updatedAt: now))
          .copyWith(name: name, iconKey: _iconKey, colorHex: _color);
      final id = await ref.read(repoProvider).saveSection(section);
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e'.replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => _BrandSheet(
        scrollable: true,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.add_business_outlined,
                      color: AppColors.primaryOf(context)),
                  const SizedBox(width: 8),
                  Text(
                    widget.section == null ? 'قسم جديد' : 'تعديل القسم',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              TextField(
                controller: _name,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'اسم القسم *',
                  hintText: 'مثل: إلكترونيات، ملابس، مواد غذائية',
                  prefixIcon: const Icon(Icons.storefront_outlined),
                  errorText: _error,
                ),
                onSubmitted: (_) => _saving ? null : _save(),
              ),
              const SizedBox(height: 12),
              // (2026-09-24) اختيار الأيقونة واللون مع معاينة فورية.
              _BrandPickers(
                iconKey: _iconKey,
                color: _color,
                onIcon: (k) => setState(() => _iconKey = k),
                onColor: (c) => setState(() => _color = c),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primaryOf(context),
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(
                      widget.section == null ? 'حفظ القسم' : 'حفظ التعديل'),
                ),
              ),
            ],
          ),
        ),
      );
}


/// بطاقة الصنف في نمط القائمة التفصيلي.
class _ItemTile extends ConsumerWidget {
  final Item item;
  final String badge;
  const _ItemTile({required this.item, this.badge = ''});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final warn = item.out
        ? AppColors.danger
        : (item.low ? AppColors.amber : AppColors.green);
    final warnText = item.out ? 'نفد' : (item.low ? 'قارب النفاد' : 'متوفر');

    return Card(
      margin: const EdgeInsets.only(bottom: 9),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => openItemForm(context, ref, item: item),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Row(
            children: [
              _Thumb(image: item.image),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Wrap(
                      spacing: 6,
                      runSpacing: 3,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (item.sku.isNotEmpty)
                          _Meta(
                            icon: Icons.qr_code_2_rounded,
                            text: item.sku,
                          ),
                        if (badge.isNotEmpty)
                          _Meta(
                            icon: Icons.sell_outlined,
                            text: badge,
                          ),
                        _Meta(icon: Icons.straighten, text: item.unit),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        _Price(
                          label: 'شراء',
                          value: Fmt.money(item.buyPrice, 0),
                          color: AppColors.info,
                        ),
                        const SizedBox(width: 14),
                        _Price(
                          label: 'بيع',
                          value: Fmt.money(item.sellPrice, 0),
                          color: AppColors.teal,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Pill(warnText, color: warn),
                  const SizedBox(height: 8),
                  Text(
                    Fmt.money(item.quantity, 0),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      color: warn,
                    ),
                  ),
                  if (item.minQuantity > 0)
                    Text(
                      'حد ${Fmt.money(item.minQuantity, 0)}',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: AppColors.text3Of(context),
                      ),
                    ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'تعديل الصنف',
                        onPressed: () => openItemForm(context, ref, item: item),
                        icon: Icon(Icons.edit_outlined,
                            size: 19, color: AppColors.primaryOf(context)),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'حذف الصنف',
                        onPressed: () async {
                          final ok = await confirmDialog(
                            context,
                            title: 'حذف الصنف',
                            message: 'سيُنقل «${item.name}» إلى سلة المهملات '
                                'ويمكن استرجاعه.',
                          );
                          if (!ok || item.id == null) return;
                          await ref.read(repoProvider).deleteItem(item.id!);
                          bump(ref);
                          if (context.mounted) {
                            showSnack(context, 'نُقل الصنف إلى سلة المهملات');
                          }
                        },
                        icon: Icon(Icons.delete_outline,
                            size: 19, color: AppColors.dangerOf(context)),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// بطاقة الصنف في نمط الشبكة.
class _ItemGridCard extends ConsumerWidget {
  final Item item;
  final String badge;
  const _ItemGridCard({required this.item, this.badge = ''});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOut = item.quantity <= 0;
    final isLow = item.minQuantity > 0 && item.quantity <= item.minQuantity;
    final status = isOut
        ? ('نفد', AppColors.red)
        : (isLow ? ('قليل', AppColors.amber) : ('متوفر', AppColors.green));
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceOf(context),
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.card(scheme),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openItemForm(context, ref, item: item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // صورة الصنف في النصف العلوي + قائمة الخيارات السريعة.
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _ItemThumb(image: item.image),
                  PositionedDirectional(
                    top: 6,
                    start: 6,
                    child: Material(
                      color: Colors.white.withValues(alpha: .92),
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => _itemQuickMenu(context, ref, item),
                        child: const SizedBox(
                          width: 30,
                          height: 30,
                          child: Icon(Icons.more_vert,
                              size: 17, color: Color(0xFF5B6B83)),
                        ),
                      ),
                    ),
                  ),
                  PositionedDirectional(
                    top: 6,
                    end: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: status.$2.withValues(alpha: .14),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text(
                        status.$1,
                        style: TextStyle(
                          color: status.$2,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      height: 1.25,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${Fmt.money(item.quantity)} ${item.unit}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.text3Of(context),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: FittedBox(
                          alignment: AlignmentDirectional.centerStart,
                          fit: BoxFit.scaleDown,
                          child: Text(
                            Fmt.money(item.sellPrice, 0),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                              color: isOut
                                  ? AppColors.dangerOf(context)
                                  : AppColors.green,
                            ),
                          ),
                        ),
                      ),
                      if (badge.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            badge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.text3Of(context),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// قائمة الخيارات السريعة لبطاقة الصنف في المخزون.
void _itemQuickMenu(BuildContext context, WidgetRef ref, Item item) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceOf(ctx),
        borderRadius: AppRadius.sheetTop,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.borderOf(ctx),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: Icon(Icons.edit_outlined,
                  color: AppColors.primaryOf(ctx)),
              title: const Text('تعديل المنتج'),
              onTap: () {
                Navigator.pop(ctx);
                openItemForm(context, ref, item: item);
              },
            ),
            ListTile(
              leading: Icon(Icons.add_shopping_cart_outlined,
                  color: AppColors.greenOf(ctx)),
              title: const Text('إضافة إلى سلة البيع'),
              onTap: () {
                Navigator.pop(ctx);
                // (قانون المخزون) منع السالب: تُمرَّر سياسة النفاد صراحةً.
                final st = ref.read(settingsProvider).valueOrNull ?? const {};
                final allowNegative = st['allowNegativeStock'] == '1';
                final ok = ref
                    .read(posDraftProvider.notifier)
                    .addItem(item, allowNegative: allowNegative);
                showSnack(
                  context,
                  ok ? 'أُضيف للسلة: ${item.name}' : 'الكمية المتاحة لا تكفي',
                  error: !ok,
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}


class _Meta extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Meta({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.text3Of(context)),
          const SizedBox(width: 3),
          // (2026-09-24) سقف عرض + علامة حذف: بطاقات المخزون الضيقة
          // (171px على هاتف 360) لم تعد تفيض بنصّ القسم/الوحدة الطويل.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 128),
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: 11.5, color: AppColors.text2Of(context)),
            ),
          ),
        ],
      );
}

class _Price extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Price({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  TextStyle(fontSize: 10.5, color: AppColors.text3Of(context))),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      );
}

/// يفتح نموذج إضافة/تعديل فئة (مع تحديد الفئة الأب لشجرة الفئات).
/// [parentId] يُعيَّن ابتداءً عند الإضافة من داخل فئة معيّنة.
Future<int?> openItemCategoryForm(
  BuildContext context,
  WidgetRef ref, {
  ItemCategory? category,
  int? parentId,
  int? sectionId,
}) =>
    showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _ItemCategoryForm(
          category: category,
          presetParentId: parentId,
          presetSectionId: sectionId,
        ),
      ),
    ).then((id) {
      if (id != null) bump(ref);
      return id;
    });

class _ItemCategoryForm extends ConsumerStatefulWidget {
  final ItemCategory? category;

  /// (2026-09-22) فئة أب مبدئية عند الإضافة من داخل فئة.
  final int? presetParentId;

  /// (2026-09-22) قسم مبدئي عند الإضافة من شريط قسم محدد.
  final int? presetSectionId;

  const _ItemCategoryForm(
      {this.category, this.presetParentId, this.presetSectionId});

  @override
  ConsumerState<_ItemCategoryForm> createState() => _ItemCategoryFormState();
}

class _ItemCategoryFormState extends ConsumerState<_ItemCategoryForm> {
  late final TextEditingController _name;
  int? _parentId;
  int? _sectionId;
  String? _error;
  bool _saving = false;

  /// (2026-09-24) الهوية البصرية للفئة: مفتاح أيقونة + لون كرت.
  late String _iconKey;
  late String _color;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.category?.name ?? '');
    _parentId = widget.category?.parentId ?? widget.presetParentId;
    _sectionId = widget.category?.sectionId ?? widget.presetSectionId;
    _iconKey = widget.category?.iconKey ?? '';
    _color = widget.category?.colorHex ?? '';
  }

  /// الفئات الممنوع اختيارها كأب: الفئة نفسها وكل سلالتها (منع الدوران).
  Set<int> _forbidden(List<ItemCategory> all) {
    final self = widget.category?.id;
    if (self == null) return const <int>{};
    final childrenOf = <int, List<int>>{};
    for (final c in all) {
      final p = c.parentId;
      if (p != null && c.id != null) {
        childrenOf.putIfAbsent(p, () => <int>[]).add(c.id!);
      }
    }
    final banned = <int>{self};
    final queue = <int>[self];
    while (queue.isNotEmpty) {
      final cur = queue.removeLast();
      for (final child in childrenOf[cur] ?? const <int>[]) {
        if (banned.add(child)) queue.add(child);
      }
    }
    return banned;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'اسم الفئة مطلوب');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final now = DateTime.now();
      final category = (widget.category ??
              ItemCategory(name: name, createdAt: now, updatedAt: now))
          .copyWith(
        name: name,
        parentId: _parentId,
        sectionId: _sectionId,
        iconKey: _iconKey,
        colorHex: _color,
      );
      final id = await ref.read(repoProvider).saveItemCategory(category);
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e'.replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => _BrandSheet(
        scrollable: true,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.folder_outlined,
                      color: AppColors.primaryOf(context)),
                  const SizedBox(width: 8),
                  Text(
                    widget.category == null ? 'إضافة فئة جديدة' : 'تعديل الفئة',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _name,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'اسم الفئة *',
                  hintText: 'مثل: المواد الغذائية أو الأجهزة',
                  prefixIcon: const Icon(Icons.category_outlined),
                  errorText: _error,
                ),
                onSubmitted: (_) => _saving ? null : _save(),
              ),
              const SizedBox(height: 12),
              // (2026-09-24) اختيار الأيقونة واللون مع معاينة فورية.
              _BrandPickers(
                iconKey: _iconKey,
                color: _color,
                onIcon: (k) => setState(() => _iconKey = k),
                onColor: (c) => setState(() => _color = c),
              ),
              const SizedBox(height: 12),
              // (2026-09-22) القسم: «عام» يعني بلا قسم.
              Consumer(
                builder: (ctx, rref, _) {
                  final secs =
                      rref.watch(sectionsProvider).valueOrNull ?? const [];
                  return DropdownButtonFormField<int?>(
                    initialValue: _sectionId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'القسم',
                      hintText: 'عام (بدون قسم)',
                      prefixIcon: Icon(Icons.storefront_outlined),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('عام (بدون قسم)'),
                      ),
                      for (final sec in secs)
                        DropdownMenuItem<int?>(
                          value: sec.id,
                          child: Text(sec.name,
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged:
                        _saving ? null : (v) => setState(() => _sectionId = v),
                  );
                },
              ),
              const SizedBox(height: 12),
              // (2026-09-22) اختيار الفئة الأب: فارغ = فئة رئيسية.
              Consumer(
                builder: (ctx, rref, _) {
                  final all = rref.watch(itemCategoriesProvider).valueOrNull ??
                      const [];
                  final banned = _forbidden(all);
                  final options = all
                      .where((c) => c.id != null && !banned.contains(c.id))
                      .toList();
                  final valid = _parentId != null && banned.contains(_parentId)
                      ? null
                      : _parentId;
                  return DropdownButtonFormField<int?>(
                    initialValue: valid,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'الفئة الأب',
                      hintText: 'فئة رئيسية (بدون أب)',
                      prefixIcon: Icon(Icons.account_tree_outlined),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('فئة رئيسية (بدون أب)'),
                      ),
                      for (final c in options)
                        DropdownMenuItem<int?>(
                          value: c.id,
                          child: Text(
                            c.parentId == null ? c.name : '↳ ${c.name}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged:
                        _saving ? null : (v) => setState(() => _parentId = v),
                  );
                },
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(
                    widget.category == null ? 'حفظ الفئة' : 'حفظ التعديل',
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

// ==================== نموذج الصنف ====================

Future<void> openItemForm(
  BuildContext context,
  WidgetRef ref, {
  Item? item,
  int? categoryId,
  int? sectionId,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: _ItemForm(
          item: item,
          presetCategoryId: categoryId,
          presetSectionId: sectionId,
        ),
      ),
    ).then((_) => bump(ref));

class _ItemForm extends ConsumerStatefulWidget {
  final Item? item;
  final int? presetSectionId;
  final int? presetCategoryId;
  const _ItemForm({this.item, this.presetCategoryId, this.presetSectionId});

  @override
  ConsumerState<_ItemForm> createState() => _ItemFormState();
}

class _ItemFormState extends ConsumerState<_ItemForm> {
  late final TextEditingController _name;
  late final TextEditingController _sku;
  late final TextEditingController _unit;
  late final TextEditingController _buy;
  late final TextEditingController _sell;
  late final TextEditingController _qty;
  late final TextEditingController _min;
  late final TextEditingController _notes;
  int? _categoryId;
  int? _sectionId;
  String? _image;
  bool _saving = false;
  String? _error;
  String? _categoryError;

  @override
  void initState() {
    super.initState();
    final i = widget.item;
    _categoryId = widget.presetCategoryId ?? i?.categoryId;
    _sectionId = widget.presetSectionId ?? i?.sectionId;
    _image = i?.image ?? '';
    _name = TextEditingController(text: i?.name ?? '');
    _sku = TextEditingController(text: i?.sku ?? '');
    _unit = TextEditingController(text: i?.unit ?? 'حبة');
    _buy = TextEditingController(text: i == null ? '' : _n(i.buyPrice));
    _sell = TextEditingController(text: i == null ? '' : _n(i.sellPrice));
    _qty = TextEditingController(text: i == null ? '' : _n(i.quantity));
    _min = TextEditingController(text: i == null ? '' : _n(i.minQuantity));
    _notes = TextEditingController(text: i?.notes ?? '');
    for (final c in [_buy, _sell]) {
      c.addListener(() => setState(() {}));
    }
  }

  static String _n(double v) =>
      v == 0 ? '' : (v == v.roundToDouble() ? v.toInt().toString() : '$v');

  @override
  void dispose() {
    for (final c in [_name, _sku, _unit, _buy, _sell, _qty, _min, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  double get _buyV => Fmt.parseAmount(_buy.text) ?? 0;
  double get _sellV => Fmt.parseAmount(_sell.text) ?? 0;

  Future<void> _addCategory() async {
    final id = await openItemCategoryForm(context, ref);
    if (mounted && id != null) setState(() => _categoryId = id);
  }

  Widget _categoryPicker(
    BuildContext context,
    AsyncValue<List<ItemCategory>> state,
  ) {
    // الفئات المعروضة: فئات القسم المختار + الفئات بلا قسم (عام).
    final scoped = state.maybeWhen(
          data: (list) => _sectionId == null
              ? list
              : list
                  .where((c) =>
                      c.sectionId == _sectionId || c.sectionId == null)
                  .toList(),
          orElse: () => null,
        ) ??
        (state.valueOrNull ?? const <ItemCategory>[]);
    return _categoryPickerBody(context, state, scoped);
  }

  Widget _categoryPickerBody(
    BuildContext context,
    AsyncValue<List<ItemCategory>> state,
    List<ItemCategory> scoped,
  ) {
    return state.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      ),
      error: (e, _) => InputDecorator(
        decoration: const InputDecoration(
          labelText: 'الفئة *',
          errorText: 'تعذّر تحميل الفئات',
          prefixIcon: Icon(Icons.category_outlined),
        ),
        child: Text('$e', maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
      data: (_) {
        final categories = scoped;
        final validId =
            categories.any((c) => c.id == _categoryId) ? _categoryId : null;
        return Column(
          children: [
            DropdownButtonFormField<int?>(
              initialValue: validId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'الفئة (اختياري — الافتراضي: عام)',
                errorText: _categoryError,
                prefixIcon: const Icon(Icons.category_outlined),
              ),
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: Text('عام (بدون فئة محددة)'),
                ),
                ...categories.map(
                  (category) => DropdownMenuItem<int?>(
                    value: category.id,
                    child: Text(
                      category.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              onChanged: (value) {
                setState(() {
                  _categoryId = value;
                  _categoryError = null;
                });
              },
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _addCategory,
                icon: const Icon(Icons.add, size: 17),
                label: const Text('إضافة فئة جديدة'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'اسم الصنف مطلوب');
      return;
    }

    final repo = ref.read(repoProvider);
    ItemCategory? category;
    if (_categoryId != null) {
      final categories = await repo.itemCategories();
      category =
          categories.where((value) => value.id == _categoryId).firstOrNull;
    }

    final now = DateTime.now();
    final base = widget.item;
    final effectiveSectionId =
        _sectionId == kGeneralSectionId ? null : (_sectionId ?? category?.sectionId);
    setState(() => _saving = true);
    await HapticFeedback.mediumImpact();
    final it =
        (base ?? Item(name: name, createdAt: now, updatedAt: now)).copyWith(
      name: name,
      categoryId: category?.id,
      sectionId: effectiveSectionId,
      image: _image ?? '',
      sku: _sku.text.trim(),
      unit: _unit.text.trim().isEmpty ? 'حبة' : _unit.text.trim(),
      buyPrice: _buyV,
      sellPrice: _sellV,
      quantity: Fmt.parseAmount(_qty.text) ?? 0,
      minQuantity: Fmt.parseAmount(_min.text) ?? 0,
      category: category?.name ?? 'عام',
      notes: _notes.text.trim(),
    );
    try {
      await repo.saveItem(it);
      bump(ref);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        showSnack(
          context,
          e is StateError ? e.message : 'تعذّر حفظ المنتج: $e',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// اختيار صورة الصنف (معرض الجهاز) — تُضغط وتُصغّر بشدة كـ Thumbnail صغير جداً
  /// وتُحفظ كمسار نسبي داخل المستندات لتوحيد صور الأصناف عبر السحابة بأقل استهلاك ممكن.
  Future<void> _pickImage() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 160,
        maxHeight: 160,
        imageQuality: 45,
      );
      if (picked == null) return;
      final rel = await MediaPaths.saveCompressedItemImage(picked.path);
      if (rel.isNotEmpty && mounted) {
        setState(() => _image = rel);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(itemCategoriesProvider);
    final profit = _sellV - _buyV;
    return _BrandSheet(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.inventory_2_outlined,
                    color: AppColors.primaryOf(context),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.item == null ? 'إضافة منتج جديد' : 'تعديل المنتج',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // (2026-09-22) معاينة دائرية لصورة الصنف مع زر رفع سريع.
              Row(
                children: [
                  Stack(
                    children: [
                      CircleAvatar(
                        radius: 34,
                        backgroundColor: AppColors.primarySoftOf(context),
                        backgroundImage: (_image ?? '').isNotEmpty &&
                                MediaPaths.exists(_image ?? '')
                            ? FileImage(
                                File(MediaPaths.toAbsolute(_image ?? '')))
                            : null,
                        child: (_image ?? '').isEmpty ||
                                !MediaPaths.exists(_image ?? '')
                            ? Icon(Icons.inventory_2_outlined,
                                size: 30,
                                color: AppColors.primaryOf(context))
                            : null,
                      ),
                      PositionedDirectional(
                        bottom: 0,
                        end: 0,
                        child: Material(
                          color: AppColors.primary,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: _pickImage,
                            child: const Padding(
                              padding: EdgeInsets.all(5),
                              child: Icon(Icons.photo_camera_outlined,
                                  size: 16, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _image?.isNotEmpty == true
                          ? 'صورة الصنف مضافة — اضغط الكاميرا لتغييرها'
                          : 'أضف صورة للصنف (اختياري) لتسهيل تمييزه في البيع',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.text2Of(context),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // (2026-09-22) القسم ← الفئة: اختيار القسم يفلتر الفئات.
              Consumer(
                builder: (ctx, rref, _) {
                  final secs = rref.watch(sectionsProvider).valueOrNull ?? const [];
                  return DropdownButtonFormField<int?>(
                    initialValue: _sectionId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'القسم',
                      hintText: 'عام (بدون قسم)',
                      prefixIcon: Icon(Icons.storefront_outlined),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('عام (بدون قسم)'),
                      ),
                      for (final sec in secs)
                        DropdownMenuItem<int?>(
                          value: sec.id,
                          child: Text(sec.name,
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      _sectionId = v;
                      _categoryId = null;
                    }),
                  );
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                autofocus: widget.item == null,
                decoration: InputDecoration(
                  labelText: 'اسم الصنف *',
                  prefixIcon: const Icon(Icons.label_outline),
                  errorText: _error,
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
              const SizedBox(height: 10),
              _categoryPicker(context, categories),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _sku,
                      decoration: InputDecoration(
                        labelText: 'الرمز / الباركود',
                        prefixIcon: const Icon(Icons.qr_code),
                        suffixIcon: IconButton(
                          tooltip: 'مسح الباركود بالكاميرا',
                          icon: const Icon(Icons.barcode_reader),
                          onPressed: () async {
                            final code = await scanBarcode(context);
                            if (code != null && code.isNotEmpty) {
                              setState(() => _sku.text = code);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _unit,
                      decoration: const InputDecoration(
                        labelText: 'الوحدة',
                        prefixIcon: Icon(Icons.straighten),
                      ),
                    ),
                  ),
                ],
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () {
                    // توليد رمز باركود فريد (EAN-13 مبسّط) إن لم يكن هناك رمز.
                    if (_sku.text.trim().isEmpty) {
                      final now = DateTime.now();
                      final base =
                          '62${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}${now.millisecondsSinceEpoch.toString().substring(7)}';
                      setState(() => _sku.text = base.substring(0, 12));
                    }
                  },
                  icon: const Icon(Icons.qr_code_2, size: 18),
                  label: const Text('توليد رمز باركود تلقائي'),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _AmountField(
                      controller: _buy,
                      label: 'سعر الشراء',
                      icon: Icons.shopping_cart_outlined,
                      words: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _AmountField(
                      controller: _sell,
                      label: 'سعر البيع',
                      icon: Icons.sell_outlined,
                      words: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: profit >= 0
                      ? AppColors.greenSoftOf(context)
                      : AppColors.dangerSoftOf(context),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      profit >= 0 ? Icons.trending_up : Icons.trending_down,
                      size: 18,
                      color: profit >= 0
                          ? AppColors.greenOf(context)
                          : AppColors.dangerOf(context),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'ربح الوحدة: ${Fmt.money(profit, 0)}'
                      '${_buyV > 0 ? '  (${(profit / _buyV * 100).toStringAsFixed(0)}٪)' : ''}',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: profit >= 0
                            ? AppColors.greenOf(context)
                            : AppColors.dangerOf(context),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _AmountField(
                      controller: _qty,
                      label: 'الكمية الحالية',
                      icon: Icons.inventory_outlined,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _AmountField(
                      controller: _min,
                      label: 'حد التنبيه',
                      icon: Icons.warning_amber_outlined,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _notes,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'ملاحظات',
                  prefixIcon: Icon(Icons.notes_outlined),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('حفظ المنتج'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// حقل مبلغ مع آلة حاسبة سريعة. عند تفعيل [words] يظهر المبلغ بالحروف تحته.
class _AmountField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool words;
  const _AmountField({
    required this.controller,
    required this.label,
    required this.icon,
    this.words = false,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: label,
              prefixIcon: Icon(icon),
              suffixIcon: IconButton(
                tooltip: 'آلة حاسبة',
                icon: const Icon(Icons.calculate_outlined),
                onPressed: () async {
                  final v =
                      await openCalculator(context, initial: controller.text);
                  if (v != null) {
                    controller.text =
                        v == v.roundToDouble() ? '${v.toInt()}' : '$v';
                  }
                },
              ),
            ),
          ),
          if (words) AmountWords(controller: controller),
        ],
      );
}

/// (2026-09-24) غلاف موحّد للأوراق السفلية: زوايا علوية 24px ومقبض سحب.
class _BrandSheet extends StatelessWidget {
  const _BrandSheet({required this.child, this.scrollable = false});

  final Widget child;

  /// يغلّف المحتوى بمنطقة تمرير (للنماذج القصيرة التي لا تملك واحدة).
  final bool scrollable;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceOf(context),
          borderRadius: AppRadius.sheetTop,
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
              if (scrollable)
                Flexible(child: SingleChildScrollView(child: child))
              else
                Flexible(child: child),
            ],
          ),
        ),
      );
}

/// (2026-09-24) منتقيا الأيقونة واللون مع معاينة فورية لشكل الكرت.
class _BrandPickers extends StatelessWidget {
  const _BrandPickers({
    required this.iconKey,
    required this.color,
    required this.onIcon,
    required this.onColor,
  });

  final String iconKey;
  final String color;
  final ValueChanged<String> onIcon;
  final ValueChanged<String> onColor;

  /// النغمة الفعالة: مفتاح باستيل أو لون HEX مخصّص أو نغمة الأيقونة التلقائية.
  AppTone get _tone =>
      IconCatalog.resolveTone(colorHex: color, iconKey: iconKey);

  @override
  Widget build(BuildContext context) {
    final tone = _tone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // معاينة مدمجة مع زر اختيار الأيقونة في صف واحد أنيق.
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () async {
                final picked = await showIconPicker(
                  context,
                  initialKey: iconKey,
                );
                if (picked != null) onIcon(picked);
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: tone.foreground.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: tone.foreground.withValues(alpha: .30)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        IconCatalog.of(iconKey),
                        size: 17,
                        color: tone.foreground,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'اختيار أيقونة',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: tone.foreground,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'لون البطاقة',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text2Of(context),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ColorTonePicker(value: color, onChanged: onColor),
      ],
    );
  }
}

/// صورة الصنف أعلى بطاقة الشبكة (ملف محلي) مع بديل أيقوني باستيل ملون وحي.
class _ItemThumb extends StatelessWidget {
  const _ItemThumb({required this.image});

  final String image;

  @override
  Widget build(BuildContext context) {
    final hasImage = image.isNotEmpty && MediaPaths.exists(image);
    const tone = AppTone.blue;
    final placeholder = Container(
      color: tone.foreground.withValues(alpha: 0.12),
      child: Center(
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: tone.foreground.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            Icons.inventory_2_outlined,
            size: 26,
            color: tone.foreground,
          ),
        ),
      ),
    );
    if (!hasImage) return placeholder;
    return Image.file(
      File(MediaPaths.toAbsolute(image)),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => placeholder,
    );
  }
}

/// صورة الصنف المصغّرة (ملف محلي) مع بديل أيقوني آمن — تستخدمها بطاقة القائمة.
class _Thumb extends StatelessWidget {
  final String image;

  /// نصف قطر الصورة وحجم بديلها — ثوابت (الاستدعاء الوحيد يستخدمها).
  static const double radius = 13;
  static const double size = 26;

  const _Thumb({required this.image});

  @override
  Widget build(BuildContext context) {
    final path = image.isEmpty ? '' : MediaPaths.toAbsolute(image);
    final file = path.isEmpty ? null : File(path);
    final hasImage = file != null && MediaPaths.exists(image);
    return Container(
      width: radius == 0 ? null : 52,
      height: radius == 0 ? null : 52,
      decoration: BoxDecoration(
        color: AppTone.blue.foreground.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: hasImage
            ? Image.file(
                file,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _fallback(context),
              )
            : _fallback(context),
      ),
    );
  }

  Widget _fallback(BuildContext context) => Center(
        child: Icon(
          Icons.inventory_2_outlined,
          size: size,
          color: AppTone.blue.foreground,
        ),
      );
}

/// يفتح نافذة قائمة النواقص المنفصلة والمرتبة مع إمكانية حفظها كصورة PNG أو ملف PDF.
Future<void> openShortagesListSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => FractionallySizedBox(
      heightFactor: 0.90,
      child: _ShortagesListSheet(parentContext: context),
    ),
  );
}

class _ShortageDraftRow {
  final Item item;
  bool selected;
  double requiredQty;

  _ShortageDraftRow({
    required this.item,
    this.selected = true,
    required this.requiredQty,
  });
}

class _ShortagesListSheet extends ConsumerStatefulWidget {
  final BuildContext parentContext;
  const _ShortagesListSheet({required this.parentContext});

  @override
  ConsumerState<_ShortagesListSheet> createState() =>
      _ShortagesListSheetState();
}

class _ShortagesListSheetState extends ConsumerState<_ShortagesListSheet> {
  final List<_ShortageDraftRow> _rows = [];
  bool _initialized = false;
  bool _busyImage = false;
  bool _busyPdf = false;
  String _searchAddQuery = '';
  int _filterTab = 0; // 0 = الكل، 1 = نافدة (0)، 2 = تحت حد التنبيه

  void _sortRows() {
    _rows.sort((a, b) {
      final ao = a.item.quantity <= 0 ? 0 : 1;
      final bo = b.item.quantity <= 0 ? 0 : 1;
      final c = ao.compareTo(bo);
      if (c != 0) return c;
      final q = a.item.quantity.compareTo(b.item.quantity);
      if (q != 0) return q;
      return a.item.name
          .trim()
          .toLowerCase()
          .compareTo(b.item.name.trim().toLowerCase());
    });
  }

  void _initRows(List<Item> allItems) {
    if (_initialized) return;
    _initialized = true;
    final shortages = allItems.where(isShortageItem).toList();
    for (final it in shortages) {
      double suggested = 1;
      if (it.minQuantity > 0) {
        final diff = it.minQuantity - it.quantity;
        suggested = diff > 0 ? diff : it.minQuantity;
      } else if (it.quantity <= 0) {
        suggested = 5;
      }
      _rows.add(
        _ShortageDraftRow(
          item: it,
          selected: true,
          requiredQty: suggested,
        ),
      );
    }
    _sortRows();
  }

  List<_ShortageDraftRow> get _filteredRows {
    return _rows.where((r) {
      if (_filterTab == 1) return r.item.quantity <= 0;
      if (_filterTab == 2) return r.item.quantity > 0;
      return true;
    }).toList();
  }

  List<_ShortageDraftRow> get _selectedRows =>
      _rows.where((r) => r.selected && r.requiredQty > 0).toList();

  Future<void> _promptEditRequiredQty(_ShortageDraftRow row) async {
    final ctrl = TextEditingController(
      text: row.requiredQty == row.requiredQty.roundToDouble()
          ? row.requiredQty.toStringAsFixed(0)
          : row.requiredQty.toStringAsFixed(2),
    );
    final res = await showDialog<double>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text('الكمية المطلوبة — ${row.item.name}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'الكمية المطلوبة للطلب (${row.item.unit})',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(ctrl.text.trim());
              Navigator.pop(dCtx, v);
            },
            child: const Text('تطبيق'),
          ),
        ],
      ),
    );
    if (res != null && res > 0 && mounted) {
      setState(() {
        row.requiredQty = res;
        row.selected = true;
      });
    }
  }

  Future<void> _exportAsImage() async {
    final picked = _selectedRows;
    if (picked.isEmpty) {
      showSnack(context, 'اختر صنفاً واحداً على الأقل لتصدير القائمة',
          error: true);
      return;
    }
    setState(() => _busyImage = true);
    try {
      final st = await ref.read(repoProvider).settings();
      final orgName =
          (st['businessName'] ?? st['org.name'] ?? 'المتجر').trim();
      final bytes = await _renderShortagesImage(
        orgName: orgName,
        rows: picked,
        date: DateTime.now(),
      );
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/shortages_$stamp.png');
      await file.writeAsBytes(bytes, flush: true);

      try {
        final docDir = await getApplicationDocumentsDirectory();
        final savedCopy = File('${docDir.path}/shortages_$stamp.png');
        await savedCopy.writeAsBytes(bytes, flush: true);
      } catch (_) {}

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        subject: 'قائمة النواقص — $orgName',
        text: 'قائمة نواقص المخزون ($orgName) - ${Fmt.date(DateTime.now())}',
      );
      if (mounted) {
        showSnack(context, '✅ تم تجهيز وحفظ صورة قائمة النواقص بنجاح');
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, 'تعذر حفظ صورة النواقص: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _busyImage = false);
    }
  }

  Future<void> _exportAsPdf() async {
    final picked = _selectedRows;
    if (picked.isEmpty) {
      showSnack(context, 'اختر صنفاً واحداً على الأقل لتصدير ملف PDF',
          error: true);
      return;
    }
    setState(() => _busyPdf = true);
    try {
      final st = await ref.read(repoProvider).settings();
      final orgName =
          (st['businessName'] ?? st['org.name'] ?? 'المتجر').trim();
      final pdfBytes = await _buildShortagesPdf(
        orgName: orgName,
        rows: picked,
        date: DateTime.now(),
      );
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final filename = 'shortages_$stamp.pdf';

      try {
        final docDir = await getApplicationDocumentsDirectory();
        final savedPdf = File('${docDir.path}/$filename');
        await savedPdf.writeAsBytes(pdfBytes, flush: true);
      } catch (_) {}

      await Printing.sharePdf(
        bytes: pdfBytes,
        filename: filename,
      );
      if (mounted) {
        showSnack(context, '✅ تم إنشاء ملف PDF لقائمة النواقص بنجاح');
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, 'تعذر إنشاء ملف PDF: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _busyPdf = false);
    }
  }

  Widget _buildFilterChip({
    required int index,
    required String label,
    required Color activeColor,
  }) {
    final selected = _filterTab == index;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => _filterTab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? activeColor.withValues(alpha: 0.14)
                : AppColors.surfaceOf(context),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? activeColor : AppColors.borderOf(context),
              width: selected ? 1.4 : 1.0,
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
              color: selected ? activeColor : AppColors.text2Of(context),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(itemsProvider);
    final allItems = itemsAsync.valueOrNull ?? const <Item>[];
    _initRows(allItems);

    final outCount = _rows.where((r) => r.item.quantity <= 0).length;
    final lowCount = _rows.where((r) => r.item.quantity > 0).length;
    final visibleRows = _filteredRows;

    final existingIds = _rows.map((r) => r.item.id).toSet();
    final extraCandidates = _searchAddQuery.trim().isEmpty
        ? const <Item>[]
        : allItems
            .where((it) =>
                !it.isDeleted &&
                !existingIds.contains(it.id) &&
                it.name
                    .toLowerCase()
                    .contains(_searchAddQuery.trim().toLowerCase()))
            .take(8)
            .toList();

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 4,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // رأس النافذة
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFD97706).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.assignment_late_outlined,
                  color: Color(0xFFD97706),
                  size: 22,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'قائمة النواقص المرتبة وطلب البضاعة',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      'مرتبة تلقائياً (النافدة أولاً ثم الأقل كمية) — حفظ كصورة أو PDF',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.text2Of(context),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // تبويبات الفلترة السريعة داخل قائمة النواقص
          Row(
            children: [
              _buildFilterChip(
                index: 0,
                label: 'الكل (${_rows.length})',
                activeColor: AppColors.primaryOf(context),
              ),
              const SizedBox(width: 6),
              _buildFilterChip(
                index: 1,
                label: 'نافدة ($outCount)',
                activeColor: AppColors.dangerOf(context),
              ),
              const SizedBox(width: 6),
              _buildFilterChip(
                index: 2,
                label: 'تحت الحد ($lowCount)',
                activeColor: const Color(0xFFD97706),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // حقل بحث سريع لإضافة أي صنف إضافي للقائمة
          TextField(
            decoration: InputDecoration(
              isDense: true,
              hintText: 'ابحث لإضافة صنف آخر إلى قائمة النواقص...',
              prefixIcon: const Icon(Icons.add_shopping_cart_rounded, size: 19),
              suffixIcon: _searchAddQuery.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setState(() => _searchAddQuery = ''),
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onChanged: (v) => setState(() => _searchAddQuery = v),
          ),
          if (extraCandidates.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 6),
              constraints: const BoxConstraints(maxHeight: 140),
              decoration: BoxDecoration(
                color: AppColors.surfaceOf(context),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.borderOf(context)),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: extraCandidates.length,
                itemBuilder: (_, i) {
                  final it = extraCandidates[i];
                  return ListTile(
                    dense: true,
                    title: Text(
                      it.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      'المتوفر: ${Fmt.qty(it.quantity)} ${it.unit} • حد التنبيه: ${Fmt.qty(it.minQuantity)}',
                      style: const TextStyle(fontSize: 11.5),
                    ),
                    trailing: FilledButton.tonalIcon(
                      onPressed: () {
                        setState(() {
                          _rows.add(
                            _ShortageDraftRow(
                              item: it,
                              selected: true,
                              requiredQty:
                                  it.minQuantity > 0 ? it.minQuantity : 5,
                            ),
                          );
                          _sortRows();
                          _searchAddQuery = '';
                        });
                      },
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('إضافة'),
                    ),
                  );
                },
              ),
            ),

          const SizedBox(height: 6),
          // شريط تحديد الكل / الإحصائية
          Row(
            children: [
              Text(
                'الأصناف المحددة: ${_selectedRows.length} من ${_rows.length}',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () {
                  final allSelected = _rows.every((r) => r.selected);
                  setState(() {
                    for (final r in _rows) {
                      r.selected = !allSelected;
                    }
                  });
                },
                icon: Icon(
                  _rows.every((r) => r.selected)
                      ? Icons.deselect_outlined
                      : Icons.select_all_rounded,
                  size: 17,
                ),
                label: Text(
                  _rows.every((r) => r.selected)
                      ? 'إلغاء تحديد الكل'
                      : 'تحديد الكل',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),

          // قائمة الأصناف الناقصة المرتبة والمرقمة
          Expanded(
            child: visibleRows.isEmpty
                ? const EmptyState(
                    icon: Icons.inventory_rounded,
                    title: 'لا توجد أصناف ضمن هذا التصنيف',
                    message:
                        'يمكنك البحث في الحقل أعلاه لإضافة أي صنف ترغب بطلبه إلى القائمة.',
                  )
                : ListView.separated(
                    itemCount: visibleRows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final r = visibleRows[index];
                      final it = r.item;
                      final isOut = it.quantity <= 0;
                      final statusColor = isOut
                          ? AppColors.dangerOf(context)
                          : const Color(0xFFD97706);
                      final statusLabel =
                          isOut ? 'نفدت الكمية' : 'تحت حد التنبيه';

                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        decoration: BoxDecoration(
                          color: r.selected
                              ? AppColors.surfaceOf(context)
                              : AppColors.surfaceOf(context)
                                  .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: r.selected
                                ? statusColor.withValues(alpha: 0.45)
                                : AppColors.borderOf(context),
                          ),
                        ),
                        child: Row(
                          children: [
                            // رقم تسلسلي مرتب (#1, #2, ...)
                            Container(
                              width: 26,
                              height: 26,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: statusColor.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${index + 1}',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w900,
                                  color: statusColor,
                                ),
                              ),
                            ),
                            Checkbox(
                              value: r.selected,
                              visualDensity: VisualDensity.compact,
                              onChanged: (v) =>
                                  setState(() => r.selected = v ?? false),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          it.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontSize: 13.5,
                                          ),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: statusColor.withValues(
                                              alpha: 0.12),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          statusLabel,
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w800,
                                            color: statusColor,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    'المتوفر: ${Fmt.qty(it.quantity)} ${it.unit}  •  حد التنبيه: ${Fmt.qty(it.minQuantity)} ${it.unit}',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.text2Of(context),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            // التحكم بالكمية المطلوبة للطلب
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Text(
                                  'الكمية المطلوبة',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.text3Of(context),
                                  ),
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      iconSize: 18,
                                      icon: const Icon(
                                          Icons.remove_circle_outline),
                                      onPressed: () {
                                        if (r.requiredQty > 1) {
                                          setState(() => r.requiredQty -= 1);
                                        }
                                      },
                                    ),
                                    InkWell(
                                      borderRadius: BorderRadius.circular(6),
                                      onTap: () => _promptEditRequiredQty(r),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: AppColors.primaryOf(context)
                                              .withValues(alpha: 0.10),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          Fmt.qty(r.requiredQty),
                                          style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: 13,
                                            color: AppColors.primaryOf(context),
                                          ),
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      iconSize: 18,
                                      icon:
                                          const Icon(Icons.add_circle_outline),
                                      onPressed: () =>
                                          setState(() => r.requiredQty += 1),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),

          const SizedBox(height: 12),
          // أزرار الحفظ والمشاركة (كصورة PNG أو كملف PDF)
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    backgroundColor: const Color(0xFF0F3E78),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: (_busyImage || _busyPdf) ? null : _exportAsImage,
                  icon: _busyImage
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.image_outlined, size: 20),
                  label: const Text(
                    'حفظ كصورة (PNG)',
                    style: TextStyle(
                        fontWeight: FontWeight.w900, fontSize: 13.5),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    backgroundColor: const Color(0xFFB91C1C),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: (_busyImage || _busyPdf) ? null : _exportAsPdf,
                  icon: _busyPdf
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.picture_as_pdf_outlined, size: 20),
                  label: const Text(
                    'حفظ كملف PDF',
                    style: TextStyle(
                        fontWeight: FontWeight.w900, fontSize: 13.5),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// يولّد ملف PDF عربي متكامل لقائمة النواقص.
Future<Uint8List> _buildShortagesPdf({
  required String orgName,
  required List<_ShortageDraftRow> rows,
  required DateTime date,
}) async {
  final theme = await PdfFonts.theme();
  final doc = pw.Document(theme: theme);
  final dateStr = Fmt.dateTime(date);

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      textDirection: pw.TextDirection.rtl,
      header: (_) => PdfFonts.rtl(
        child: pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 14),
          padding: const pw.EdgeInsets.all(14),
          decoration: const pw.BoxDecoration(
            color: PdfColor.fromInt(0xFF0F3E78),
            borderRadius: pw.BorderRadius.all(pw.Radius.circular(8)),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    orgName.isEmpty ? 'قائمة نواقص المخزون' : orgName,
                    style: pw.TextStyle(
                      color: PdfColors.white,
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.SizedBox(height: 3),
                  pw.Text(
                    'قائمة النواقص وطلب البضاعة (الأصناف تحت حد التنبيه)',
                    style: const pw.TextStyle(
                      color: PdfColors.white,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    'التاريخ: $dateStr',
                    style: const pw.TextStyle(
                      color: PdfColors.white,
                      fontSize: 10,
                    ),
                  ),
                  pw.SizedBox(height: 3),
                  pw.Text(
                    'إجمالي الأصناف: ${rows.length}',
                    style: pw.TextStyle(
                      color: PdfColors.amber200,
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      build: (_) => [
        PdfFonts.rtl(
          child: pw.Table(
            border: pw.TableBorder.all(
              color: const PdfColor.fromInt(0xFFCBD5E1),
              width: 0.7,
            ),
            columnWidths: const {
              0: pw.FlexColumnWidth(1.2), // الحالة
              1: pw.FlexColumnWidth(1.1), // الوحدة
              2: pw.FlexColumnWidth(1.3), // الكمية المطلوبة
              3: pw.FlexColumnWidth(1.2), // حد التنبيه
              4: pw.FlexColumnWidth(1.2), // المتوفر
              5: pw.FlexColumnWidth(3.2), // اسم الصنف
              6: pw.FixedColumnWidth(28), // م
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(
                  color: PdfColor.fromInt(0xFFF1F5F9),
                ),
                children: [
                  _pdfCell('الحالة', bold: true),
                  _pdfCell('الوحدة', bold: true),
                  _pdfCell('المطلوب طلبه', bold: true),
                  _pdfCell('حد التنبيه', bold: true),
                  _pdfCell('المتوفر', bold: true),
                  _pdfCell('اسم الصنف', bold: true, alignRight: true),
                  _pdfCell('م', bold: true),
                ],
              ),
              for (var i = 0; i < rows.length; i++)
                pw.TableRow(
                  decoration: pw.BoxDecoration(
                    color: i.isEven
                        ? PdfColors.white
                        : const PdfColor.fromInt(0xFFF8FAFC),
                  ),
                  children: [
                    _pdfCell(
                      rows[i].item.quantity <= 0 ? 'نفد' : 'تحت الحد',
                      color: rows[i].item.quantity <= 0
                          ? const PdfColor.fromInt(0xFFB91C1C)
                          : const PdfColor.fromInt(0xFFB45309),
                      bold: true,
                    ),
                    _pdfCell(rows[i].item.unit),
                    _pdfCell(
                      Fmt.qty(rows[i].requiredQty),
                      bold: true,
                      color: const PdfColor.fromInt(0xFF0F3E78),
                    ),
                    _pdfCell(Fmt.qty(rows[i].item.minQuantity)),
                    _pdfCell(Fmt.qty(rows[i].item.quantity)),
                    _pdfCell(rows[i].item.name, bold: true, alignRight: true),
                    _pdfCell('${i + 1}'),
                  ],
                ),
            ],
          ),
        ),
      ],
    ),
  );

  return doc.save();
}

pw.Widget _pdfCell(
  String text, {
  bool bold = false,
  bool alignRight = false,
  PdfColor? color,
}) =>
    pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: pw.Text(
        text,
        textAlign: alignRight ? pw.TextAlign.right : pw.TextAlign.center,
        textDirection: pw.TextDirection.rtl,
        style: pw.TextStyle(
          fontSize: 10,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          color: color ?? const PdfColor.fromInt(0xFF0F172A),
        ),
      ),
    );

/// يرسم صورة عالية الدقة (PNG) لقائمة النواقص باللغة العربية.
Future<Uint8List> _renderShortagesImage({
  required String orgName,
  required List<_ShortageDraftRow> rows,
  required DateTime date,
}) async {
  const double width = 860;
  const double headerHeight = 118;
  const double tableHeaderHeight = 46;
  const double rowHeight = 46;
  const double footerHeight = 52;
  const double pad = 24;

  final double totalHeight = headerHeight +
      tableHeaderHeight +
      (rows.length * rowHeight) +
      footerHeight +
      (pad * 2);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, totalHeight));

  // خلفية بيضاء كاملة
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, totalHeight),
    Paint()..color = const Color(0xFFF8FAFC),
  );

  // ترويسة كحلية
  final headerRect = RRect.fromRectAndRadius(
    const Rect.fromLTWH(pad, pad, width - pad * 2, headerHeight - 12),
    const Radius.circular(14),
  );
  canvas.drawRRect(
    headerRect,
    Paint()..color = const Color(0xFF0F3E78),
  );

  _drawCanvasText(
    canvas,
    text: orgName.isEmpty ? 'قائمة نواقص المخزون' : orgName,
    x: pad + 20,
    y: pad + 18,
    maxWidth: width - pad * 2 - 40,
    fontSize: 22,
    fontWeight: FontWeight.w900,
    color: Colors.white,
    align: TextAlign.right,
  );
  _drawCanvasText(
    canvas,
    text:
        'قائمة النواقص وطلب البضاعة (${rows.length} صنف)  •  ${Fmt.dateTime(date)}',
    x: pad + 20,
    y: pad + 56,
    maxWidth: width - pad * 2 - 40,
    fontSize: 14.5,
    fontWeight: FontWeight.w700,
    color: const Color(0xFFFDE68A),
    align: TextAlign.right,
  );

  double y = pad + headerHeight;

  // ترويسة الجدول
  const tableWidth = width - pad * 2;
  canvas.drawRRect(
    RRect.fromRectAndCorners(
      Rect.fromLTWH(pad, y, tableWidth, tableHeaderHeight),
      topLeft: const Radius.circular(10),
      topRight: const Radius.circular(10),
    ),
    Paint()..color = const Color(0xFFE2E8F0),
  );

  // أعمدة الجدول من اليمين إلى اليسار:
  // م (50) | اسم الصنف (310) | المتوفر (110) | حد التنبيه (110) | المطلوب (130) | الوحدة (102)
  final cols = <({String title, double w})>[
    (title: 'م', w: 50),
    (title: 'اسم الصنف', w: 310),
    (title: 'المتوفر', w: 110),
    (title: 'حد التنبيه', w: 110),
    (title: 'الكمية المطلوبة', w: 130),
    (title: 'الوحدة', w: 102),
  ];

  double colRight = width - pad;
  for (final col in cols) {
    final colLeft = colRight - col.w;
    _drawCanvasText(
      canvas,
      text: col.title,
      x: colLeft + 6,
      y: y + 12,
      maxWidth: col.w - 12,
      fontSize: 13.5,
      fontWeight: FontWeight.w900,
      color: const Color(0xFF0F172A),
      align: col.title == 'اسم الصنف' ? TextAlign.right : TextAlign.center,
    );
    colRight = colLeft;
  }

  y += tableHeaderHeight;

  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    final rowBg = i.isEven ? Colors.white : const Color(0xFFF1F5F9);
    canvas.drawRect(
      Rect.fromLTWH(pad, y, tableWidth, rowHeight),
      Paint()..color = rowBg,
    );
    canvas.drawLine(
      Offset(pad, y + rowHeight),
      Offset(width - pad, y + rowHeight),
      Paint()
        ..color = const Color(0xFFCBD5E1)
        ..strokeWidth = 1,
    );

    final values = <String>[
      '${i + 1}',
      r.item.name,
      Fmt.qty(r.item.quantity),
      Fmt.qty(r.item.minQuantity),
      Fmt.qty(r.requiredQty),
      r.item.unit,
    ];

    double cRight = width - pad;
    for (var c = 0; c < cols.length; c++) {
      final w = cols[c].w;
      final cLeft = cRight - w;
      final isName = c == 1;
      final isReq = c == 4;
      final isAvail = c == 2;
      Color txtColor = const Color(0xFF1E293B);
      if (isReq) txtColor = const Color(0xFF0F3E78);
      if (isAvail && r.item.quantity <= 0) txtColor = const Color(0xFFB91C1C);

      _drawCanvasText(
        canvas,
        text: values[c],
        x: cLeft + 6,
        y: y + 12,
        maxWidth: w - 12,
        fontSize: 13.5,
        fontWeight: (isName || isReq) ? FontWeight.w800 : FontWeight.w600,
        color: txtColor,
        align: isName ? TextAlign.right : TextAlign.center,
      );
      cRight = cLeft;
    }

    y += rowHeight;
  }

  // تذييل الصورة
  _drawCanvasText(
    canvas,
    text: 'تم استخراج قائمة النواقص آلياً — إجمالي الأصناف المطلوبة: ${rows.length}',
    x: pad,
    y: y + 14,
    maxWidth: tableWidth,
    fontSize: 12.5,
    fontWeight: FontWeight.w700,
    color: const Color(0xFF64748B),
    align: TextAlign.center,
  );

  final picture = recorder.endRecording();
  final img = await picture.toImage(width.toInt(), totalHeight.ceil());
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

void _drawCanvasText(
  Canvas canvas, {
  required String text,
  required double x,
  required double y,
  required double maxWidth,
  required double fontSize,
  required FontWeight fontWeight,
  required Color color,
  TextAlign align = TextAlign.right,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        fontFamily: 'Cairo',
      ),
    ),
    textDirection: TextDirection.rtl,
    textAlign: align,
    maxLines: 1,
    ellipsis: '…',
  )..layout(minWidth: maxWidth, maxWidth: maxWidth);
  tp.paint(canvas, Offset(x, y));
}

