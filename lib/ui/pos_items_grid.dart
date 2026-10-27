// شبكة الأصناف في نقطة البيع (2026-09-24) — بطاقات متجاوبة واضحة الأسعار والأسماء.
//
// • الجوال: 4 أصناف في الصف · التابلت: 6 · الحاسوب: 8 (ديناميكي حسب العرض).
// • اسم الصنف يظهر بوضوح تام على سطرين كحد أقصى دون تداخل مع زر الإضافة (+).
// • رقم الترقيم السريع (PLU) **مخفي**: موجود في النموذج للبحث الرقمي فقط.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/icon_catalog.dart';
import '../core/media_paths.dart';
import '../core/models.dart';
import '../core/theme.dart';

/// اسم بديل قياسي لبطاقة الصنف في شبكة نقطة البيع.
typedef PosItemCard = PosItemTile;

/// بطاقة صنف داخل شبكة نقطة البيع — مطابقة للتصميم المرجعي الحديث.
class PosItemTile extends StatelessWidget {
  const PosItemTile({
    super.key,
    required this.item,
    required this.symbol,
    required this.inCart,
    required this.enabled,
    required this.onAdd,
    this.onLongPress,
    this.isFavorite = false,
    this.tone,
    this.fallbackIcon,
  });

  final Item item;
  final String symbol;

  /// الكمية الموجودة حالياً في السلة (0 إن لم يُضف بعد).
  final double inCart;

  /// هل الإضافة مسموحة (نفاد المخزون يحظرها إلا بصلاحية البيع السالب).
  final bool enabled;
  final VoidCallback onAdd;
  final VoidCallback? onLongPress;
  final bool isFavorite;

  /// نغمة الباستيل المشتقة من فئة أو قسم الصنف (لتلوين الأيقونة البديلة عند غياب الصورة).
  final AppTone? tone;

  /// الأيقونة البديلة المشتقة من الفئة أو القسم عند غياب صورة الصنف.
  final IconData? fallbackIcon;

  AppTone get _resolvedTone =>
      tone ??
      IconCatalog.resolveTone(
        fallbackSeed: (item.categoryId ?? item.sectionId ?? item.id ?? item.name.hashCode),
      );

  IconData get _resolvedIcon => fallbackIcon ?? Icons.inventory_2_outlined;

