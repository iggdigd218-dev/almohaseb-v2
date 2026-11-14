import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import 'repository.dart';

/// مستوى الحصاد اليومي لتحديد النبرة التشجيعية المتفائلة.
enum DailyHarvestLevel {
  high,
  good,
  calm,
}

/// نتيجة تقييم ملخص المبيعات اليومية (الحصاد اليومي الذكي).
class DailyHarvestSummary {
  final String dateKey;
  final bool isManager;
  final int itemsCount;
  final double totalSales;
  final double previousDaySales;
  final int invoiceCount;
  final String currencySymbol;
  final int currencyDecimals;
  final DailyHarvestLevel level;
  final String title;
  final String message;

  const DailyHarvestSummary({
    required this.dateKey,
    required this.isManager,
    required this.itemsCount,
    required this.totalSales,
    required this.previousDaySales,
    required this.invoiceCount,
    required this.currencySymbol,
    required this.currencyDecimals,
    required this.level,
    required this.title,
    required this.message,
  });

  /// شرط الظهور الصارم: لا يظهر الإشعار إطلاقاً إذا لم تكن هناك أصناف
  /// أو كانت مبيعات اليوم تساوي صفراً (`totalSales <= 0`).
  bool get shouldShow =>
      itemsCount > 0 && totalSales > 0 && invoiceCount > 0;
}

/// خدمة إشعار ملخص المبيعات اليومية (داخلي + خارجي + سجل التنبيهات).
class DailyHarvestService {
  DailyHarvestService._();

  static const String kLastShownPrefsKey = 'daily_sales_summary.last_shown_date';

