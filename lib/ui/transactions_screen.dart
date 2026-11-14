import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/thermal_invoice_doc.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/sync/subscription_guard.dart' show Feature;
import 'tx_form.dart';
import 'trial_ui.dart' show ensureFeatureUnlocked, featureNeedsStamp;
import 'tx_share.dart';
import 'widgets.dart';

class TransactionsScreen extends ConsumerWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(txPageProvider);
    final hidden = ref.watch(hideBalancesProvider);
    // (قانون 2026-09-19) زر «إضافة عملية» صريح داخل الشاشة نفسها.
    final me = ref.watch(currentUserProvider).valueOrNull;
    final canAdd = me != null && me.can('add_tx');

    return Column(
      children: [
        const _TxFilterBar(),
        if (canAdd)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                onPressed: () => openTxForm(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: Text(context.tr('إضافة عملية')),
              ),
            ),
          ),
        Expanded(
          child: page.when(
            skipLoadingOnReload: true,
            skipLoadingOnRefresh: true,
            loading: () => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(context.tr('جارٍ تحميل العمليات…')),
                  ],
                ),
              ),
            ),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    EmptyState(
                      icon: Icons.error_outline,
                      title: context.tr('تعذّر تحميل العمليات'),
                      message:
                          '$e'.length > 200 ? '${'$e'.substring(0, 200)}…' : '$e',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => bump(ref),
                      icon: const Icon(Icons.refresh),
                      label: Text(context.tr('إعادة المحاولة')),
                    ),
                  ],
                ),
              ),
            ),
            data: (p) {
              if (p.items.isEmpty) {
                return EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: context.tr('لا توجد عمليات مطابقة'),
                  message: context.tr('غيّر معايير البحث أو سجّل عملية جديدة.'),
                  action: canAdd
                      ? FilledButton.icon(
                          onPressed: () => openTxForm(context, ref),
                          icon: const Icon(Icons.add),
                          label: Text(context.tr('إضافة عملية')),
                        )
                      : null,
                );
              }
              // (دفعة 58) سحب للأسفل = إعادة تحميل + مزامنة فورية.
              return RefreshIndicator(
                onRefresh: () async => bump(ref),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 96),
                  itemCount: p.items.length + 1,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    if (i == 0) return _Totals(page: p, hidden: hidden);
                    final idx = i - 1;
                    final t = p.items[idx];
                    final txId = t.id;
                    return _TxCard(
                      index: idx,
                      tx: t,
                      account: t.type == OpType.transfer
                          ? p.accounts[t.fromId]
                          : p.accounts[t.accountId],
                      toAccount: p.accounts[t.toId],
                      hidden: hidden,
                      itemsSummary:
                          (txId != null ? p.itemsSummaryByTxId[txId] : null) ??
                              '',
                      executorName:
                          (txId != null ? p.executorByTxId[txId] : null) ??
                              t.cashierName,
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// شريط البحث والمرشّحات — يطابق أدوات نسخة الويب.
class _TxFilterBar extends ConsumerStatefulWidget {
  const _TxFilterBar();

  @override
  ConsumerState<_TxFilterBar> createState() => _TxFilterBarState();
}

class _TxFilterBarState extends ConsumerState<_TxFilterBar> {
  late final TextEditingController _q;

  @override
  void initState() {
    super.initState();
    _q = TextEditingController(text: ref.read(txFilterProvider).query);
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  void _set(TxFilter f) => ref.read(txFilterProvider.notifier).state = f;

  @override
  Widget build(BuildContext context) {
    final f = ref.watch(txFilterProvider);
    final accounts = ref.watch(allAccountsProvider).valueOrNull ?? [];
    final currencies = ref.watch(currenciesProvider).valueOrNull ?? [];

    return Container(
      color: AppColors.surfaceOf(context),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        children: [
          TextField(
            controller: _q,
            decoration: InputDecoration(
              hintText: context.tr('بحث بالبيان أو المرجع أو الحساب...'),
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              suffixIcon: f.query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _q.clear();
                        _set(f.copyWith(query: ''));
                      },
                    ),
            ),
            onChanged: (v) => _set(f.copyWith(query: v)),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final ok = await ensureFeatureUnlocked(context, ref,
                        featureKey: 'advanced_search',
                        featureName: context.tr('البحث الشامل المتقدم'),
                        description:
                            'فلترة عميقة بالحساب والعملة والنوع والفترة '
                            'الزمنية للوصول لأي عملية في ثوانٍ.');
                    if (ok) _openFilters(f, accounts, currencies);
                  },
                  icon: Icon(
                    Icons.tune,
                    size: 18,
                    color: f.isActive
                        ? AppColors.primaryOf(context)
                        : AppColors.text2Of(context),
                  ),
                  label: Text(
                    f.isActive
                        ? '${context.tr('الفلاتر مفعّلة')} (${_activeCount(f)})'
                        : context.tr('تصفية وبحث متقدّم'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: f.isActive
                          ? AppColors.primaryOf(context)
                          : AppColors.text2Of(context),
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: f.isActive
                          ? AppColors.primaryOf(context)
                          : AppColors.borderOf(context),
                    ),
                    backgroundColor: f.isActive
                        ? AppColors.primarySoftOf(context)
                        : AppColors.surface2Of(context),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              if (f.isActive) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: context.tr('مسح كل الفلاتر'),
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 20),
                  color: AppColors.dangerOf(context),
                  onPressed: () {
                    _q.clear();
                    _set(const TxFilter());
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickType(TxFilter f) async {
    final v = await showModalBottomSheet<Object>(
      context: context,
      builder: (_) => _SheetList(
        title: 'نوع العملية',
        items: [
          const _SheetItem(value: '', label: 'كل الأنواع'),
          ...OpType.values.map(
            (t) => _SheetItem(value: t, label: '${t.icon}  ${t.label}'),
          ),
        ],
      ),
    );
    if (v == null) return;
    _set(v is OpType ? f.copyWith(type: v) : f.copyWith(clearType: true));
  }

  Future<void> _pickAccount(TxFilter f, List<Account> accounts) async {
    final v = await showModalBottomSheet<Object>(
      context: context,
      builder: (_) => _SheetList(
        title: 'الحساب',
        items: [
          const _SheetItem(value: '', label: 'كل الحسابات'),
          ...accounts.map(
            (a) => _SheetItem(value: a.id!, label: '${a.kind.icon}  ${a.name}'),
          ),
        ],
      ),
    );
    if (v == null) return;
    _set(v is int ? f.copyWith(accountId: v) : f.copyWith(clearAccount: true));
  }

  Future<void> _pickCurrency(TxFilter f, List<CurrencyDef> curs) async {
    final v = await showModalBottomSheet<Object>(
      context: context,
      builder: (_) => _SheetList(
        title: 'العملة',
        items: [
          const _SheetItem(value: '', label: 'كل العملات'),
          ...curs.map(
            (c) => _SheetItem(value: c.code, label: '${c.symbol}  ${c.name}'),
          ),
        ],
      ),
    );
    if (v == null) return;
    _set(
      v is String && v.isNotEmpty
          ? f.copyWith(currency: v)
          : f.copyWith(clearCurrency: true),
    );
  }

  Future<void> _pickSort(TxFilter f) async {
    final v = await showModalBottomSheet<Object>(
      context: context,
      builder: (_) => _SheetList(
        title: 'الترتيب',
        items: TxSort.values
            .map((s) => _SheetItem(value: s, label: s.label))
            .toList(),
      ),
    );
    if (v is TxSort) _set(f.copyWith(sort: v));
  }

  Future<void> _pickRange(TxFilter f) async {
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2015),
      lastDate: DateTime(2100),
      initialDateRange: f.from != null && f.to != null
          ? DateTimeRange(start: f.from!, end: f.to!)
          : null,
    );
    if (r == null) return;
    _set(
      f.copyWith(
        from: DateTime(r.start.year, r.start.month, r.start.day),
        to: DateTime(r.end.year, r.end.month, r.end.day, 23, 59, 59),
      ),
    );
  }

  /// عدد الفلاتر المفعّلة حالياً (يظهر على زر التصفية).
  int _activeCount(TxFilter f) {
    var n = 0;
    if (f.type != null) n++;
    if (f.accountId != null) n++;
    if (f.currency != null) n++;
    if (f.from != null || f.to != null) n++;
    if (f.sort != TxSort.newest) n++;
    return n;
  }

  String _accountLabel(TxFilter f, List<Account> accounts) =>
      f.accountId == null
          ? 'كل الحسابات'
          : (accounts.where((a) => a.id == f.accountId).firstOrNull?.name ??
              'حساب محدد');

  String _rangeLabel(TxFilter f) => f.from == null && f.to == null
      ? 'كل الفترات'
      : '${f.from != null ? Fmt.date(f.from!) : '…'} → ${f.to != null ? Fmt.date(f.to!) : '…'}';

  /// نافذة واحدة تجمع كل خيارات الفلترة (النوع/الحساب/العملة/الفترة/الترتيب/مسح).
  Future<void> _openFilters(
    TxFilter f,
    List<Account> accounts,
    List<CurrencyDef> currencies,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        Widget tile(
          IconData icon,
          String title,
          String value,
          VoidCallback onTap, {
          bool active = false,
        }) {
          return ListTile(
            leading: Icon(
              icon,
              color: active
                  ? AppColors.primaryOf(sheetCtx)
                  : AppColors.text2Of(sheetCtx),
            ),
            title: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(value),
            trailing: const Icon(
              Icons.chevron_left,
              color: Colors.grey,
              size: 22,
            ),
            onTap: () {
              Navigator.pop(sheetCtx);
              onTap();
            },
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'تصفية العمليات',
                  style: Theme.of(sheetCtx).textTheme.titleMedium,
                ),
              ),
              const Divider(height: 1),
              tile(
                Icons.category_outlined,
                'نوع العملية',
                f.type?.label ?? 'كل الأنواع',
                () => _pickType(f),
                active: f.type != null,
              ),
              tile(
                Icons.people_alt_outlined,
                'الحساب',
                _accountLabel(f, accounts),
                () => _pickAccount(f, accounts),
                active: f.accountId != null,
              ),
              tile(
                Icons.currency_exchange,
                'العملة',
                f.currency ?? 'كل العملات',
                () => _pickCurrency(f, currencies),
                active: f.currency != null,
              ),
              tile(
                Icons.date_range_outlined,
                'الفترة الزمنية',
                _rangeLabel(f),
                () => _pickRange(f),
                active: f.from != null || f.to != null,
              ),
              tile(
                Icons.sort,
                'الترتيب',
                f.sort.label,
                () => _pickSort(f),
                active: f.sort != TxSort.newest,
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(
                  Icons.filter_alt_off_outlined,
                  color: AppColors.dangerOf(sheetCtx),
                ),
                title: Text(
                  'مسح كل الفلاتر',
                  style: TextStyle(
                    color: AppColors.dangerOf(sheetCtx),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                enabled: f.isActive,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _q.clear();
                  _set(const TxFilter());
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

class _SheetItem {
  final Object value;
  final String label;
  const _SheetItem({required this.value, required this.label});
}

class _SheetList extends StatelessWidget {
  final String title;
  final List<_SheetItem> items;
  const _SheetList({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              context.tr(title),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: items.length,
              itemBuilder: (context, i) => ListTile(
                title: Text(context.tr(items[i].label)),
                onTap: () => Navigator.pop(context, items[i].value),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _Totals extends ConsumerWidget {
  final TxPage page;
  final bool hidden;
  const _Totals({required this.page, required this.hidden});

  Future<void> _pickPeriod(
    BuildContext context,
    WidgetRef ref,
    TxTotalsPeriod current,
  ) async {
    final chosen = await showModalBottomSheet<TxTotalsPeriod>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Text(
                'فترة إجماليات (وارد / صادر)',
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ),
            const Divider(height: 1),
            for (final p in TxTotalsPeriod.values)
              ListTile(
                leading: Icon(
                  p == current
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: p == current
                      ? AppColors.primaryOf(ctx)
                      : AppColors.text3Of(ctx),
                ),
                title: Text(
                  p.label,
                  style: TextStyle(
                    fontWeight:
                        p == current ? FontWeight.w800 : FontWeight.w600,
                    color: p == current
                        ? AppColors.primaryOf(ctx)
                        : AppColors.textOf(ctx),
                  ),
                ),
                onTap: () => Navigator.pop(ctx, p),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen != null && chosen != current) {
      ref.read(txTotalsPeriodProvider.notifier).state = chosen;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(txTotalsPeriodProvider);
    final rawCodes = {
      ...page.inflowByCurrency.keys,
      ...page.outflowByCurrency.keys,
    }.toList();
    final codes = rawCodes.isEmpty ? const <String>['YER'] : rawCodes;

    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Column(
        children: [
          for (final code in codes) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: StatCard(
                      title:
                          '${context.tr('وارد')} ($code) • ${context.tr(period.label)}',
                      value: hidden
                          ? '••••'
                          : Fmt.money(page.inflowByCurrency[code] ?? 0),
                      icon: Icons.south_west,
                      color: AppColors.greenOf(context),
                      onTap: () => _pickPeriod(context, ref, period),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatCard(
                      title:
                          '${context.tr('صادر')} ($code) • ${context.tr(period.label)}',
                      value: hidden
                          ? '••••'
                          : Fmt.money(page.outflowByCurrency[code] ?? 0),
                      icon: Icons.north_east,
                      color: AppColors.dangerOf(context),
                      onTap: () => _pickPeriod(context, ref, period),
                    ),
                  ),
                ],
              ),
            ),
          ],
          Row(
            children: [
              Text(
                context.tr('${page.items.length} عملية'),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text2Of(context),
                ),
              ),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _pickPeriod(context, ref, period),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.calendar_today_rounded,
                        size: 13,
                        color: AppColors.primaryOf(context),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${context.tr('الفترة')}: ${context.tr(period.label)}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryOf(context),
                        ),
                      ),
                    ],
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

class _TxCard extends ConsumerWidget {
  final int index;
  final Tx tx;
  final Account? account;
  final Account? toAccount;
  final bool hidden;
  final String itemsSummary;
  final String executorName;
  const _TxCard({
    this.index = 0,
    required this.tx,
    required this.account,
    required this.toAccount,
    required this.hidden,
    this.itemsSummary = '',
    this.executorName = '',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTransfer = tx.type == OpType.transfer;
    final group = opGroup(tx.type);
    final color = switch (group) {
      'inflow' => AppColors.greenOf(context),
      'outflow' => AppColors.dangerOf(context),
      'receivable' => AppColors.infoOf(context),
      'payable' => AppColors.accentOf(context),
      _ => AppColors.violetOf(context),
    };

    final cashCustomer = context.tr('عميل نقدي');
    final customCustName = tx.customCustomerName ?? '';
    final defaultNonTransferParty =
        customCustName.isNotEmpty ? customCustName : cashCustomer;
    final title = isTransfer
        ? '${account?.name.trim().isNotEmpty == true ? account!.name : cashCustomer}  ←  ${toAccount?.name.trim().isNotEmpty == true ? toAccount!.name : cashCustomer}'
        : (account?.name.trim().isNotEmpty == true
            ? account!.name
            : defaultNonTransferParty);

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = index.isEven
        ? (isDark ? const Color(0xFF1E293B) : Colors.white)
        : (isDark ? const Color(0xFF132A2E) : const Color(0xFFE6F7F5));

    final hasItemsSummary = itemsSummary.trim().isNotEmpty;
    final detailsLine = hasItemsSummary
        ? itemsSummary.trim()
        : (tx.description.trim().isNotEmpty
            ? tx.description.trim()
            : context.tr(tx.type.label));
    final cleanExecutor = executorName.trim();

    return Card(
      color: cardBg,
      surfaceTintColor: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _menu(context, ref),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Text(tx.type.icon, style: const TextStyle(fontSize: 19)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        _buildCompactSyncBadge(context, ref),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Pill(tx.type.label, color: color),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${Fmt.date(tx.date)} · ${Fmt.clock(tx.createdAt)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: AppColors.text3Of(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    // سطر نظيف وغير مزدحم يعرض ملخص أصناف الفاتورة (أو البيان) بجانب اسم الجهاز/الموظف المنفذ.
                    Row(
                      children: [
                        Icon(
                          hasItemsSummary
                              ? Icons.shopping_bag_outlined
                              : Icons.notes_rounded,
                          size: 13.5,
                          color: AppColors.text2Of(context),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            detailsLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.text2Of(context),
                            ),
                          ),
                        ),
                        if (cleanExecutor.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.person_outline_rounded,
                            size: 13,
                            color: AppColors.text3Of(context),
                          ),
                          const SizedBox(width: 3),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 110),
                            child: Text(
                              cleanExecutor,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
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
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    hidden ? '••••' : Fmt.money(tx.amount),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15.5,
                      color: AppColors.textOf(context),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tx.currency,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text3Of(context),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// (المتطلب 3) بادج واحد مصغّر وأنيق جداً يحتوي على علامة صح (أو أيقونة انتظار صغيرة) وعداد الأجهزة المتزامنة.
  Widget _buildCompactSyncBadge(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(workspaceModeProvider).value ?? 'standalone';
    final isOwner = ref.watch(isOwnerProvider).value ?? (mode == 'host');
    final badges =
        isOwner ? ref.watch(txDeliveryBadgesProvider).valueOrNull : null;
    final b = badges?['${tx.id}'];
    final hasTracker = isOwner && b != null && b.total > 1;

    final int delivered;
    final int total;
    final bool isComplete;

    if (hasTracker) {
      delivered = b.delivered;
      total = b.total;
      isComplete = tx.syncState == 'synced' && b.all;
    } else {
      final devices = ref.watch(devicesProvider).valueOrNull ?? const [];
      final rosterTotal = devices.length > 1 ? devices.length : 1;
      total = b?.total ?? rosterTotal;
      final isSynced =
          mode == 'standalone' || tx.syncState == 'synced' || tx.status == 'done' && tx.syncState != 'pending' && tx.syncState != 'syncing' && tx.syncState != 'failed';
      delivered = b?.delivered ?? (isSynced ? total : 1);
      isComplete = isSynced && delivered >= total;
    }

    final badgeColor =
        isComplete ? Colors.green.shade700 : Colors.amber.shade900;
    final text = isComplete
        ? '✓ $delivered/$total'
        : '$delivered/$total';

    final pill = Container(
      key: ValueKey('tx_compact_sync_badge_${tx.id ?? index}'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: badgeColor.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isComplete) ...[
            Icon(
              Icons.hourglass_top_rounded,
              size: 11,
              color: badgeColor,
            ),
            const SizedBox(width: 2),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              color: badgeColor,
            ),
          ),
        ],
      ),
    );

    if (hasTracker) {
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _showDeliveryDetailsSheet(context, b),
        child: pill,
      );
    }
    return pill;
  }

  Future<void> _showDeliveryDetailsSheet(
    BuildContext context,
    TxDeliveryBadge badge,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.text3Of(ctx).withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      badge.all
                          ? Icons.verified_rounded
                          : Icons.cloud_sync_rounded,
                      color: badge.all
                          ? Colors.green.shade600
                          : Colors.amber.shade800,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'حالة استلام العملية على أجهزة المنشأة',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            'تم الاستلام في ${badge.delivered} من أصل ${badge.total} أجهزة مسجلة في الروستر',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.text3Of(ctx),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: (badge.all
                                ? Colors.green.shade600
                                : Colors.amber.shade800)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        '👥 ${badge.delivered}/${badge.total}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: badge.all
                              ? Colors.green.shade700
                              : Colors.amber.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
                const Divider(height: 20),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: badge.peers.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, i) {
                      final p = badge.peers[i];
                      final parsedReceived =
                          DateTime.tryParse(p.receivedAt.trim());
                      final timeText = parsedReceived != null
                          ? Fmt.clock(parsedReceived)
                          : '';
                      final statusLabel = p.delivered
                          ? '✅ تم الاستلام${timeText.isNotEmpty ? ' $timeText' : ''}'
                          : '⏳ بانتظار الاتصال';
                      final statusColor = p.delivered
                          ? Colors.green.shade700
                          : Colors.amber.shade900;
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        leading: CircleAvatar(
                          radius: 18,
                          backgroundColor: (p.isOwner
                                  ? AppColors.primaryOf(ctx)
                                  : AppColors.infoOf(ctx))
                              .withValues(alpha: 0.12),
                          child: Icon(
                            p.isOwner
                                ? Icons.admin_panel_settings_rounded
                                : Icons.smartphone_rounded,
                            size: 18,
                            color: p.isOwner
                                ? AppColors.primaryOf(ctx)
                                : AppColors.infoOf(ctx),
                          ),
                        ),
                        title: Text(
                          p.deviceName,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          [
                            if (p.isOwner) 'جهاز المدير' else 'جهاز عضو',
                            if (p.isCreator) 'منشئ العملية',
                          ].join(' · '),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppColors.text3Of(ctx),
                          ),
                        ),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: statusColor.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Text(
                            statusLabel,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: statusColor,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _menu(BuildContext context, WidgetRef ref) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            // «عرض العملية» أول الخيارات: نافذة تفاصيل كاملة للقراءة فقط.
            ListTile(
              leading: Icon(Icons.visibility_outlined,
                  color: AppColors.infoOf(context)),
              title: const Text('عرض العملية'),
              subtitle: const Text('كل تفاصيل العملية في نافذة واحدة'),
              onTap: () => Navigator.pop(context, 'view'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('تعديل العملية'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('تكرار العملية'),
              onTap: () => Navigator.pop(context, 'copy'),
            ),
            ListTile(
              leading: Icon(Icons.send, color: AppColors.primaryOf(context)),
              title: const Text('إرسال واتساب'),
              subtitle: const Text('يفتح محادثة العميل بالصورة والنص'),
              onTap: () => Navigator.pop(context, 'send'),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('صورة الإيصال'),
              subtitle: const Text('معاينة وإعادة التوليد'),
              onTap: () => Navigator.pop(context, 'image'),
            ),
            if (ref.read(isOwnerProvider).valueOrNull == true ||
                (ref.read(currentUserProvider).valueOrNull?.can('delete_tx') ??
                    true))
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: AppColors.dangerOf(context),
                ),
                title: Text(
                  'حذف العملية',
                  style: TextStyle(color: AppColors.dangerOf(context)),
                ),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case 'view':
        await showTxDetails(context, ref,
            tx: tx, account: account, toAccount: toAccount);
      case 'edit':
        await openTxForm(context, ref, existing: tx);
      case 'copy':
        await openTxForm(context, ref, existing: tx, isCopy: true);
      case 'send':
        // إعادة الإرسال تسلك المسار نفسه تمامًا كعملية جديدة.
        await TxShare.sendNow(context, ref, tx: tx);
      case 'image':
        await showReceiptPreview(context, ref, tx: tx);
      case 'delete':
        final ok = await confirmDialog(
          context,
          title: 'حذف عملية',
          message:
              'سيُحذف السجل ويُحدَّث رصيد الحساب تلقائيًا. هل تريد المتابعة؟',
          danger: true,
        );
        if (ok == true) {
          await ref.read(repoProvider).deleteTx(tx.id!);
          bump(ref);
          if (context.mounted) {
            showSnack(context, 'تم حذف العملية وتحديث الرصيد');
          }
        }
    }
  }
}

/// نافذة «عرض العملية»: بطاقة تفاصيل وافية واحترافية لسجل المبيعات والعمليات المالية —
/// تعرض بيانات الطرف (اسم العميل، الهاتف، نوع الحساب)، الملخص المالي المفصل
/// (إجمالي الفاتورة، الخصم، المبلغ المدفوع، المتبقي كمديونية)، جدول الأصناف،
/// وأزرار إجرائية سريعة (طباعة الفاتورة، مشاركة واتساب، عرض الإيصال كصورة).
Future<void> showTxDetails(
  BuildContext context,
  WidgetRef ref, {
  required Tx tx,
  Account? account,
  Account? toAccount,
}) async {
  final repo = ref.read(repoProvider);
  final resolvedAccount = account ??
      (tx.accountId != null ? await repo.account(tx.accountId!) : null);
  final items = tx.id != null
      ? await repo.transactionItems(tx.id!)
      : const <InvoiceLine>[];
  final execDeviceName = await repo.txCreatorDeviceName(tx.id);
  if (!context.mounted) return;

  final isTransfer = tx.type == OpType.transfer;
  final isCashSale = tx.type == OpType.revenue;
  final isCreditOrPartial = tx.type == OpType.debit;
  final group = opGroup(tx.type);
  final color = switch (group) {
    'inflow' => AppColors.greenOf(context),
    'outflow' => AppColors.dangerOf(context),
    'receivable' => AppColors.infoOf(context),
    'payable' => AppColors.accentOf(context),
    _ => AppColors.violetOf(context),
  };

  // استخراج قيم الخصم والمدفوع والمتبقي من ملاحظات الفاتورة أو حسابها
  String? paidValStr;
  String? remainValStr;
  String? discountValStr;
  for (final l in tx.notes.split('\n')) {
    final t = l.trim();
    if (t.startsWith('المبلغ المدفوع:')) {
      paidValStr = t.substring('المبلغ المدفوع:'.length).trim();
    } else if (t.startsWith('المبلغ المتبقي:')) {
      remainValStr = t.substring('المبلغ المتبقي:'.length).trim();
    } else if (t.startsWith('المتبقي:')) {
      remainValStr = t.substring('المتبقي:'.length).trim();
    } else if (t.startsWith('الخصم:')) {
      discountValStr = t.substring('الخصم:'.length).trim();
    }
  }

  final itemsSubtotal =
      items.fold<double>(0.0, (sum, line) => sum + line.total);
  final inferredDiscount =
      (items.isNotEmpty && itemsSubtotal > tx.amount)
          ? (itemsSubtotal - tx.amount)
          : 0.0;
  final invoiceTotal =
      items.isNotEmpty && itemsSubtotal > tx.amount ? itemsSubtotal : tx.amount;

  final String discountDisplay = discountValStr ??
      '${Fmt.money(inferredDiscount)} ${tx.currency}';
  final String paidDisplay = paidValStr ??
      (isCashSale
          ? '${Fmt.money(tx.amount)} ${tx.currency}'
          : (isCreditOrPartial ? '0.00 ${tx.currency}' : '${Fmt.money(tx.amount)} ${tx.currency}'));
  final String remainDisplay = remainValStr ??
      (isCashSale
          ? '0.00 ${tx.currency}'
          : (isCreditOrPartial ? '${Fmt.money(tx.amount)} ${tx.currency}' : '0.00 ${tx.currency}'));

  final customCustName = tx.customCustomerName ?? '';
  final partyName = resolvedAccount?.name.trim().isNotEmpty == true
      ? resolvedAccount!.name
      : (customCustName.isNotEmpty
          ? customCustName
          : (isCashSale ? 'عميل نقدي' : 'غير محدد'));
  final partyPhone = resolvedAccount?.phone.trim().isNotEmpty == true
      ? resolvedAccount!.phone
      : 'غير مسجل';
  final partyKindLabel = resolvedAccount != null
      ? resolvedAccount.kind.label
      : (isCashSale ? 'عميل نقدي (مدفوع نقداً)' : tx.accountKind.label);

  final paymentBadgeText = isCashSale
      ? 'مدفوع نقداً'
      : (tx.type == OpType.inflow || tx.type == OpType.credit
          ? 'له (سند قبض)'
          : (isCreditOrPartial ? 'عليه (ذمة آجلة)' : tx.type.label));
  final paymentBadgeColor = (isCashSale ||
          tx.type == OpType.inflow ||
          tx.type == OpType.credit)
      ? AppColors.greenOf(context)
      : AppColors.dangerOf(context);

  Future<void> printInvoice() async {
    try {
      final st = await repo.settings();
      final orgName = st['businessName']?.trim().isNotEmpty == true
          ? st['businessName']!
          : 'متجري';
      final orgPhone = st['phone'] ?? '';
      final footer = st['voucherFooter']?.trim().isNotEmpty == true
          ? st['voucherFooter']!
          : 'شكراً لتعاملكم معنا';
      final logoPath =
          (st['logo'] ?? st['logoPath'] ?? st['account.photoPath'] ?? '')
              .trim();
      final logoBase64 =
          (st['org.icon.b64'] ?? st['logoBase64'] ?? '').trim();
      final stamp = await featureNeedsStamp(ref, Feature.reportsExport);
      final sellerIdentity = (st['profile.owner_name'] ??
              st['sync.deviceName'] ??
              st['account.name'] ??
              tx.cashierName)
          .trim();
      final built = await buildThermalInvoiceDocument(
        tx: tx,
        account: resolvedAccount,
        lines: items,
        orgName: orgName,
        orgPhone: orgPhone,
        footer: footer,
        sellerOrDevice: sellerIdentity,
        logoPath: logoPath,
        logoBase64: logoBase64,
        stamp: stamp,
      );
      await Printing.layoutPdf(
        onLayout: (format) async => built.bytes,
        name: 'Invoice_${tx.reference.isEmpty ? tx.id : tx.reference}',
      );
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذر فتح الطباعة: $e', error: true);
      }
    }
  }

  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // رأس البطاقة
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child:
                        Text(tx.type.icon, style: const TextStyle(fontSize: 20)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isCashSale
                              ? 'فاتورة نقدية مدفوعة'
                              : 'تفاصيل الفاتورة والعملية',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: color,
                          ),
                        ),
                        Text(
                          '${tx.reference.isNotEmpty ? 'مرجع #${tx.reference} · ' : ''}${Fmt.dateTime(tx.date)}',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppColors.text3Of(ctx),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: paymentBadgeColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: paymentBadgeColor.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      paymentBadgeText,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        color: paymentBadgeColor,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const Divider(height: 18),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 1. بيانات الطرف
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(ctx)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(ctx)
                                .dividerColor
                                .withValues(alpha: 0.25),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.person_outline,
                                    size: 17, color: AppColors.primaryOf(ctx)),
                                const SizedBox(width: 6),
                                const Text(
                                  'بيانات الطرف (العميل / الحساب)',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (isTransfer)
                              _detailKvRow(
                                ctx,
                                'من ← إلى',
                                '${resolvedAccount?.name ?? '—'} ← ${toAccount?.name ?? '—'}',
                              )
                            else ...[
                              _detailKvRow(ctx, 'اسم العميل', partyName),
                              _detailKvRow(ctx, 'رقم الهاتف', partyPhone),
                              _detailKvRow(ctx, 'نوع الحساب', partyKindLabel),
                            ],
                            if (tx.cashierName.trim().isNotEmpty)
                              _detailKvRow(
                                  ctx, 'المستخدم المنفّذ', tx.cashierName.trim()),
                            if (execDeviceName.trim().isNotEmpty)
                              _detailKvRow(
                                  ctx, 'الجهاز المنفّذ', execDeviceName.trim()),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),

                      // 2. الملخص المالي المفصل
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.primarySoftOf(ctx),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.account_balance_wallet_outlined,
                                    size: 17, color: AppColors.primaryOf(ctx)),
                                const SizedBox(width: 6),
                                const Text(
                                  'الملخص المالي المفصل',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            _detailKvRow(
                              ctx,
                              'إجمالي الفاتورة',
                              '${Fmt.money(invoiceTotal)} ${tx.currency}',
                              boldValue: true,
                            ),
                            _detailKvRow(
                              ctx,
                              'الخصم',
                              discountDisplay,
                            ),
                            _detailKvRow(
                              ctx,
                              'صافي الفاتورة',
                              '${Fmt.money(tx.amount)} ${tx.currency}',
                              boldValue: true,
                              valueColor: AppColors.primaryOf(ctx),
                            ),
                            _detailKvRow(
                              ctx,
                              'المبلغ المدفوع',
                              paidDisplay,
                              boldValue: true,
                              valueColor: AppColors.greenOf(ctx),
                            ),
                            _detailKvRow(
                              ctx,
                              'المبلغ المتبقي (مديونية)',
                              remainDisplay,
                              boldValue: true,
                              valueColor: isCashSale
                                  ? AppColors.greenOf(ctx)
                                  : AppColors.dangerOf(ctx),
                            ),
                          ],
                        ),
                      ),

                      // 3. جدول الأصناف
                      if (items.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Theme.of(ctx)
                                  .dividerColor
                                  .withValues(alpha: 0.35),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Theme.of(ctx)
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.6),
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(11),
                                  ),
                                ),
                                child: const Row(
                                  children: [
                                    Expanded(
                                      flex: 4,
                                      child: Text(
                                        'الصنف',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        'الكمية',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        'السعر',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        'الإجمالي',
                                        textAlign: TextAlign.end,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              for (var i = 0; i < items.length; i++) ...[
                                if (i > 0) const Divider(height: 1),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        flex: 4,
                                        child: Text(
                                          items[i].name,
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        flex: 2,
                                        child: Text(
                                          '${Fmt.money(items[i].quantity)} ${items[i].unit}',
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                      Expanded(
                                        flex: 2,
                                        child: Text(
                                          Fmt.money(items[i].unitPrice),
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                      Expanded(
                                        flex: 2,
                                        child: Text(
                                          Fmt.money(items[i].total),
                                          textAlign: TextAlign.end,
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],

                      // 4. البيان والملاحظات الإضافية
                      if (tx.description.trim().isNotEmpty ||
                          tx.notes.trim().isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: Theme.of(ctx)
                                  .dividerColor
                                  .withValues(alpha: 0.25),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (tx.description.trim().isNotEmpty)
                                _detailKvRow(
                                    ctx, 'البيان', tx.description.trim()),
                              if (tx.notes.trim().isNotEmpty)
                                _detailKvRow(ctx, 'ملاحظات', tx.notes.trim()),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // 5. أزرار إجرائية سريعة: طباعة الفاتورة، مشاركة واتساب، عرض الإيصال كصورة
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await printInvoice();
                    },
                    icon: const Icon(Icons.print_outlined, size: 17),
                    label: const Text('طباعة الفاتورة'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await TxShare.sendNow(
                        context,
                        ref,
                        tx: tx,
                        account: resolvedAccount,
                      );
                    },
                    icon: Icon(Icons.chat_outlined,
                        size: 17, color: AppColors.greenOf(context)),
                    label: const Text('مشاركة واتساب'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await showReceiptPreview(context, ref, tx: tx);
                    },
                    icon: const Icon(Icons.image_outlined, size: 17),
                    label: const Text('عرض الإيصال كصورة'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('إغلاق'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await openTxForm(context, ref, existing: tx);
                    },
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('تعديل'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _detailKvRow(
  BuildContext context,
  String label,
  String value, {
  bool boldValue = false,
  Color? valueColor,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: AppColors.text3Of(context),
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: boldValue ? FontWeight.w800 : FontWeight.w600,
              color: valueColor,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}
