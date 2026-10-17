// شبكة الأصناف في نقطة البيع (2026-09-24) — مربعات متساوية الأضلاع.
//
// • الجوال: 4 أصناف في الصف · التابلت: 6 · الحاسوب: 8 (ديناميكي حسب العرض).
// • الاسم والسعر بخطوط عريضة بارزة، السعر بالأخضر، وزر إضافة بلون متناسق.
// • رقم الترقيم السريع (PLU) **مخفي**: موجود في النموذج للبحث الرقمي فقط.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/media_paths.dart';
import '../core/models.dart';
import '../core/theme.dart';

/// بطاقة صنف مربّعة داخل شبكة نقطة البيع.
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
              // مساحة الصورة العلوية مع شارة التوفر ونجمة المفضلة.
              Expanded(
                flex: 5,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(
                      color: AppTone.blue.background,
                      width: double.infinity,
                      child: _buildThumb(context),
                    ),
                    // شارة التوفر والمخزون الثلاثية (أخضر / أصفر / أحمر).
                    PositionedDirectional(
                      top: 5,
                      end: 5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
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
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: tone.foreground,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 3.5),
                            Text(
                              statusLabel,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: tone.foreground,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // نجمة التثبيت في المفضلة.
                    if (isFavorite)
                      PositionedDirectional(
                        top: 5,
                        start: 5,
                        child: Container(
                          padding: const EdgeInsets.all(2.5),
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
                            size: 13,
                            color: Color(0xFFF59E0B),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // منطقة بيانات الصنف: الاسم مستقل تماماً في الأعلى، والسعر/المخزون وزر (+) في الصف السفلي دون أي تداخل.
              Expanded(
                flex: 5,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 5, 6, 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.topStart,
                          child: Text(
                            item.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.start,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                              height: 1.18,
                              color: AppColors.textOf(context),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: AlignmentDirectional.centerStart,
                                  child: Text(
                                    '${Fmt.money(price)} $symbol',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 13,
                                      color: isOut
                                          ? AppColors.dangerOf(context)
                                          : (isLow
                                              ? const Color(0xFFD97706)
                                              : AppColors.greenOf(context)),
                                    ),
                                  ),
                                ),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: AlignmentDirectional.centerStart,
                                  child: Text(
                                    '${Fmt.money(item.quantity)} ${item.unit}',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: isLow
                                          ? FontWeight.w700
                                          : FontWeight.normal,
                                      color: isLow
                                          ? const Color(0xFFD97706)
                                          : AppColors.text3Of(context),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 4),
                          // زر الإضافة مدمج في الركن السفلي بدون التداخل مع اسم الصنف.
                          Material(
                            color: enabled
                                ? AppColors.primaryOf(context)
                                : AppColors.text3Of(context),
                            borderRadius: BorderRadius.circular(10),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: enabled ? onAdd : null,
                              child: SizedBox(
                                height: 26,
                                child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 6),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.add,
                                          size: 14, color: Colors.white),
                                      if (inCart > 0) ...[
                                        const SizedBox(width: 2),
                                        Text(
                                          Fmt.money(inCart),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w900,
                                            fontSize: 11,
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
          size: 34,
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
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cross,
        // مربّع متساوي الأضلاع تقريباً.
        childAspectRatio: .94,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
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
