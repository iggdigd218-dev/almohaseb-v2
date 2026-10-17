// شبكة الأصناف في نقطة البيع (2026-09-24) — بطاقات متجاوبة واضحة الأسعار والأسماء.
//
// • الجوال: 4 أصناف في الصف · التابلت: 6 · الحاسوب: 8 (ديناميكي حسب العرض).
// • اسم الصنف يظهر بوضوح تام على سطرين كحد أقصى دون تداخل مع زر الإضافة (+).
// • رقم الترقيم السريع (PLU) **مخفي**: موجود في النموذج للبحث الرقمي فقط.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/media_paths.dart';
import '../core/models.dart';
import '../core/theme.dart';

/// اسم بديل قياسي لبطاقة الصنف في شبكة نقطة البيع.
typedef PosItemCard = PosItemTile;

/// بطاقة صنف داخل شبكة نقطة البيع.
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

  Widget _buildThumb(BuildContext context) {
    if (item.image.isEmpty) return _fallback(context);
    if (item.image.startsWith('http')) {
      return Image.network(
        item.image,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _fallback(context),
      );
    }
    if (MediaPaths.exists(item.image)) {
      return Image.file(
        File(MediaPaths.toAbsolute(item.image)),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _fallback(context),
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

    // المؤشرات المرئية الثلاثية لحالة المخزون:
    // • أخضر (متوفر): الكمية أعلى من الحد الأدنى.
    // • أصفر/برتقالي (منخفض): الرصيد قارب الحد الأدنى.
    // • أحمر (نفد): الرصيد صفر أو أقل.
    final tone = isOut
        ? AppTone.red
        : (isLow ? AppTone.orange : AppTone.green);
    final statusLabel = isOut ? 'نفد' : (isLow ? 'منخفض' : 'متوفر');

    final scheme = Theme.of(context).colorScheme;

    return Opacity(
      opacity: enabled ? 1 : .55,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceOf(context),
          borderRadius: BorderRadius.circular(AppRadius.card),
          boxShadow: AppShadows.card(scheme),
          border: inCart > 0
              ? Border.all(color: AppColors.primaryOf(context), width: 2)
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onAdd : null,
          onLongPress: onLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1) الجزء العلوي: الصورة/الأيقونة + مؤشر المخزون + شارة الكمية + نجمة المفضلة.
              Expanded(
                flex: 4,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(
                      color: AppTone.blue.background,
                      width: double.infinity,
                      child: _buildThumb(context),
                    ),
                    // مؤشر حالة المخزون (أعلى اليسار في RTL).
                    PositionedDirectional(
                      top: 4,
                      end: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4.5, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceOf(context)
                              .withValues(alpha: .94),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                          border: Border.all(
                            color: tone.foreground.withValues(alpha: .35),
                            width: .8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 5.5,
                              height: 5.5,
                              decoration: BoxDecoration(
                                color: tone.foreground,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              statusLabel,
                              style: TextStyle(
                                fontSize: 8.5,
                                fontWeight: FontWeight.w800,
                                color: tone.foreground,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // شارة الكمية المتوفرة (أسفل اليمين على الصورة لتفريغ المساحة السفلية للاسم).
                    PositionedDirectional(
                      bottom: 4,
                      start: 4,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 72),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4.5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceOf(context)
                                .withValues(alpha: .92),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(
                              '${Fmt.money(item.quantity)} ${item.unit}',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight:
                                    isLow ? FontWeight.w800 : FontWeight.w600,
                                color: isOut
                                    ? AppColors.dangerOf(context)
                                    : (isLow
                                        ? const Color(0xFFD97706)
                                        : AppColors.text2Of(context)),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // نجمة التثبيت في المفضلة.
                    if (isFavorite)
                      PositionedDirectional(
                        top: 4,
                        start: 4,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceOf(context)
                                .withValues(alpha: .94),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color:
                                  const Color(0xFFF59E0B).withValues(alpha: .4),
                              width: .8,
                            ),
                          ),
                          child: const Icon(
                            Icons.star_rounded,
                            size: 12,
                            color: Color(0xFFF59E0B),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // 2) الجزء السفلي: اسم الصنف بعرض البطاقة الكامل (سطرين كحد أقصى) + شريط السعر وزر (+) المستقل.
              Expanded(
                flex: 6,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 5, 6, 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // اسم الصنف واضح ومقروء بالكامل دون أي تداخل مع الأزرار.
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.topStart,
                          child: Text(
                            item.name,
                            maxLines: 2,
                            softWrap: true,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.start,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                              height: 1.2,
                              color: AppColors.textOf(context),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      // شريط سفلي مخصص للسعر وزر الإضافة (+) دون المساس بمساحة الاسم.
                      SizedBox(
                        height: 24,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: AlignmentDirectional.centerStart,
                                child: Text(
                                  '${Fmt.money(price)} $symbol',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 12.5,
                                    color: isOut
                                        ? AppColors.dangerOf(context)
                                        : (isLow
                                            ? const Color(0xFFD97706)
                                            : AppColors.greenOf(context)),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Material(
                              color: enabled
                                  ? AppColors.primaryOf(context)
                                  : AppColors.text3Of(context),
                              borderRadius: BorderRadius.circular(8),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: enabled ? onAdd : null,
                                child: SizedBox(
                                  height: 24,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5.5),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.add,
                                            size: 13.5, color: Colors.white),
                                        if (inCart > 0) ...[
                                          const SizedBox(width: 2),
                                          Text(
                                            Fmt.money(inCart),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w900,
                                              fontSize: 10.5,
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
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fallback(BuildContext context) => Center(
        child: Icon(
          Icons.inventory_2_outlined,
          size: 28,
          color: AppTone.blue.foreground.withValues(alpha: .55),
        ),
      );
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

  /// عدد الأعمدة حسب عرض الشاشة: 4 · 6 · 8.
  static int crossAxisCountFor(double width) =>
      width >= 1000 ? 8 : (width >= 600 ? 6 : 4);

  @override
  Widget build(BuildContext context) {
    final cross = crossAxisCountFor(MediaQuery.sizeOf(context).width);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cross,
        // ارتفاع إضافي متوازن يمنح اسم الصنف (سطرين) مساحة مريحة دون اقتطاع.
        childAspectRatio: .70,
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
        );
      },
    );
  }
}