  Widget _buildThumb(BuildContext context) {
    if (item.image.isEmpty) return _fallback(context);
    if (item.image.startsWith('http')) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
        child: Image.network(
          item.image,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => _fallback(context),
        ),
      );
    }
    if (MediaPaths.exists(item.image)) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
        child: Image.file(
          File(MediaPaths.toAbsolute(item.image)),
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => _fallback(context),
        ),
      );
    }
    return _fallback(context);
  }

  @override
  Widget build(BuildContext context) {
    final price = item.sellPrice > 0 ? item.sellPrice : item.buyPrice;
    final isOut = item.quantity <= 0;
    final isLow = !isOut &&
        (item.low || (item.minQuantity > 0 && item.quantity <= item.minQuantity));

    final statusLabel = isOut ? 'نفد' : (isLow ? 'منخفض' : 'متوفر');
    final statusBg = isOut
        ? const Color(0xFFFFE4E6)
        : (isLow ? const Color(0xFFFEF3C7) : const Color(0xFFE6F7F2));
    final statusFg = isOut
        ? const Color(0xFFE11D48)
        : (isLow ? const Color(0xFFD97706) : const Color(0xFF00897B));

    final scheme = Theme.of(context).colorScheme;
    const actionBlue = Color(0xFF1E88E5);

    return Opacity(
      opacity: enabled ? 1 : .58,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceOf(context),
          borderRadius: BorderRadius.circular(14),
          boxShadow: AppShadows.card(scheme),
          border: Border.all(
            color: inCart > 0 ? actionBlue : AppColors.borderOf(context),
            width: inCart > 0 ? 1.8 : 0.9,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onAdd : null,
          onLongPress: onLongPress,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 1) منطقة الصورة أو الأيقونة الملونة بتأثير الباستيل في النصف العلوي.
                    Expanded(
                      flex: 5,
                      child: Center(
                        child: _buildThumb(context),
                      ),
                    ),
                    const SizedBox(height: 3),
                    // 2) اسم الصنف عريض في المنتصف + الوحدة/الكمية تحته بالرمادي الهادئ.
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 11.5,
                        height: 1.15,
                        color: AppColors.textOf(context),
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '${Fmt.money(item.quantity)} ${item.unit}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.text3Of(context),
                      ),
                    ),
                    const SizedBox(height: 4),
                    // 3) الصف السفلي: شارة التوفر يميناً + السعر بخط عريض يساراً.
                    SizedBox(
                      height: 20,
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: statusBg,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              statusLabel,
                              style: TextStyle(
                                fontSize: 8.5,
                                fontWeight: FontWeight.w800,
                                color: statusFg,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: AlignmentDirectional.centerEnd,
                              child: Text(
                                '${Fmt.money(price)} $symbol',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 11.5,
                                  color: isOut
                                      ? AppColors.dangerOf(context)
                                      : const Color(0xFF059669),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // زر الإضافة الدائري الأزرق (+) في الزاوية العلوية اليسرى (end في RTL).
              PositionedDirectional(
                top: 5,
                end: 5,
                child: Material(
                  color: enabled ? actionBlue : AppColors.text3Of(context),
                  borderRadius: BorderRadius.circular(999),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: enabled ? onAdd : null,
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: 22,
                        minHeight: 22,
                      ),
                      padding: EdgeInsets.symmetric(
                        horizontal: inCart > 0 ? 5 : 0,
                      ),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.add_rounded,
                            size: 14,
                            color: Colors.white,
                          ),
                          if (inCart > 0) ...[
                            const SizedBox(width: 1),
                            Text(
                              Fmt.money(inCart),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 9.5,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fallback(BuildContext context) {
    final t = _resolvedTone;
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: t.foreground.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      child: Icon(
        _resolvedIcon,
        size: 24,
        color: t.foreground,
      ),
    );
  }
}

/// شبكة الأصناف المتجاوبة: 4 على الجوال · 6 على التابلت · 8 على الحاسوب.
class PosItemsGrid extends StatelessWidget {
  const PosItemsGrid({
    super.key,
    required this.items,
    required this.symbol,
    required this.quantityInCart,
    required this.canAdd,
    required this.onAdd,
    this.onLongPress,
    this.isFavorite,
    this.toneFor,
    this.iconFor,
  });

  final List<Item> items;
  final String symbol;

  /// كمية الصنف داخل السلة (لعرض العدّاد على البطاقة).
  final double Function(Item item) quantityInCart;

  /// هل يُسمح بإضافة هذا الصنف (المخزون أو صلاحية البيع السالب).
  final bool Function(Item item) canAdd;

  final void Function(Item item) onAdd;
  final void Function(Item item)? onLongPress;
  final bool Function(Item item)? isFavorite;
  final AppTone Function(Item item)? toneFor;
  final IconData Function(Item item)? iconFor;

  /// عدد الأعمدة حسب عرض الشاشة: 4 · 6 · 8.
  static int crossAxisCountFor(double width) =>
      width >= 1000 ? 8 : (width >= 600 ? 6 : 4);

  @override
  Widget build(BuildContext context) {
    final cross = crossAxisCountFor(MediaQuery.sizeOf(context).width);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 96),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cross,
        childAspectRatio: .72,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final it = items[i];
        return PosItemTile(
          item: it,
          symbol: symbol,
          inCart: quantityInCart(it),
          enabled: canAdd(it),
          onAdd: () => onAdd(it),
          onLongPress: onLongPress == null ? null : () => onLongPress!(it),
          isFavorite: isFavorite?.call(it) ?? false,
          tone: toneFor?.call(it),
          fallbackIcon: iconFor?.call(it),
        );
      },
    );
  }
}
