// شبكة الأصناف في نقطة البيع (2026-09-24) — بطاقات متجاوبة واضحة الأسعار والأسماء.
//
// • الجوال: 4 أصناف في الصف · التابلت: 6 · الحاسوب: 8 (ديناميكي حسب العرض).
// • اسم الصنف يظهر بوضوح تام على سطرين كحد أقصى دون تداخل مع زر الإضافة (+).
// • رقم الترقيم السريع (PLU) **مخفي**: موجود في النموذج للبحث الرقمي فقط.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  String _rawQtyCount(double q) {
    if (q <= 0) return '0';
    return q == q.roundToDouble() ? q.toInt().toString() : Fmt.money(q, 2);
  }

  Widget _buildThumb(BuildContext context) {
    // (PR-8) حدة Retina: نكاش الصورة بكثافة بكسل الشاشة الفيزيائية
    // (منع البكسلة والتمدد) + جودة معالجة عالية داخل ClipRRect بقص
    // متناسق — بلا أي غباش.
    final thumbCacheWidth = crispCacheWidth(context, 160);
    if (item.image.isEmpty) return _fallback(context);
    if (item.image.startsWith('http')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox.expand(
          child: Image.network(
            item.image,
            fit: BoxFit.cover,
            cacheWidth: thumbCacheWidth,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => _fallback(context),
          ),
        ),
      );
    }
    if (MediaPaths.exists(item.image)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox.expand(
          child: Image.file(
            File(MediaPaths.toAbsolute(item.image)),
            fit: BoxFit.cover,
            cacheWidth: thumbCacheWidth,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => _fallback(context),
          ),
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

    final rawCount = _rawQtyCount(item.quantity);
    final statusLabel =
        isOut ? 'نفد 0' : (isLow ? 'منخفض $rawCount' : 'متوفر $rawCount');
    // (PR-8) شارات نقية مشرقة: أخضر تفاحي نضر للمتوفر، أحمر لطيف صريح
    // للنفاد، أصفر عنبري للمنخفض.
    final statusBg = isOut
        ? const Color(0xFFFEE2E2)
        : (isLow ? const Color(0xFFFEF3C7) : const Color(0xFFDCFCE7));
    final statusFg = isOut
        ? const Color(0xFFDC2626)
        : (isLow ? const Color(0xFFB45309) : const Color(0xFF16A34A));

    final scheme = Theme.of(context).colorScheme;
    // (PR-8) الأزرق الحيوي الصافي الموحد.
    const actionBlue = Color(0xFF2563EB);

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
          onTap: enabled
              ? () {
                  HapticFeedback.lightImpact();
                  onAdd();
                }
              : null,
          onLongPress: onLongPress,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(5, 5, 5, 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 1) منطقة الصورة أو الأيقونة الملونة ممتدة رأسياً بعد دمج الكمية في الشارة السفلية.
                    Expanded(
                      flex: 7,
                      child: _buildThumb(context),
                    ),
                    const SizedBox(height: 4),
                    // 2) اسم الصنف يظهر على سطرين لتمكين قراءة الاسم كاملاً والتفريق بين الأصناف.
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 26),
                      child: Center(
                        child: Text(
                          item.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            // (PR-8) اسم الصنف: فحم نقي (0F172A في الفاتح)
                            // بوزن واضح حاد — ويتكيف تلقائياً في الداكن.
                            fontWeight: FontWeight.w700,
                            fontSize: 10.5,
                            height: 1.15,
                            color: AppColors.textOf(context),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    // 3) الصف السفلي: شارة التوفر مع العدد كرقم مجرد يميناً + السعر بخط عريض يساراً.
                    SizedBox(
                      height: 18,
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: statusBg,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              statusLabel,
                              style: TextStyle(
                                fontSize: 8.0,
                                fontWeight: FontWeight.w800,
                                color: statusFg,
                              ),
                            ),
                          ),
                          const SizedBox(width: 3),
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: AlignmentDirectional.centerEnd,
                              child: Text(
                                '${Fmt.money(price)} $symbol',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 11.0,
                                  // (PR-8) سعر زمردي نضر للصنف المتاح.
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
              // شارة الزاوية العلوية اليسرى: تعرض (+) قبل الإضافة، وعند الإضافة تختفي (+) ويظهر العدد فقط بحجم مدمج لا يغطي الصورة.
              PositionedDirectional(
                top: 4,
                end: 4,
                child: Material(
                  color: enabled ? actionBlue : AppColors.text3Of(context),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                    side: const BorderSide(color: Colors.white, width: 1.2),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: enabled
                        ? () {
                            HapticFeedback.lightImpact();
                            onAdd();
                          }
                        : null,
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: 20,
                        minHeight: 20,
                      ),
                      padding: EdgeInsets.symmetric(
                        horizontal: inCart > 9 ? 4 : 0,
                      ),
                      alignment: Alignment.center,
                      child: inCart > 0
                          ? Text(
                              Fmt.money(inCart),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 10.5,
                                height: 1.0,
                              ),
                            )
                          : const Icon(
                              Icons.add_rounded,
                              size: 13,
                              color: Colors.white,
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
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: t.foreground.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Icon(
        _resolvedIcon,
        size: 28,
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
