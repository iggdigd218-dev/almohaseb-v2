import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:flutter/services.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/pdf_fonts.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'trial_ui.dart' show FeatureGate;
import 'widgets.dart';
import 'trial_ui.dart' show featureNeedsStamp;
import '../data/sync/subscription_guard.dart' show Feature, kWatermarkText;

/// أنواع التقارير — نقل حرفي لـ `REPORT_TABS` في نسخة الويب.
enum ReportTab {
  summary('📋 ملخص إجمالي المبالغ'),
  detail('🧾 تفصيل العمليات'),
  categories('🗂️ التصنيفات'),
  period('🗓️ يومي/أسبوعي/شهري/سنوي'),
  account('👤 حسب عميل/مورد'),
  currency('💱 حسب العملة'),
  pl('📈 إيرادات ومصروفات'),
  topDebt('💸 أكثر الحسابات مديونية'),
  topActive('⚡ أكثر الحسابات نشاطًا'),
  overdue('⏰ تجاوز حد الائتمان');

  const ReportTab(this.label);
  final String label;
}

enum PeriodUnit {
  day('يومي'),
  week('أسبوعي'),
  month('شهري'),
  year('سنوي');

  const PeriodUnit(this.label);
  final String label;
}

final reportTabProvider = StateProvider<ReportTab>((ref) => ReportTab.summary);
final periodUnitProvider = StateProvider<PeriodUnit>((ref) => PeriodUnit.month);

/// البطاقات الإحصائية الأربع التفاعلية في شبكة (2×2) بشاشة التقارير.
enum ReportSummaryCard {
  sales('إجمالي المبيعات'),
  owedToUs('إجمالي المستحق لنا'),
  owedByUs('إجمالي المستحق علينا'),
  net('صافي الرصيد');

  const ReportSummaryCard(this.label);
  final String label;
}

final reportSelectedCardProvider = StateProvider<ReportSummaryCard?>(
  (ref) => null,
);

/// جدول التقرير الناتج: عناوين وصفوف نصية جاهزة للعرض والتصدير.
class ReportTable {
  final List<String> headers;
  final List<List<String>> rows;
  final List<(String, String)> summary;

  const ReportTable({
    required this.headers,
    required this.rows,
    this.summary = const [],
  });
}

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(reportTabProvider);
    final data = ref.watch(reportDataProvider);

    return Column(
      children: [
        const _ScopeBar(),
        const SizedBox(height: 4),
        Expanded(
          child: data.when(
            skipLoadingOnReload: true,
            skipLoadingOnRefresh: true,
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => EmptyState(
              icon: Icons.error_outline,
              title: 'تعذّر بناء التقرير',
              message: '$e',
            ),
            data: (d) {
              final currencies = ref.watch(currenciesProvider).valueOrNull ??
                  kDefaultCurrencies;
              final unit = ref.watch(periodUnitProvider);
              final selectedCard = ref.watch(reportSelectedCardProvider);
              final baseTable = buildReport(tab, d, currencies, unit);
              final effectiveTable =
                  (tab == ReportTab.summary && selectedCard != null)
                      ? buildCardDetailTable(
                          selectedCard,
                          d,
                          currencies,
                          baseSummary: baseTable.summary,
                        )
                      : baseTable;
              final view = _ReportView(
                tab: tab,
                table: effectiveTable,
                data: d,
                selectedCard: selectedCard,
              );
              // 🔒 (الخطة الفردية) تقرير التصنيفات ميزة مدفوعة — يبقى
              // ظاهراً بمؤشر القفل ويقود لشاشة الشراء.
              if (tab == ReportTab.categories) {
                return FeatureGate(
                  featureKey: 'categories',
                  featureName: 'التصنيفات',
                  description:
                      'صنّف حساباتك وأصنافك واستعرض تقارير مجمّعة لكل '
                      'تصنيف بضغطة واحدة.',
                  child: view,
                );
              }
              return view;
            },
          ),
        ),
      ],
    );
  }
}

/// (المتطلب 4-أ) شريط علوي واحد نظيف ومرتب يدمج بادج التاريخ مع بادج موحّد «تصفية وعرض» بدون قصّ للنصوص.
class _ScopeBar extends ConsumerWidget {
  const _ScopeBar();

  int _activeFilterCount(ReportScope s, ReportTab tab) {
    var count = 0;
    if (tab != ReportTab.summary) count++;
    if (s.currency != null) count++;
    if (s.accountId != null) count++;
    if (s.cashier != null) count++;
    return count;
  }