  static String formatDateKey(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';

  /// بناء النص التشجيعي المتفائل حسب مستوى المبيعات مقارنة باليوم السابق أو المتوسط.
  static (DailyHarvestLevel, String, String) buildEncouragingCopy({
    required double totalSales,
    required double previousDaySales,
    required int invoiceCount,
    required String formattedAmount,
    required bool isManager,
  }) {
    final DailyHarvestLevel level;
    if ((previousDaySales > 0 && totalSales > previousDaySales) ||
        (previousDaySales <= 0 && (totalSales >= 50000 || invoiceCount >= 8))) {
      level = DailyHarvestLevel.high;
    } else if ((previousDaySales > 0 && totalSales >= previousDaySales * 0.5) ||
        (previousDaySales <= 0 && (totalSales >= 10000 || invoiceCount >= 3))) {
      level = DailyHarvestLevel.good;
    } else {
      level = DailyHarvestLevel.calm;
    }

    final scopeLabel = isManager ? 'مبيعات اليوم' : 'حصيلة مبيعاتك اليوم';
    const unifiedTitle = 'إجمالي مبيعاتك اليومية';
    switch (level) {
      case DailyHarvestLevel.high:
        return (
          level,
          unifiedTitle,
          'إنجاز يومي مميز؛ وصلت $scopeLabel إلى $formattedAmount عبر $invoiceCount عملية.. خطوة رائعة نحو مزيد من النجاح والتقدم!',
        );
      case DailyHarvestLevel.good:
        return (
          level,
          unifiedTitle,
          'أداء يومي ممتاز؛ تحققت اليوم مبيعات بقيمة $formattedAmount عبر $invoiceCount عملية.. استمرارية متميزة وجهد مثمر!',
        );
      case DailyHarvestLevel.calm:
        return (
          level,
          unifiedTitle,
          'ملخص مبيعات اليوم بلغ $formattedAmount عبر $invoiceCount عملية.. كل عملية هي مكسب وثقة جديدة نحو غدٍ أكثر نجاحاً!',
        );
    }
  }

  /// تقييم مبيعات يوم محدد مع مراعاة صلاحية الجهاز (المدير يرى المنشأة كاملة، والعضو يرى مبيعاته فقط).
  static Future<DailyHarvestSummary> evaluate(
    Repo repo, {
    DateTime? date,
    bool? isManagerOverride,
  }) async {
    final target = date ?? DateTime.now();
    final dayStart = DateTime(target.year, target.month, target.day);
    final prevDayStart = dayStart.subtract(const Duration(days: 1));
    final dateKey = formatDateKey(dayStart);

    int itemsCount = 0;
    try {
      final allItems = await repo.items();
      itemsCount = allItems.where((it) => !it.archived).length;
    } catch (e) {
      debugPrint('DailyHarvestService.evaluate items error: $e');
    }

    bool isManager = true;
    if (isManagerOverride != null) {
      isManager = isManagerOverride;
    } else {
      try {
        final wsMode = await repo.workspaceMode();
        final isOwner = await repo.isWorkspaceOwner();
        final me = await repo.currentUser();
        if (wsMode == 'member') {
          isManager = false;
        } else if (me != null &&
            (me.role == UserRole.cashier ||
                me.role == UserRole.dataentry ||
                me.role == UserRole.viewer)) {
          isManager = false;
        } else {
          isManager = isOwner ||
              me == null ||
              me.role == UserRole.admin ||
              me.role == UserRole.agent;
        }
      } catch (e) {
        debugPrint('DailyHarvestService.evaluate role error: $e');
      }
    }

    CurrencyDef defaultCur = kDefaultCurrencies.first;
    try {
      final curs = await repo.currencies();
      final st = await repo.settings();
      final defCode = (st['defaultCurrency'] ?? 'YER').trim();
      if (curs.isNotEmpty) {
        defaultCur = curs.firstWhere(
          (c) => c.code == defCode,
          orElse: () => curs.first,
        );
      }
    } catch (e) {
      debugPrint('DailyHarvestService.evaluate currency error: $e');
    }

    if (itemsCount <= 0) {
      return DailyHarvestSummary(
        dateKey: dateKey,
        isManager: isManager,
        itemsCount: 0,
        totalSales: 0,
        previousDaySales: 0,
        invoiceCount: 0,
        currencySymbol: defaultCur.symbol,
        currencyDecimals: defaultCur.decimal,
        level: DailyHarvestLevel.calm,
        title: '',
        message: '',
      );
    }

    List<Tx> allTxs = const [];
    Map<int, String> txOpDeviceMap = const {};
    int? myUserId;
    String myUserName = '';
    String myDeviceId = repo.deviceId ?? '';
    String myDeviceName = '';

    try {
      allTxs = await repo.transactions();
      final me = await repo.currentUser();
      myUserId = me?.id;
      myUserName = (me?.name ?? '').trim();
      final st = await repo.settings();
      if (myDeviceId.isEmpty) {
        myDeviceId = (st['sync.deviceId'] ?? '').trim();
      }
      myDeviceName = (st['sync.deviceName'] ?? '').trim();

      if (!isManager) {
        final db = await repo.database;
        final opRows = await db.query(
          'operations',
          columns: ['entity_id', 'device_id'],
          where: "entity_type = 'tx'",
        );
        final map = <int, String>{};
        for (final r in opRows) {
          final tid = int.tryParse('${r['entity_id'] ?? ''}');
          final did = '${r['device_id'] ?? ''}'.trim();
          if (tid != null && did.isNotEmpty) {
            map[tid] = did;
          }
        }
        txOpDeviceMap = map;
      }
    } catch (e) {
      debugPrint('DailyHarvestService.evaluate tx fetch error: $e');
    }

    bool belongsToScope(Tx t) {
      if (isManager) return true;
      // في جهاز العضو (الموظف/الكاشير): يعرض حصيلة مبيعات هذا العضو/الجهاز فقط
      if (t.id != null && txOpDeviceMap.containsKey(t.id)) {
        return myDeviceId.isNotEmpty && txOpDeviceMap[t.id] == myDeviceId;
      }
      if (t.createdByUserId != null && myUserId != null) {
        return t.createdByUserId == myUserId;
      }
      final cName = t.cashierName.trim();
      if (cName.isNotEmpty) {
        if (myUserName.isNotEmpty && cName == myUserName) return true;
        if (myDeviceName.isNotEmpty && cName == myDeviceName) return true;
        return false;
      }
      return t.createdByUserId == null;
    }

    bool isSameCalendarDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;

    double todaySales = 0.0;
    int todayInvoices = 0;
    double prevSales = 0.0;

    for (final t in allTxs) {
      if (!belongsToScope(t)) continue;
      final desc = t.description.trim();
      if (desc.startsWith('دفعة مقدمة من فاتورة')) continue;
      final isRet = desc.startsWith('مرتجع ') ||
          t.category == 'مرتجع مبيعات' ||
          t.notes.contains('[ORIG_TX:');
      final isSale = !isRet &&
          (t.type == OpType.revenue ||
              (t.type == OpType.debit &&
                  t.accountKind != AccountKind.supplier));
      if (!isSale && !isRet) continue;

      if (isSameCalendarDay(t.date, dayStart)) {
        if (isSale) {
          todaySales += t.amount;
          todayInvoices++;
        } else if (isRet) {
          todaySales -= t.amount;
        }
      } else if (isSameCalendarDay(t.date, prevDayStart)) {
        if (isSale) {
          prevSales += t.amount;
        } else if (isRet) {
          prevSales -= t.amount;
        }
      }
    }

    todaySales = todaySales.clamp(0.0, double.infinity);
    prevSales = prevSales.clamp(0.0, double.infinity);

    if (todaySales <= 0 || todayInvoices <= 0) {
      return DailyHarvestSummary(
        dateKey: dateKey,
        isManager: isManager,
        itemsCount: itemsCount,
        totalSales: 0,
        previousDaySales: prevSales,
        invoiceCount: 0,
        currencySymbol: defaultCur.symbol,
        currencyDecimals: defaultCur.decimal,
        level: DailyHarvestLevel.calm,
        title: '',
        message: '',
      );
    }

    final formattedAmount =
        '${Fmt.money(todaySales, defaultCur.decimal)} ${defaultCur.symbol}';
    final (level, title, message) = buildEncouragingCopy(
      totalSales: todaySales,
      previousDaySales: prevSales,
      invoiceCount: todayInvoices,
      formattedAmount: formattedAmount,
      isManager: isManager,
    );

    return DailyHarvestSummary(
      dateKey: dateKey,
      isManager: isManager,
      itemsCount: itemsCount,
      totalSales: todaySales,
      previousDaySales: prevSales,
      invoiceCount: todayInvoices,
      currencySymbol: defaultCur.symbol,
      currencyDecimals: defaultCur.decimal,
      level: level,
      title: title,
      message: message,
    );
  }

  /// يفحص ويُصدر إشعار الحصاد اليومي (في جدول notifications بالعمود `seen` + إشعار نظام خارجي).
  /// يعيد [DailyHarvestSummary] إذا تم إصدار الإشعار ليتم عرضه في نافذة منبثقة داخل التطبيق،
  /// أو `null` إذا كانت المبيعات صفراً أو لا توجد أصناف أو سبق عرضه لنفس اليوم.
  static Future<DailyHarvestSummary?> checkAndNotify(
    Repo repo, {
    DateTime? date,
    bool force = false,
    bool? isManagerOverride,
    bool enforceEndOfDay = false,
  }) async {
    final target = date ?? DateTime.now();
    // عند التفعيل التلقائي من الواجهة (enforceEndOfDay = true): لا تظهر إلا في نهاية اليوم (بعد الساعة 6 مساءً)
    if (enforceEndOfDay && !force && target.hour < 18) {
      return null;
    }

    final summary = await evaluate(
      repo,
      date: target,
      isManagerOverride: isManagerOverride,
    );
    if (!summary.shouldShow) return null;

    final roleKey = summary.isManager ? 'manager' : 'member';
    final settingKey = 'daily_harvest.shown.${summary.dateKey}.$roleKey';
    final prefsKey = '$kLastShownPrefsKey.$roleKey';

    if (!force) {
      try {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getString(prefsKey) == summary.dateKey) {
          return null;
        }
      } catch (e) {
        debugPrint('DailyHarvestService.checkAndNotify prefs read error: $e');
      }
      try {
        final already = await repo.getSetting(settingKey);
        if (already == '1') return null;
      } catch (e) {
        debugPrint('DailyHarvestService.checkAndNotify getSetting error: $e');
      }
    }

    try {
      await repo.notify(
        title: summary.title,
        body: summary.message,
        kind: 'daily_harvest',
        entityType: 'daily_harvest',
        entityId: summary.dateKey,
      );
      await repo.setSetting(settingKey, '1');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, summary.dateKey);
    } catch (e) {
      debugPrint('DailyHarvestService.checkAndNotify notify error: $e');
    }

