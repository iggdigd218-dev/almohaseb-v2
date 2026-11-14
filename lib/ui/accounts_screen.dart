import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/sfx.dart';
import '../data/providers.dart';
import 'account_detail.dart';
import 'account_form.dart';
import 'widgets.dart';

import '../core/theme.dart';
enum _BalanceFilter { all, debt, credit, settled }

final _balanceFilterProvider =
    StateProvider<_BalanceFilter>((ref) => _BalanceFilter.all);

/// شاشة الحسابات: بطاقة الملخص المالي للعملات + بحث وفلترة وقائمة الحسابات.
class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(accountsProvider);
    final filter = ref.watch(accountFilterProvider);
    final curs =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;
    final hidden = ref.watch(hideBalancesProvider);
    final balanceFilter = ref.watch(_balanceFilterProvider);
    final txCounts =
        ref.watch(accountTxCountsProvider).valueOrNull ?? const {};

    return Stack(
      children: [
        Column(
          children: [
            // شريط الفلترة المتقدم والبحث + زر إضافة حساب جديد
            _EnhancedFilterBar(
              filter: filter,
              currencies: curs,
              balanceFilter: balanceFilter,
            ),
            Expanded(
              child: list.when(
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
                        Text(context.tr('جارٍ تحميل الحسابات…')),
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
                          title: context.tr('تعذّر تحميل الحسابات'),
                          message: '$e'.length > 200
                              ? '${'$e'.substring(0, 200)}…'
                              : '$e',
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
                data: (rawItems) {
                  final decimals = <String, int>{
                    for (final c in curs)
                      c.code.trim().toUpperCase(): c.decimal,
                  };
                  final items = rawItems.where((it) {
                    final dec =
                        decimals[it.account.currency.trim().toUpperCase()];
                    final bal = Fmt.roundMoney(it.balance, dec ?? 2);
                    switch (balanceFilter) {
                      case _BalanceFilter.all:
                        return true;
                      case _BalanceFilter.debt:
                        return bal > 0;
                      case _BalanceFilter.credit:
                        return bal < 0;
                      case _BalanceFilter.settled:
                        return bal == 0;
                    }
                  }).toList();

                  if (items.isEmpty) {
                    return EmptyState(
                      icon: Icons.people_outline,
                      title: filter.query.isEmpty &&
                              filter.kind == null &&
                              balanceFilter == _BalanceFilter.all
                          ? context.tr('لا توجد حسابات بعد')
                          : context.tr('لا نتائج مطابقة'),
                      message: filter.query.isEmpty &&
                              filter.kind == null &&
                              balanceFilter == _BalanceFilter.all
                          ? context.tr('أضف أول حساب لعميل أو مورد')
                          : context.tr('جرّب تغيير كلمة البحث أو الفلاتر'),
                      action: FilledButton.icon(
                        onPressed: () => openAccountForm(context, ref),
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                        label: Text(context.tr('إضافة حساب جديد')),
                      ),
                    );
                  }
                  return RefreshIndicator(
                    onRefresh: () async => bump(ref),
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 90),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) => _AccountCard(
                        index: i,
                        item: items[i],
                        currencies: curs,
                        hidden: hidden,
                        txCount: txCounts[items[i].account.id] ?? 0,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _EnhancedFilterBar extends ConsumerStatefulWidget {
  final AccountFilter filter;
  final List<CurrencyDef> currencies;
  final _BalanceFilter balanceFilter;

  const _EnhancedFilterBar({
    required this.filter,
    required this.currencies,
    required this.balanceFilter,
  });

  @override
  ConsumerState<_EnhancedFilterBar> createState() => _EnhancedFilterBarState();
}

class _EnhancedFilterBarState extends ConsumerState<_EnhancedFilterBar> {
  late final TextEditingController _searchCtrl;
  bool _searchExpanded = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController(text: widget.filter.query);
    _searchExpanded = widget.filter.query.isNotEmpty;
  }

  @override
  void didUpdateWidget(covariant _EnhancedFilterBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filter.query != _searchCtrl.text) {
      _searchCtrl.value = TextEditingValue(
        text: widget.filter.query,
        selection: TextSelection.collapsed(offset: widget.filter.query.length),
      );
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _balanceFilterLabel(BuildContext context, _BalanceFilter bf) =>
      switch (bf) {
        _BalanceFilter.all => context.tr('الكل'),
        _BalanceFilter.debt => context.tr('عليه'),
        _BalanceFilter.credit => context.tr('له'),
        _BalanceFilter.settled => context.tr('مسدد'),
      };

  String _summaryLabel(
    BuildContext context,
    AccountFilter filter,
    List<CurrencyDef> currencies,
    _BalanceFilter balanceFilter,
  ) {
    final parts = <String>[];
    if (filter.currency != null) {
      final c = currencies
          .where((x) => x.code == filter.currency)
          .firstOrNull;
      parts.add(c != null ? '${context.tr(c.name)} ${c.flag}' : filter.currency!);
    } else {
      parts.add(context.tr('كل العملات'));
    }
    if (balanceFilter != _BalanceFilter.all) {
      parts.add(_balanceFilterLabel(context, balanceFilter));
    }
    if (filter.kind != null) {
      parts.add(context.tr(filter.kind!.label));
    }
    return parts.join(' • ');
  }

  Future<void> _openFilterSortSheet(
    BuildContext context,
    List<CurrencyDef> currencies,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) {
        return Consumer(
          builder: (ctx, rref, _) {
            final f = rref.watch(accountFilterProvider);
            final bf = rref.watch(_balanceFilterProvider);
            final n = rref.read(accountFilterProvider.notifier);
            final bNotifier = rref.read(_balanceFilterProvider.notifier);

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
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
                            ctx.tr('تصفية وفرز العملاء والحسابات'),
                            style:
                                Theme.of(ctx).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w800,
                                    ),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            n.state = const AccountFilter();
                            bNotifier.state = _BalanceFilter.all;
                            Navigator.pop(ctx);
                          },
                          child: Text(ctx.tr('إعادة ضبط')),
                        ),
                      ],
                    ),
                    const Divider(height: 16),
                    Text(
                      ctx.tr('العملة'),
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
                        _chip(
                          ctx,
                          ctx.tr('كل العملات'),
                          f.currency == null,
                          () => n.state = f.copyWith(clearCurrency: true),
                        ),
                        for (final c in currencies)
                          _chip(
                            ctx,
                            '${ctx.tr(c.name)} ${c.flag}',
                            f.currency == c.code,
                            () => n.state = f.copyWith(
                              currency: f.currency == c.code ? null : c.code,
                              clearCurrency: f.currency == c.code,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      ctx.tr('حالة الرصيد'),
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
                        _chip(
                          ctx,
                          ctx.tr('الكل'),
                          bf == _BalanceFilter.all,
                          () => bNotifier.state = _BalanceFilter.all,
                        ),
                        _chip(
                          ctx,
                          ctx.tr('عليه'),
                          bf == _BalanceFilter.debt,
                          () => bNotifier.state = _BalanceFilter.debt,
                          color: const Color(0xFFEF4444),
                        ),
                        _chip(
                          ctx,
                          ctx.tr('له'),
                          bf == _BalanceFilter.credit,
                          () => bNotifier.state = _BalanceFilter.credit,
                          color: const Color(0xFF10B981),
                        ),
                        _chip(
                          ctx,
                          ctx.tr('مسدد'),
                          bf == _BalanceFilter.settled,
                          () => bNotifier.state = _BalanceFilter.settled,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      ctx.tr('نوع الحساب'),
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
                        _chip(
                          ctx,
                          ctx.tr('الكل'),
                          f.kind == null,
                          () => n.state = f.copyWith(clearKind: true),
                        ),
                        ...AccountKind.values.map((k) {
                          return _chip(
                            ctx,
                            '${k.icon} ${ctx.tr(k.label)}',
                            f.kind == k,
                            () => n.state = f.copyWith(
                              kind: f.kind == k ? null : k,
                              clearKind: f.kind == k,
                            ),
                          );
                        }),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(ctx.tr('تم')),
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
  Widget build(BuildContext context) {
    final filter = widget.filter;
    final currencies = widget.currencies;
    final balanceFilter = widget.balanceFilter;
    final n = ref.read(accountFilterProvider.notifier);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasActiveFilter = filter.currency != null ||
        balanceFilter != _BalanceFilter.all ||
        filter.kind != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
      child: Row(
        children: [
          if (_searchExpanded) ...[
            Expanded(
              child: TextField(
                key: const ValueKey('accounts_search_field'),
                autofocus: true,
                controller: _searchCtrl,
                style: const TextStyle(fontSize: 13.5),
                decoration: InputDecoration(
                  hintText: context.tr('بحث بالاسم أو الهاتف أو الملاحظات…'),
                  hintStyle: const TextStyle(fontSize: 13),
                  prefixIcon: const Icon(Icons.search, size: 19),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: context.tr('إغلاق البحث'),
                    onPressed: () {
                      _searchCtrl.clear();
                      n.state = filter.copyWith(query: '');
                      setState(() => _searchExpanded = false);
                    },
                  ),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  filled: true,
                  fillColor: isDark
                      ? const Color(0xFF1E293B)
                      : const Color(0xFFF1F5F9),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (v) => n.state = filter.copyWith(query: v),
              ),
            ),
          ] else ...[
            Expanded(
              child: InkWell(
                key: const ValueKey('accounts_unified_filter_badge'),
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  Sfx.tap();
                  _openFilterSortSheet(context, currencies);
                },
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: hasActiveFilter
                        ? AppColors.primarySoftOf(context)
                        : (isDark
                            ? const Color(0xFF1E293B)
                            : const Color(0xFFF1F5F9)),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: hasActiveFilter
                          ? AppColors.primaryOf(context)
                          : AppColors.borderOf(context),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.tune_rounded,
                        size: 17,
                        color: hasActiveFilter
                            ? AppColors.primaryOf(context)
                            : AppColors.text2Of(context),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${context.tr('تصفية وفرز')}: ${_summaryLabel(context, filter, currencies, balanceFilter)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: hasActiveFilter
                                ? AppColors.primaryOf(context)
                                : AppColors.textOf(context),
                          ),
                        ),
                      ),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: AppColors.text2Of(context),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Material(
              color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                key: const ValueKey('accounts_search_icon_badge'),
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  Sfx.tap();
                  setState(() => _searchExpanded = true);
                },
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.borderOf(context)),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.search,
                    size: 20,
                    color: AppColors.textOf(context),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: 8),
          SizedBox(
            width: 38,
            height: 38,
            child: FilledButton(
              key: const ValueKey('accounts_add_btn'),
              style: FilledButton.styleFrom(
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () {
                Sfx.tap();
                openAccountForm(context, ref);
              },
              child: const Icon(Icons.add, size: 22),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext c,
    String label,
    bool active,
    VoidCallback onTap, {
    Color? color,
  }) {
    final effectiveColor = color ?? const Color(0xFF0284C7);
    final isDark = Theme.of(c).brightness == Brightness.dark;

    return InkWell(
      onTap: () {
        Sfx.tap();
        onTap();
      },
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? effectiveColor.withValues(alpha: isDark ? 0.28 : 0.14)
              : (isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? effectiveColor : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            color: active
                ? effectiveColor
                : (isDark
                    ? const Color(0xFF94A3B8)
                    : const Color(0xFF475569)),
          ),
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  final int index;
  final AccountWithBalance item;
  final List<CurrencyDef> currencies;
  final bool hidden;
  final int txCount;

  const _AccountCard({
    this.index = 0,
    required this.item,
    required this.currencies,
    required this.hidden,
    required this.txCount,
  });

  Color _avatarColor(String name) {
    final colors = [
      const Color(0xFF0284C7),
      AppColors.primary2,
      const Color(0xFF7C3AED),
      const Color(0xFFEA580C),
      const Color(0xFF4F46E5),
      const Color(0xFFDB2777),
    ];
    return colors[name.hashCode.abs() % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final a = item.account;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final c = currencies.firstWhere(
      (x) => x.code == a.currency,
      orElse: () => kDefaultCurrencies.first,
    );

    // (المهمة 2) الأرقام دائماً باللون الأسود، وعبارة «عليه» بالأحمر و«له» بالأخضر،
    // مع المربع الصغير ذي السهم الأبيض بجانب المبلغ.
    final shown = Fmt.roundMoney(item.balance, c.decimal);
    final isDebt = shown > 0;
    final isCredit = shown < 0;
    final accent = _avatarColor(a.name);

    const debtRed = Color(0xFFEF4444);
    const creditGreen = Color(0xFF10B981);
    final statusColor = isDebt
        ? debtRed
        : (isCredit
            ? creditGreen
            : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)));

    final cardBg = index.isEven
        ? (isDark ? const Color(0xFF1E293B) : Colors.white)
        : (isDark ? const Color(0xFF132A2E) : const Color(0xFFE6F7F5));

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            Sfx.tap();
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AccountDetailScreen(accountId: a.id!),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: isDark ? 0.22 : 0.12),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: accent.withValues(alpha: 0.3),
                      width: 1.2,
                    ),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Opacity(
                        opacity: 0.01,
                        child: Icon(Icons.person, color: accent, size: 22),
                      ),
                      Icon(Icons.person_rounded, color: accent, size: 24),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          if (a.phone.isNotEmpty) a.phone,
                          if (txCount > 0)
                            context.tr('$txCount حركة')
                          else
                            context.tr('لا حركات'),
                          context.tr(c.name),
                        ].join(' • '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (hidden)
                          const Text(
                            '••••••',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2,
                            ),
                          )
                        else
                          Text(
                            isDebt || isCredit
                                ? '${Fmt.moneyFor(item.balance.abs(), c)} ${c.symbol}'
                                : '0 ${c.symbol}',
                            style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w900,
                              color: AppColors.textOf(context),
                            ),
                          ),
                        const SizedBox(height: 2),
                        Text(
                          isDebt
                              ? context.tr('عليه')
                              : (isCredit
                                  ? context.tr('له')
                                  : context.tr('مسدد')),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: statusColor,
                          ),
                        ),
                      ],
                    ),
                    if (isDebt || isCredit) ...[
                      const SizedBox(width: 8),
                      NatureArrowSquare(isDebit: isDebt, size: 22),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