  Future<void> _openUnifiedFilterSheet(
    BuildContext context,
    WidgetRef ref,
    ReportScope s,
    ReportTab currentTab,
    List<Account> accounts,
    List<CurrencyDef> currencies,
  ) async {
    void setScope(ReportScope v) =>
        ref.read(reportScopeProvider.notifier).state = v;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) {
        return Consumer(
          builder: (ctx, rref, _) {
            final scope = rref.watch(reportScopeProvider);
            final tab = rref.watch(reportTabProvider);
            final unit = rref.watch(periodUnitProvider);
            final userList = rref.watch(usersProvider).valueOrNull ?? [];

            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.82,
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.tune_rounded,
                          color: AppColors.primaryOf(ctx),
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            ctx.tr('تصفية وعرض التقارير'),
                            style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            rref.read(reportTabProvider.notifier).state =
                                ReportTab.summary;
                            rref
                                .read(reportSelectedCardProvider.notifier)
                                .state = null;
                            setScope(
                              scope.copyWith(
                                clearCurrency: true,
                                clearAccount: true,
                                clearCashier: true,
                              ),
                            );
                            Navigator.pop(ctx);
                          },
                          child: Text(ctx.tr('إعادة ضبط')),
                        ),
                      ],
                    ),
                    const Divider(height: 16),
                    Text(
                      ctx.tr('نوع التقرير والتصنيفات'),
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.text2Of(ctx),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: ReportTab.values.map((t) {
                        final selected = tab == t;
                        return ChoiceChip(
                          selected: selected,
                          label: Text(
                            ctx.tr(t.label),
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: selected
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                          onSelected: (_) {
                            rref.read(reportTabProvider.notifier).state = t;
                            if (t != ReportTab.summary) {
                              rref
                                  .read(reportSelectedCardProvider.notifier)
                                  .state = null;
                            }
                          },
                        );
                      }).toList(),
                    ),
                    if (tab == ReportTab.period) ...[
                      const SizedBox(height: 14),
                      Text(
                        'وحدة تجميع الفترة',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: AppColors.text2Of(ctx),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: PeriodUnit.values.map((u) {
                          return ChoiceChip(
                            selected: unit == u,
                            label: Text(u.label),
                            onSelected: (_) => rref
                                .read(periodUnitProvider.notifier)
                                .state = u,
                          );
                        }).toList(),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Text(
                      'فترات سريعة',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.text2Of(ctx),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ActionChip(
                          label: const Text('اليوم'),
                          onPressed: () {
                            final n = DateTime.now();
                            setScope(
                              scope.copyWith(
                                from: DateTime(n.year, n.month, n.day),
                                to: DateTime(
                                    n.year, n.month, n.day, 23, 59, 59),
                              ),
                            );
                          },
                        ),
                        ActionChip(
                          label: const Text('هذا الشهر'),
                          onPressed: () {
                            final n = DateTime.now();
                            setScope(
                              scope.copyWith(
                                from: DateTime(n.year, n.month, 1),
                                to: DateTime(
                                    n.year, n.month, n.day, 23, 59, 59),
                              ),
                            );
                          },
                        ),
                        ActionChip(
                          label: const Text('آخر ٣٠ يومًا'),
                          onPressed: () {
                            final n = DateTime.now();
                            setScope(
                              scope.copyWith(
                                from: n.subtract(const Duration(days: 30)),
                                to: DateTime(
                                    n.year, n.month, n.day, 23, 59, 59),
                              ),
                            );
                          },
                        ),
                        ActionChip(
                          label: const Text('هذه السنة'),
                          onPressed: () {
                            final n = DateTime.now();
                            setScope(
                              scope.copyWith(
                                from: DateTime(n.year, 1, 1),
                                to: DateTime(n.year, 12, 31, 23, 59, 59),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    const Divider(height: 20),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.currency_exchange),
                      title: const Text(
                        'العملة',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(scope.currency ?? 'كل العملات'),
                      trailing: const Icon(Icons.chevron_left),
                      onTap: () async {
                        final v = await showModalBottomSheet<String>(
                          context: ctx,
                          builder: (_) => SafeArea(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ListTile(
                                  title: const Text('كل العملات'),
                                  onTap: () => Navigator.pop(ctx, ''),
                                ),
                                for (final c in currencies)
                                  ListTile(
                                    title: Text('${c.symbol}  ${c.name}'),
                                    onTap: () => Navigator.pop(ctx, c.code),
                                  ),
                              ],
                            ),
                          ),
                        );
                        if (v == null) return;
                        setScope(
                          v.isEmpty
                              ? scope.copyWith(clearCurrency: true)
                              : scope.copyWith(currency: v),
                        );
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_outline),
                      title: const Text(
                        'الحساب',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        scope.accountId == null
                            ? 'كل الحسابات'
                            : (accounts
                                    .where((a) => a.id == scope.accountId)
                                    .firstOrNull
                                    ?.name ??
                                'حساب'),
                      ),
                      trailing: const Icon(Icons.chevron_left),
                      onTap: () async {
                        final v = await showModalBottomSheet<int>(
                          context: ctx,
                          builder: (_) => SafeArea(
                            child: ListView(
                              shrinkWrap: true,
                              children: [
                                ListTile(
                                  title: const Text('كل الحسابات'),
                                  onTap: () => Navigator.pop(ctx, -1),
                                ),
                                for (final a in accounts)
                                  ListTile(
                                    title: Text('${a.kind.icon}  ${a.name}'),
                                    onTap: () => Navigator.pop(ctx, a.id),
                                  ),
                              ],
                            ),
                          ),
                        );
                        if (v == null) return;
                        setScope(
                          v == -1
                              ? scope.copyWith(clearAccount: true)
                              : scope.copyWith(accountId: v),
                        );
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.badge_outlined),
                      title: const Text(
                        'الكاشير / الموظف',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        scope.cashier == null
                            ? 'كل الكاشيرات'
                            : 'الكاشير: ${scope.cashier}',
                      ),
                      trailing: const Icon(Icons.chevron_left),
                      onTap: () async {
                        final v = await showModalBottomSheet<String>(
                          context: ctx,
                          builder: (_) => SafeArea(
                            child: ListView(
                              shrinkWrap: true,
                              children: [
                                ListTile(
                                  leading: const Icon(Icons.people_outline),
                                  title: const Text('كل الكاشيرات والموظفين'),
                                  onTap: () => Navigator.pop(ctx, ''),
                                ),
                                for (final u in userList)
                                  ListTile(
                                    leading:
                                        const Icon(Icons.person_pin_outlined),
                                    title: Text(u.name),
                                    subtitle: Text(
                                      '${u.role.label} • ${u.active ? "نشط" : "معطل"}',
                                    ),
                                    onTap: () => Navigator.pop(ctx, u.name),
                                  ),
                              ],
                            ),
                          ),
                        );
                        if (v == null) return;
                        setScope(
                          v.isEmpty
                              ? scope.copyWith(clearCashier: true)
                              : scope.copyWith(cashier: v),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('تطبيق الفلاتر والعرض'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(reportScopeProvider);
    final tab = ref.watch(reportTabProvider);
    final accounts = ref.watch(allAccountsProvider).valueOrNull ?? [];
    final currencies = ref.watch(currenciesProvider).valueOrNull ?? [];
    void set(ReportScope v) => ref.read(reportScopeProvider.notifier).state = v;
    final activeCount = _activeFilterCount(s, tab);

    return Container(
      color: AppColors.surfaceOf(context),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          // بادج الفترة الزمنية (التاريخ)
          Expanded(
            flex: 5,
            child: InkWell(
              key: const ValueKey('reports_date_range_badge'),
              borderRadius: BorderRadius.circular(12),
              onTap: () async {
                final r = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2015),
                  lastDate: DateTime(2100),
                  initialDateRange: DateTimeRange(start: s.from, end: s.to),
                );
                if (r != null) {
                  set(
                    s.copyWith(
                      from: DateTime(r.start.year, r.start.month, r.start.day),
                      to: DateTime(
                        r.end.year,
                        r.end.month,
                        r.end.day,
                        23,
                        59,
                        59,
                      ),
                    ),
                  );
                }
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.surface2Of(context),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.borderOf(context)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.date_range_rounded,
                      size: 16,
                      color: AppColors.primaryOf(context),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${Fmt.date(s.from)} → ${Fmt.date(s.to)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textOf(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // بادج «تصفية وعرض» الموحّد (نوع التقرير + التصنيفات + العملات + الحسابات)
          Expanded(
            flex: 4,
            child: InkWell(
              key: const ValueKey('reports_unified_filter_badge'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => _openUnifiedFilterSheet(
                context,
                ref,
                s,
                tab,
                accounts,
                currencies,
              ),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: activeCount > 0
                      ? AppColors.primarySoftOf(context)
                      : AppColors.surface2Of(context),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: activeCount > 0
                        ? AppColors.primaryOf(context)
                        : AppColors.borderOf(context),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.tune_rounded,
                      size: 16,
                      color: activeCount > 0
                          ? AppColors.primaryOf(context)
                          : AppColors.text2Of(context),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        activeCount > 0
                            ? '${context.tr('تصفية وعرض')} ($activeCount)'
                            : context.tr('تصفية وعرض'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: activeCount > 0
                              ? AppColors.primaryOf(context)
                              : AppColors.textOf(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// بناء جدول تفصيلي مخصص عند النقر على إحدى البطاقات الإحصائية الأربع في شبكة (2×2).
ReportTable buildCardDetailTable(
  ReportSummaryCard card,
  ReportData d,
  List<CurrencyDef> currencies, {
  List<(String, String)> baseSummary = const [],
}) {
  String sym(String code) => currencies
      .firstWhere(
        (c) => c.code == code,
        orElse: () => CurrencyDef(code, code, code, 0),
      )
      .symbol;
  String cname(String code) => currencies
      .firstWhere(
        (c) => c.code == code,
        orElse: () => CurrencyDef(code, code, code, 0),
      )
      .name;
  final byId = {for (final a in d.accounts) a.id!: a};

  switch (card) {
    case ReportSummaryCard.sales:
      final salesTxs = d.txs.where((t) {
        final isRet = t.description.trim().startsWith('مرتجع ') ||
            t.category == 'مرتجع مبيعات' ||
            t.notes.contains('[ORIG_TX:');
        final isSale = !isRet &&
            (t.type == OpType.revenue ||
                (t.type == OpType.debit &&
                    t.accountKind != AccountKind.supplier));
        return isSale || isRet;
      }).toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      return ReportTable(
        headers: const ['التاريخ', 'النوع', 'الحساب', 'البيان', 'المبلغ', 'العملة'],
        rows: salesTxs
            .map(
              (t) => [
                Fmt.date(t.date),
                t.type.label,
                t.resolvedPartyName(byId[t.accountId]),
                t.description.isEmpty ? t.type.label : t.description,
                Fmt.money(t.amount),
                sym(t.currency),
              ],
            )
            .toList(),
        summary: baseSummary,
      );

    case ReportSummaryCard.owedToUs:
      final debtors = d.accounts
          .where((a) => (d.balances[a.id!] ?? 0) > 0)
          .toList()
        ..sort(
          (a, b) => (d.balances[b.id!] ?? 0).compareTo(d.balances[a.id!] ?? 0),
        );
      return ReportTable(
        headers: const ['الحساب', 'النوع', 'المستحق لنا (عليه)', 'العملة'],
        rows: debtors
            .map(
              (a) => [
                '${a.kind.icon} ${a.name}',
                a.kind.label,
                Fmt.money(d.balances[a.id!] ?? 0),
                sym(a.currency),
              ],
            )
            .toList(),
        summary: baseSummary,
      );

    case ReportSummaryCard.owedByUs:
      final creditors = d.accounts
          .where((a) => (d.balances[a.id!] ?? 0) < 0)
          .toList()
        ..sort(
          (a, b) => (d.balances[a.id!] ?? 0).compareTo(d.balances[b.id!] ?? 0),
        );
      return ReportTable(
        headers: const ['الحساب', 'النوع', 'المستحق علينا (له)', 'العملة'],
        rows: creditors
            .map(
              (a) => [
                '${a.kind.icon} ${a.name}',
                a.kind.label,
                Fmt.money((d.balances[a.id!] ?? 0).abs()),
                sym(a.currency),
              ],
            )
            .toList(),
        summary: baseSummary,
      );

    case ReportSummaryCard.net:
      final per = <String, List<double>>{};
      for (final a in d.accounts) {
        final bal = d.balances[a.id!] ?? 0;
        final e = per.putIfAbsent(a.currency, () => [0, 0, 0]);
        if (bal > 0) {
          e[0] += bal;
        } else {
          e[1] += bal.abs();
        }
        e[2] += bal;
      }
      return ReportTable(
        headers: const ['العملة', 'مستحق لنا', 'مستحق علينا', 'الصافي'],
        rows: per.entries
            .map(
              (e) => [
                '${cname(e.key)} (${sym(e.key)})',
                Fmt.money(e.value[0]),
                Fmt.money(e.value[1]),
                Fmt.money(e.value[2]),
              ],
            )
            .toList(),
        summary: baseSummary,
      );
  }
}

/// يبني جدول التقرير المطلوب — منطق منقول من دوال `r*` في نسخة الويب.
ReportTable buildReport(
  ReportTab tab,
  ReportData d,
  List<CurrencyDef> currencies,
  PeriodUnit unit,
) {
  String sym(String code) => currencies
      .firstWhere(
        (c) => c.code == code,
        orElse: () => CurrencyDef(code, code, code, 0),
      )
      .symbol;
  String cname(String code) => currencies
      .firstWhere(
        (c) => c.code == code,
        orElse: () => CurrencyDef(code, code, code, 0),
      )
      .name;

  switch (tab) {
    case ReportTab.summary:
      final per = <String, List<double>>{}; // [مستحق لنا, علينا, الصافي]
      for (final a in d.accounts) {
        final bal = d.balances[a.id!] ?? 0;
        final e = per.putIfAbsent(a.currency, () => [0, 0, 0]);
        if (bal > 0) {
          e[0] += bal;
        } else {
          e[1] += bal.abs();
        }
        e[2] += bal;
      }
      var tRec = 0.0, tPay = 0.0, tNet = 0.0;
      final rows = per.entries.map((e) {
        tRec += e.value[0];
        tPay += e.value[1];
        tNet += e.value[2];
        return [
          '${cname(e.key)} (${sym(e.key)})',
          Fmt.money(e.value[0]),
          Fmt.money(e.value[1]),
          Fmt.money(e.value[2]),
        ];
      }).toList();
      var tSales = 0.0;
      for (final t in d.txs) {
        final isRet = t.description.trim().startsWith('مرتجع ') ||
            t.category == 'مرتجع مبيعات' ||
            t.notes.contains('[ORIG_TX:');
        final isSale = !isRet &&
            (t.type == OpType.revenue ||
                (t.type == OpType.debit &&
                    t.accountKind != AccountKind.supplier));
        if (isSale) {
          tSales += t.amount;
        } else if (isRet) {
          tSales -= t.amount;
        }
      }
      tSales = tSales.clamp(0.0, double.infinity);
      // (المتطلب 4-ب) 4 بطاقات إحصائية فقط (عدد العمليات مدمج كعنصر فرعي داخل إجمالي المبيعات).
      return ReportTable(
        headers: const ['العملة', 'مستحق لنا', 'مستحق علينا', 'الصافي'],
        rows: rows,
        summary: [
          ('إجمالي المبيعات', Fmt.money(tSales)),
          ('إجمالي المستحق لنا', Fmt.money(tRec)),
          ('إجمالي المستحق علينا', Fmt.money(tPay)),
          ('صافي الرصيد', Fmt.money(tNet)),
        ],
      );

    case ReportTab.detail:
      final byId = {for (final a in d.accounts) a.id!: a};
      final sorted = [...d.txs]..sort((a, b) => a.date.compareTo(b.date));
      return ReportTable(
        headers: const [
          'التاريخ',
          'النوع',
          'الحساب',
          'البيان',
          'المبلغ',
          'العملة',
          'المرجع',
        ],
        rows: sorted
            .map(
              (t) => [
                Fmt.date(t.date),
                t.type.label,
                t.type == OpType.transfer
                    ? 'تحويل'
                    : t.resolvedPartyName(byId[t.accountId]),
                t.description,
                Fmt.money(t.amount),
                sym(t.currency),
                t.reference,
              ],
            )
            .toList(),
      );

    case ReportTab.categories:
      final cat = <String, List<double>>{}; // [عدد, رصيد]
      for (final a in d.accounts) {
        final key = a.category.trim().isEmpty ? 'بدون تصنيف' : a.category;
        final e = cat.putIfAbsent(key, () => [0, 0]);
        e[0] += 1;
        e[1] += d.balances[a.id!] ?? 0;
      }
      return ReportTable(
        headers: const ['التصنيف', 'عدد الحسابات', 'إجمالي الرصيد'],
        rows: cat.entries
            .map((e) => [e.key, '${e.value[0].toInt()}', Fmt.money(e.value[1])])
            .toList(),
      );

    case ReportTab.period:
      final buckets = <String, List<double>>{};
      for (final t in d.txs) {
        final day = DateTime.utc(t.date.year, t.date.month, t.date.day);
        final key = switch (unit) {
          PeriodUnit.day => Fmt.date(t.date),
          PeriodUnit.week => Fmt.date(
              day.subtract(Duration(days: day.weekday % 7)),
            ),
          PeriodUnit.month =>
            '${t.date.year}/${t.date.month.toString().padLeft(2, '0')}',
          PeriodUnit.year => '${t.date.year}',
        };
        final e = buckets.putIfAbsent(key, () => [0, 0]);
        final g = opGroup(t.type);
        if (g == 'inflow') e[0] += t.amount;
        if (g == 'outflow') e[1] += t.amount;
      }
      final keys = buckets.keys.toList()..sort();
      return ReportTable(
        headers: const [
          'الفترة',
          'الإيرادات/القبض',
          'المصروفات/الصرف',
          'الصافي',
        ],
        rows: keys
            .map(
              (k) => [
                k,
                Fmt.money(buckets[k]![0]),
                Fmt.money(buckets[k]![1]),
                Fmt.money(buckets[k]![0] - buckets[k]![1]),
              ],
            )
            .toList(),
      );

    case ReportTab.account:
      return ReportTable(
        headers: const ['الحساب', 'النوع', 'عدد العمليات', 'الرصيد', 'العملة'],
        rows: d.accounts
            .map(
              (a) => [
                '${a.kind.icon} ${a.name}',
                a.kind.label,
                '${d.txCount[a.id!] ?? 0}',
                Fmt.money(d.balances[a.id!] ?? 0),
                sym(a.currency),
              ],
            )
            .toList(),
      );

    case ReportTab.currency:
      final per = <String, List<double>>{}; // [قبض, صرف, عدد]
      for (final t in d.txs) {
        final e = per.putIfAbsent(t.currency, () => [0, 0, 0]);
        final g = opGroup(t.type);
        if (g == 'inflow') e[0] += t.amount;
        if (g == 'outflow') e[1] += t.amount;
        e[2] += 1;
      }
      return ReportTable(
        headers: const [
          'العملة',
          'العمليات',
          'قبض/إيراد',
          'صرف/مصروف',
          'الصافي',
        ],
        rows: per.entries
            .map(
              (e) => [
                '${cname(e.key)} (${sym(e.key)})',
                '${e.value[2].toInt()}',
                Fmt.money(e.value[0]),
                Fmt.money(e.value[1]),
                Fmt.money(e.value[0] - e.value[1]),
              ],
            )
            .toList(),
      );

    case ReportTab.pl:
      var revenue = 0.0,
          expense = 0.0,
          receivable = 0.0,
          payable = 0.0,
          totalSales = 0.0;
      for (final t in d.txs) {
        final isRet = t.description.trim().startsWith('مرتجع ') ||
            t.category == 'مرتجع مبيعات' ||
            t.notes.contains('[ORIG_TX:');
        final isSale = !isRet &&
            (t.type == OpType.revenue ||
                (t.type == OpType.debit &&
                    t.accountKind != AccountKind.supplier));
        if (isSale) {
          totalSales += t.amount;
        } else if (isRet) {
          totalSales -= t.amount;
        }
        switch (t.type) {
          case OpType.revenue || OpType.inflow:
            revenue += t.amount;
          case OpType.expense || OpType.outflow:
            expense += t.amount;
          case OpType.debit:
            receivable += t.amount;
          case OpType.credit:
            payable += t.amount;
          default:
            break;
        }
      }
      totalSales = totalSales.clamp(0.0, double.infinity);
      final profit = revenue - expense;
      return ReportTable(
        headers: const ['البند', 'المبلغ'],
        rows: [
          ['إجمالي المبيعات', Fmt.money(totalSales)],
          ['إجمالي الإيرادات', Fmt.money(revenue)],
          ['إجمالي المصروفات', Fmt.money(expense)],
          ['صافي الأرباح / الخسائر', Fmt.money(profit)],
        ],
        summary: [
          ('إجمالي المبيعات', Fmt.money(totalSales)),
          ('الإيرادات', Fmt.money(revenue)),
          ('المصروفات', Fmt.money(expense)),
          ('صافي الربح/الخسارة', Fmt.money(profit)),
          ('ذمم مستحقة لنا', Fmt.money(receivable)),
          ('ذمم مستحقة علينا', Fmt.money(payable)),
        ],
      );

    case ReportTab.topDebt:
      final list = d.accounts
          .map((a) => (a, d.balances[a.id!] ?? 0))
          .where((x) => x.$2 > 0)
          .toList()
        ..sort((x, y) => y.$2.compareTo(x.$2));
      return ReportTable(
        headers: const ['#', 'الحساب', 'المبلغ المستحق لنا', 'العملة'],
        rows: list
            .take(20)
            .toList()
            .asMap()
            .entries
            .map(
              (e) => [
                '${e.key + 1}',
                '${e.value.$1.kind.icon} ${e.value.$1.name}',
                Fmt.money(e.value.$2),
                sym(e.value.$1.currency),
              ],
            )
            .toList(),
      );

    case ReportTab.topActive:
      final list = d.accounts
          .map((a) => (a, d.txCount[a.id!] ?? 0))
          .where((x) => x.$2 > 0)
          .toList()
        ..sort((x, y) => y.$2.compareTo(x.$2));
      return ReportTable(
        headers: const ['#', 'الحساب', 'عدد العمليات', 'الرصيد'],
        rows: list
            .take(20)
            .toList()
            .asMap()
            .entries
            .map(
              (e) => [
                '${e.key + 1}',
                '${e.value.$1.kind.icon} ${e.value.$1.name}',
                '${e.value.$2}',
                Fmt.money(d.balances[e.value.$1.id!] ?? 0),
              ],
            )
            .toList(),
      );

    case ReportTab.overdue:
      final rows = <List<String>>[];
      for (final a in d.accounts) {
        if (a.archived) continue;
        final limit = a.creditLimit;
        final bal = d.balances[a.id!] ?? 0;
        if (limit != null && limit > 0 && bal.abs() > limit) {
          rows.add([
            '${a.kind.icon} ${a.name}',
            Fmt.money(bal),
            Fmt.money(limit),
            Fmt.money(bal.abs() - limit),
            sym(a.currency),
          ]);
        }
      }
      return ReportTable(
        headers: const ['الحساب', 'الرصيد', 'حد الائتمان', 'التجاوز', 'العملة'],
        rows: rows,
      );
  }
}

class _ReportView extends ConsumerWidget {
  final ReportTab tab;
  final ReportTable table;
  final ReportData data;
  final ReportSummaryCard? selectedCard;
  const _ReportView({
    required this.tab,
    required this.table,
    required this.data,
    required this.selectedCard,
  });

  Widget _buildInteractiveSummaryGrid(BuildContext context, WidgetRef ref) {
    final map = {for (final e in table.summary) e.$1: e.$2};
    final salesVal = map['إجمالي المبيعات'] ?? '0';
    final owedToUsVal = map['إجمالي المستحق لنا'] ?? '0';
    final owedByUsVal = map['إجمالي المستحق علينا'] ?? '0';
    final netVal = map['صافي الرصيد'] ?? '0';
    final txCount = data.txs.length;

    void toggle(ReportSummaryCard c) {
      final cur = ref.read(reportSelectedCardProvider);
      ref.read(reportSelectedCardProvider.notifier).state =
          cur == c ? null : c;
    }

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _InteractiveReportCard(
                cardKey: const ValueKey('report_card_sales'),
                title: context.tr(ReportSummaryCard.sales.label),
                value: salesVal,
                subBadge: context.tr('عدد العمليات: $txCount'),
                icon: Icons.point_of_sale_rounded,
                color: const Color(0xFF10B981),
                selected: selectedCard == ReportSummaryCard.sales,
                onTap: () => toggle(ReportSummaryCard.sales),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _InteractiveReportCard(
                cardKey: const ValueKey('report_card_owed_to_us'),
                title: context.tr(ReportSummaryCard.owedToUs.label),
                value: owedToUsVal,
                icon: Icons.call_received_rounded,
                color: const Color(0xFF0284C7),
                selected: selectedCard == ReportSummaryCard.owedToUs,
                onTap: () => toggle(ReportSummaryCard.owedToUs),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _InteractiveReportCard(
                cardKey: const ValueKey('report_card_owed_by_us'),
                title: context.tr(ReportSummaryCard.owedByUs.label),
                value: owedByUsVal,
                icon: Icons.call_made_rounded,
                color: const Color(0xFFEF4444),
                selected: selectedCard == ReportSummaryCard.owedByUs,
                onTap: () => toggle(ReportSummaryCard.owedByUs),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _InteractiveReportCard(
                cardKey: const ValueKey('report_card_net'),
                title: context.tr(ReportSummaryCard.net.label),
                value: netVal,
                icon: Icons.account_balance_wallet_rounded,
                color: const Color(0xFF7C3AED),
                selected: selectedCard == ReportSummaryCard.net,
                onTap: () => toggle(ReportSummaryCard.net),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        if (tab == ReportTab.period)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: PeriodUnit.values
                  .map(
                    (u) => Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: ChoiceChip(
                        selected: ref.watch(periodUnitProvider) == u,
                        onSelected: (_) =>
                            ref.read(periodUnitProvider.notifier).state = u,
                        label: Text(u.label),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        Expanded(
          // (دفعة 58) سحب للأسفل = تحديث فوري للبيانات.
          child: RefreshIndicator(
            onRefresh: () async => bump(ref),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 96),
              children: [
                if (tab == ReportTab.summary) ...[
                  _buildInteractiveSummaryGrid(context, ref),
                  const SizedBox(height: 14),
                ] else if (table.summary.isNotEmpty) ...[
                  StatCardGrid(
                    children: table.summary
                        .map(
                          (e) => StatCard(
                            title: e.$1,
                            value: e.$2,
                            icon: Icons.analytics_outlined,
                            color: AppColors.primaryOf(context),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 14),
                ],
                if (table.rows.isEmpty)
                  EmptyState(
                    icon: Icons.bar_chart_outlined,
                    title: context.tr('لا بيانات في هذه الفترة'),
                    message: context.tr('وسّع الفترة أو غيّر المرشّحات.'),
                  )
                else
                  Card(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        headingRowHeight: 42,
                        dataRowMinHeight: 38,
                        dataRowMaxHeight: 48,
                        columns: table.headers
                            .map(
                              (h) => DataColumn(
                                label: Text(
                                  context.tr(h),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 12.5,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                        rows: table.rows
                            .map(
                              (r) => DataRow(
                                cells: r
                                    .map(
                                      (c) => DataCell(
                                        Text(
                                          c.isEmpty ? '—' : context.tr(c),
                                          style:
                                              const TextStyle(fontSize: 12.5),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: table.rows.isEmpty
                            ? null
                            : () async {
                                final stamp = await featureNeedsStamp(
                                    ref, Feature.reportsExport);
                                if (context.mounted) {
                                  await _exportPdf(context, tab, table,
                                      stamp: stamp);
                                }
                              },
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        label: Text(context.tr('تصدير PDF')),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: table.rows.isEmpty
                            ? null
                            : () => _copyCsv(context, table),
                        icon: const Icon(Icons.table_view_outlined),
                        label: Text(context.tr('نسخ CSV')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _copyCsv(BuildContext context, ReportTable t) async {
    final b = StringBuffer()..writeln(t.headers.join(','));
    for (final r in t.rows) {
      b.writeln(r.map((c) => '"${c.replaceAll('"', '""')}"').join(','));
    }
    await Clipboard.setData(ClipboardData(text: b.toString()));
    if (context.mounted) showSnack(context, 'تم نسخ التقرير بصيغة CSV ✅');
  }

  Future<void> _exportPdf(
    BuildContext context,
    ReportTab tab,
    ReportTable t, {
    bool stamp = false,
  }) async {
    // (2026-09-24) تحميل موحّد عبر خدمة الخطوط: مصدر واحد، تخزين مؤقت،
    // ورسالة خطأ صريحة إن تعذّر التحميل بدل PDF صامت بلا حروف عربية.
    final fonts = await PdfFonts.load();
    final regular = fonts.base;
    final bold = fonts.bold;

    final doc = pw.Document(
    // الثيم على المستند نفسه: يضمن الخط العربي لأي صفحة تُضاف لاحقاً
    // حتى لو لم تُعيّن pageTheme صراحةً.
    theme: fonts.theme,
  );
    doc.addPage(
      pw.MultiPage(
        // (دفعة 65-ب) طبقة خلفية على **كل** صفحة: ختم مائي مائل بنص
        // التطبيق، شفاف فلا يحجب الأرقام ويظهر في الطباعة والمشاركة معاً.
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          textDirection: pw.TextDirection.rtl,
          theme: pw.ThemeData.withFont(base: regular, bold: bold),
          margin: const pw.EdgeInsets.all(28),
          buildBackground: stamp
              ? (ctx) => pw.Watermark.text(
                    kWatermarkText,
                    angle: 0.6,
                    style: pw.TextStyle(
                      font: bold,
                      fontSize: 22,
                      color: const PdfColor(0.06, 0.46, 0.43, 0.12),
                    ),
                  )
              : null,
        ),
        build: (ctx) => [
          pw.Text(tab.label, style: pw.TextStyle(fontSize: 18, font: bold)),
          pw.SizedBox(height: 4),
          pw.Text(
            'تاريخ الإصدار: ${Fmt.dateTime(DateTime.now())}',
            style: const pw.TextStyle(
              fontSize: 9,
              color: PdfColor.fromInt(0xFF5B6B83),
            ),
          ),
          pw.SizedBox(height: 12),
          if (t.summary.isNotEmpty) ...[
            pw.Wrap(
              spacing: 8,
              runSpacing: 8,
              children: t.summary
                  .map(
                    (e) => pw.Container(
                      width: 120,
                      padding: const pw.EdgeInsets.all(8),
                      decoration: pw.BoxDecoration(
                        color: const PdfColor.fromInt(0xFFE8F0FF),
                        borderRadius: pw.BorderRadius.circular(6),
                      ),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text(e.$1, style: const pw.TextStyle(fontSize: 8)),
                          pw.SizedBox(height: 2),
                          pw.Text(
                            e.$2,
                            style: pw.TextStyle(fontSize: 12, font: bold),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
            pw.SizedBox(height: 14),
          ],
          pw.TableHelper.fromTextArray(
            headers: t.headers,
            data: t.rows,
            headerStyle: pw.TextStyle(font: bold, fontSize: 10),
            cellStyle: const pw.TextStyle(fontSize: 9),
            headerDecoration: const pw.BoxDecoration(
              color: PdfColor.fromInt(0xFFE8F0FF),
            ),
            cellAlignment: pw.Alignment.centerRight,
            border: pw.TableBorder.all(
              color: const PdfColor.fromInt(0xFFE2E8F2),
              width: .5,
            ),
          ),
        ],
      ),
    );

    await Printing.layoutPdf(
      onLayout: (_) => doc.save(),
      name: 'report-${tab.name}.pdf',
    );
  }
}

/// (المتطلب 4-ب) بطاقة إحصائية تفاعلية في شبكة (2×2) بشاشة التقارير:
/// تدعم النقر والتمييز بإطار واضح، وأيقونة ولون دلالي مميز، مع شارة فرعية لعدد العمليات.
class _InteractiveReportCard extends StatelessWidget {
  final Key? cardKey;
  final String title;
  final String value;
  final String? subBadge;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _InteractiveReportCard({
    this.cardKey,
    required this.title,
    required this.value,
    this.subBadge,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: selected
          ? color.withValues(alpha: isDark ? 0.18 : 0.08)
          : AppColors.surfaceOf(context),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: cardKey,
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? color : AppColors.borderOf(context),
              width: selected ? 2.0 : 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(icon, size: 17, color: color),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppColors.text2Of(context),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w900,
                        color: selected ? color : AppColors.textOf(context),
                      ),
                    ),
                  ),
                  if (subBadge != null) ...[
                    const SizedBox(width: 4),
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          subBadge!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            color: color,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