    try {
      await Sfx.systemNotify(
        title: summary.title,
        body: summary.message,
        entityType: 'daily_harvest',
        entityId: summary.dateKey,
      );
    } catch (e) {
      debugPrint('DailyHarvestService.checkAndNotify systemNotify error: $e');
    }

    return summary;
  }

  /// عرض نافذة منبثقة أنيقة داخل التطبيق لملخص الحصاد اليومي.
  static Future<void> showHarvestDialog(
    BuildContext context,
    DailyHarvestSummary summary,
  ) async {
    if (!context.mounted || !summary.shouldShow) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = switch (summary.level) {
      DailyHarvestLevel.high => const Color(0xFF10B981),
      DailyHarvestLevel.good => const Color(0xFF0284C7),
      DailyHarvestLevel.calm => const Color(0xFF8B5CF6),
    };
    final icon = switch (summary.level) {
      DailyHarvestLevel.high => Icons.emoji_events_rounded,
      DailyHarvestLevel.good => Icons.workspace_premium_rounded,
      DailyHarvestLevel.calm => Icons.wb_sunny_rounded,
    };

    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: isDark ? 0.22 : 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: accent, size: 34),
                ),
                const SizedBox(height: 14),
                Text(
                  summary.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: isDark ? 0.18 : 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${Fmt.money(summary.totalSales, summary.currencyDecimals)} ${summary.currencySymbol} • ${summary.invoiceCount} عملية',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: accent,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  summary.message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.6,
                    color: AppColors.text2Of(ctx),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text(
                      'إغلاق',
                      style: TextStyle(fontWeight: FontWeight.w800),
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
