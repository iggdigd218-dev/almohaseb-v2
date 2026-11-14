import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../core/thermal_invoice_doc.dart';
import '../data/providers.dart';
import '../data/sync/subscription_guard.dart' show Feature, kWatermarkText;
import 'account_form.dart';
import 'transactions_screen.dart' show showTxDetails;
import 'trial_ui.dart' show featureNeedsStamp;
import 'tx_form.dart';
import 'tx_share.dart';
import 'widgets.dart';

/// كشف حساب: الرصيد والسجل الزمني وأدوات التواصل وإجراءات العمليات المباشرة.
class AccountDetailScreen extends ConsumerStatefulWidget {
  final int accountId;
  const AccountDetailScreen({super.key, required this.accountId});

  @override
  ConsumerState<AccountDetailScreen> createState() =>
      _AccountDetailScreenState();
}

class _AccountDetailScreenState extends ConsumerState<AccountDetailScreen> {
  int get accountId => widget.accountId;

  /// فلتر كبسولة العملة: null = عرض كل العملات.
  String? _capsuleCur;
  Account? _latestAccount;
  List<Tx>? _latestTxs;

  @override
  void initState() {
    super.initState();
    _loadAccountData();
  }

  Future<void> _loadAccountData() async {
    final repo = ref.read(repoProvider);
    final acc = await repo.account(accountId);
    final list = await repo.transactions(accountId: accountId);
    if (mounted) {
      setState(() {
        _latestAccount = acc;
        _latestTxs = list;
      });
    }
  }

  Future<void> _refreshAccountData() async {
    await _loadAccountData();
    if (mounted) {
      bump(ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(refreshProvider, (_, __) {
      _loadAccountData();
    });
    final curs =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;
    final hidden = ref.watch(hideBalancesProvider);
    final me = ref.watch(currentUserProvider).valueOrNull;
    final isOwner = ref.watch(isOwnerProvider).valueOrNull ?? false;
    final canEdit = isOwner || me == null || me.can('edit_tx');
    final canDelete = isOwner || (me?.can('delete_tx') ?? true);
    final cachedAccount = _latestAccount ??
        ref
            .watch(allAccountsProvider)
            .valueOrNull
            ?.where((x) => x.id == accountId)
            .firstOrNull;

    return FutureBuilder<Account?>(
      initialData: cachedAccount,
      future: ref.read(repoProvider).account(accountId),
      builder: (context, snap) {
        final a = _latestAccount ?? snap.data ?? cachedAccount;
        if (a == null) {
          return Scaffold(
            appBar: AppBar(),
            body: EmptyState(
              icon: Icons.person_off_outlined,
              title: context.tr('الحساب غير موجود'),
            ),
          );
        }
        final allTxs = _latestTxs ??
            ref.read(accountTxProvider(accountId)).valueOrNull ??
            [];

        final balByCur = <String, double>{a.currency: a.openingBalance};
        for (final t in allTxs) {
          final e = t.effectOn(accountId);
          if (e == null) continue;
          balByCur[t.currency] = (balByCur[t.currency] ?? 0.0) + e;
        }
        final curCodes = balByCur.keys.toList()
          ..sort((x, y) {
            if (x == a.currency) return -1;
            if (y == a.currency) return 1;
            return x.compareTo(y);
          });
        CurrencyDef defOf(String code) => curs.firstWhere(
              (x) => x.code == code,
              orElse: () => kDefaultCurrencies.first,
            );
        if (_capsuleCur != null && !balByCur.containsKey(_capsuleCur)) {
          _capsuleCur = null;
        }
        final activeCur = _capsuleCur ?? a.currency;
        final c = defOf(activeCur);
        final txs = _capsuleCur == null
            ? allTxs
            : allTxs.where((t) => t.currency == _capsuleCur).toList();
        final balance = balByCur[activeCur] ?? 0.0;

        var totalDebit = 0.0;
        var totalCredit = 0.0;
        var totalSales = 0.0;
        for (final t in txs) {
          if (t.currency != activeCur) continue;
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
          final e = t.effectOn(accountId);
          if (e == null) continue;
          if (e > 0) {
            totalDebit += e;
          } else if (e < 0) {
            totalCredit += e.abs();
          }
        }
        if (activeCur == a.currency && a.openingBalance != 0) {
          if (a.openingBalance > 0) {
            totalDebit += a.openingBalance;
          } else {
            totalCredit += a.openingBalance.abs();
          }
        }
        totalSales = totalSales.clamp(0.0, double.infinity);

        // حساب الرصيد التراكمي (Running Balance) لكل عملية بالترتيب الزمني من الأقدم للأحدث
        final runningBalByCur = <String, double>{
          a.currency: a.openingBalance,
        };
        final txRunningBalance = <Tx, double>{};
        for (final t in allTxs.reversed) {
          final cur = t.currency;
          final prev = runningBalByCur[cur] ??
              (cur == a.currency ? a.openingBalance : 0.0);
          final eff = t.effectOn(accountId) ?? 0.0;
          final next = Fmt.roundMoney(prev + eff, defOf(cur).decimal);
          runningBalByCur[cur] = next;
          txRunningBalance[t] = next;
        }

        return Scaffold(
          appBar: AppBar(
            toolbarHeight: 54,
            title: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                a.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(height: 1.3),
              ),
            ),
            actions: [
              IconButton(
                tooltip: context.tr('عملية جديدة'),
                icon: const Icon(Icons.add_rounded),
                onPressed: () async {
                  await openTxForm(context, ref, presetAccountId: accountId);
                  _refreshAccountData();
                },
              ),
              if (canEdit)
                IconButton(
                  tooltip: context.tr('تعديل'),
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () async {
                    await openAccountForm(context, ref, existing: a);
                    _refreshAccountData();
                  },
                ),
              if (canEdit || canDelete)
                PopupMenuButton<String>(
                  onSelected: (v) => _action(context, ref, a, v),
                  itemBuilder: (_) => [
                    if (canEdit)
                      PopupMenuItem(
                        value: 'archive',
                        child: Text(
                          context.tr(a.archived ? 'إلغاء الأرشفة' : 'أرشفة'),
                        ),
                      ),
                    if (canDelete)
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(context.tr('حذف نهائي')),
                      ),
                  ],
                ),
            ],
          ),
          body: SafeArea(
            top: true,
            bottom: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 84),
              children: [
                Card(
                  margin: EdgeInsets.zero,
                  clipBehavior: Clip.none,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (curCodes.length > 1) ...[
                          SizedBox(
                            height: 34,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: [
                                for (final code in curCodes)
                                  Padding(
                                    padding: const EdgeInsetsDirectional.only(
                                        end: 6),
                                    child: _CurrencyCapsule(
                                      code: code,
                                      def: defOf(code),
                                      balance: balByCur[code] ?? 0.0,
                                      hidden: hidden,
                                      selected: _capsuleCur == code,
                                      onTap: () => setState(() => _capsuleCur =
                                          _capsuleCur == code ? null : code),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 6),
                        ],
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _capsuleCur == null
                                  ? '${context.tr('الرصيد الحالي')}: '
                                  : '${context.tr('الرصيد الحالي')} (${context.tr(c.name)}): ',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                            Flexible(
                              child: BalanceText(
                                value: balance,
                                currency: c,
                                hidden: hidden,
                                size: 20,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.surface2Of(context),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              if (a.kind == AccountKind.customer) ...[
                                Expanded(
                                  child: _MiniStat(
                                    label: context.tr('إجمالي المبيعات'),
                                    value: hidden
                                        ? '••••'
                                        : Fmt.money(totalSales, c.decimal),
                                    color: AppColors.textOf(context),
                                    labelColor: Theme.of(context).hintColor,
                                  ),
                                ),
                                Container(
                                  width: 1,
                                  height: 26,
                                  color: Theme.of(context).dividerColor,
                                ),
                              ],
                              Expanded(
                                child: _MiniStat(
                                  label: context.tr('إجمالي عليه'),
                                  value: hidden
                                      ? '••••'
                                      : Fmt.money(totalDebit, c.decimal),
                                  color: AppColors.textOf(context),
                                  labelColor: const Color(0xFFEF4444),
                                ),
                              ),
                              Container(
                                width: 1,
                                height: 26,
                                color: Theme.of(context).dividerColor,
                              ),
                              Expanded(
                                child: _MiniStat(
                                  label: context.tr('إجمالي له'),
                                  value: hidden
                                      ? '••••'
                                      : Fmt.money(totalCredit, c.decimal),
                                  color: AppColors.textOf(context),
                                  labelColor: const Color(0xFF10B981),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (a.contactNumber.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: SizedBox(
                                  height: 34,
                                  child: OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    onPressed: () async {
                                      final stamp = await featureNeedsStamp(
                                          ref, Feature.whatsappClaims);
                                      if (context.mounted) {
                                        await _whatsapp(context, a, balance, c,
                                            stamp: stamp);
                                      }
                                    },
                                    icon: const Icon(Icons.chat, size: 15),
                                    label: Text(
                                      context.tr('واتساب'),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: SizedBox(
                                  height: 34,
                                  child: OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    onPressed: () => _call(context, a),
                                    icon: const Icon(Icons.call, size: 15),
                                    label: Text(
                                      context.tr('اتصال'),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (a.address.isNotEmpty || a.notes.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (a.address.isNotEmpty)
                            _InfoRow(
                                icon: Icons.place_outlined, text: a.address),
                          if (a.notes.isNotEmpty)
                            _InfoRow(icon: Icons.notes, text: a.notes),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                if (txs.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: EmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: context.tr('لا عمليات على هذا الحساب'),
                      ),
                    ),
                  )
                else
                  Directionality(
                    textDirection: TextDirection.rtl,
                    child: Card(
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: AppColors.borderOf(context),
                        ),
                      ),
                      child: Column(
                        children: [
                          const _StatementTableHeader(),
                          const Divider(height: 1, thickness: 1),
                          for (var i = 0; i < txs.length; i++) ...[
                            if (i > 0)
                              Divider(
                                height: 1,
                                thickness: 0.7,
                                color: AppColors.borderOf(context),
                              ),
                            _TxTile(
                              tx: txs[i],
                              account: a,
                              accountId: accountId,
                              currency: defOf(txs[i].currency),
                              runningBalance: txRunningBalance[txs[i]] ?? 0.0,
                              hidden: hidden,
                              canEdit: canEdit,
                              canDelete: canDelete,
                              onChanged: _refreshAccountData,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _action(
    BuildContext context,
    WidgetRef ref,
    Account a,
    String v,
  ) async {
    final repo = ref.read(repoProvider);
    if (v == 'archive') {
      await repo.archiveAccount(a.id!, !a.archived);
      _refreshAccountData();
      if (context.mounted) {
        showSnack(
          context,
          context.tr(a.archived ? 'تمت الاستعادة' : 'تمت الأرشفة'),
        );
      }
    } else if (v == 'delete') {
      final ok = await confirmDialog(
        context,
        title: context.tr('حذف الحساب'),
        message:
            'سيُحذف «${a.name}» وكل عملياته. يمكن استرجاعه من سلة المحذوفات.',
        confirmText: context.tr('حذف'),
        danger: true,
      );
      if (!ok) return;
      await repo.deleteAccount(a.id!);
      bump(ref);
      if (context.mounted) {
        Navigator.pop(context);
        showSnack(context, context.tr('تم حذف الحساب'));
      }
    }
  }

  Future<void> _whatsapp(
    BuildContext context,
    Account a,
    double balance,
    CurrencyDef c, {
    bool stamp = false,
  }) async {
    final nature = balance > 0 ? 'عليكم' : 'لكم';
    final text = 'مرحباً ${a.name}\n'
        'رصيدكم الحالي: ${Fmt.money(balance.abs(), c.decimal)} ${c.symbol} '
        '($nature)'
        '${stamp ? '\n―\n$kWatermarkText' : ''}';
    final uri = Uri.parse(
      'https://wa.me/${Fmt.waNumber(a.contactNumber)}?text=${Uri.encodeComponent(text)}',
    );
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        showSnack(context, context.tr('تعذّر فتح واتساب'), error: true);
      }
    }
  }

  Future<void> _call(BuildContext context, Account a) async {
    final uri = Uri.parse('tel:${a.phone.isEmpty ? a.whatsapp : a.phone}');
    if (!await launchUrl(uri)) {
      if (context.mounted) {
        showSnack(context, context.tr('تعذّر الاتصال'), error: true);
      }
    }
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final Color? labelColor;
  const _MiniStat({
    required this.label,
    required this.value,
    required this.color,
    this.labelColor,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: labelColor ?? Theme.of(context).hintColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      );
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: Theme.of(context).hintColor),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
}

class _StatementTableHeader extends StatelessWidget {
  const _StatementTableHeader();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final headerBg = dark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
    final headerText = dark ? Colors.white : const Color(0xFF0F172A);
    return Container(
      color: headerBg,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Row(
        children: [
          Expanded(
            flex: 24,
            child: Text(
              context.tr('التاريخ'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: headerText,
              ),
            ),
          ),
          Expanded(
            flex: 25,
            child: Text(
              context.tr('المبلغ'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: headerText,
              ),
            ),
          ),
          Expanded(
            flex: 26,
            child: Text(
              context.tr('التفاصيل'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: headerText,
              ),
            ),
          ),
          Expanded(
            flex: 25,
            child: Text(
              context.tr('الرصيد'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: headerText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TxTile extends ConsumerWidget {
  final Tx tx;
  final Account account;
  final int accountId;
  final CurrencyDef currency;
  final double runningBalance;
  final bool hidden;
  final bool canEdit;
  final bool canDelete;
  final Future<void> Function() onChanged;

  const _TxTile({
    required this.tx,
    required this.account,
    required this.accountId,
    required this.currency,
    required this.runningBalance,
    required this.hidden,
    required this.canEdit,
    required this.canDelete,
    required this.onChanged,
  });

  Future<void> _printTxDocument(BuildContext context, WidgetRef ref) async {
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final items = tx.id != null
          ? await repo.transactionItems(tx.id!)
          : const <InvoiceLine>[];
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
        account: account,
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
        showSnack(context, '${context.tr('تعذر فتح الطباعة')}: $e', error: true);
      }
    }
  }

  Future<void> _openActionsMenu(BuildContext context, WidgetRef ref) async {
    Sfx.tap();
    final isCashSale = tx.type == OpType.revenue;
    final effect = tx.effectOn(accountId) ?? 0;
    const debtRed = Color(0xFFEF4444);
    const creditGreen = Color(0xFF10B981);
    final natureColor = isCashSale
        ? creditGreen
        : (effect > 0
            ? debtRed
            : (effect < 0
                ? creditGreen
                : Theme.of(context).hintColor));

    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: natureColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: natureColor.withValues(alpha: 0.25)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isCashSale
                                    ? sheetCtx.tr('فاتورة نقدية مدفوعة')
                                    : sheetCtx.tr(tx.type.label),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                '${Fmt.date(tx.date)} · ${Fmt.clock(tx.createdAt)}'
                                '${tx.reference.isNotEmpty ? ' · #${tx.reference}' : ''}',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: AppColors.text3Of(sheetCtx),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          isCashSale
                              ? '${Fmt.money(tx.amount, currency.decimal)} ${currency.symbol}'
                              : '${Fmt.money(effect.abs(), currency.decimal)} ${currency.symbol}',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            color: AppColors.textOf(sheetCtx),
                          ),
                        ),
                      ],
                    ),
                    if (tx.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        tx.description.trim(),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: Icon(
                  Icons.visibility_outlined,
                  color: AppColors.infoOf(sheetCtx),
                ),
                title: Text(
                  sheetCtx.tr('عرض التفاصيل الكاملة / الفاتورة'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  sheetCtx.tr('عرض البيان الكامل وتفاصيل الأصناف والفاتورة'),
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () => Navigator.pop(sheetCtx, 'view'),
              ),
              if (canEdit)
                ListTile(
                  leading: Icon(
                    Icons.edit_outlined,
                    color: AppColors.primaryOf(sheetCtx),
                  ),
                  title: Text(
                    sheetCtx.tr('تعديل العملية'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    sheetCtx.tr(
                      'تعديل المبلغ أو البيان أو التاريخ وتحديث الرصيد فوراً',
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                  onTap: () => Navigator.pop(sheetCtx, 'edit'),
                ),
              ListTile(
                leading: Icon(
                  Icons.share_outlined,
                  color: AppColors.greenOf(sheetCtx),
                ),
                title: Text(
                  sheetCtx.tr('مشاركة سند الإشعار (واتساب / صورة)'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  sheetCtx.tr('إرسال سند العملية كصورة إشعار أو عبر واتساب'),
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () => Navigator.pop(sheetCtx, 'share'),
              ),
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: Text(
                  sheetCtx.tr('معاينة صورة السند'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  sheetCtx.tr('معاينة سند العملية وإعادة توليده أو مشاركته'),
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () => Navigator.pop(sheetCtx, 'image'),
              ),
              ListTile(
                leading: const Icon(Icons.print_outlined),
                title: Text(
                  sheetCtx.tr('طباعة السند / الفاتورة (حرارية / PDF)'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  sheetCtx.tr('طباعة حرارية مباشرة أو حفظ كملف PDF'),
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () => Navigator.pop(sheetCtx, 'print'),
              ),
              if (canDelete) ...[
                const Divider(height: 8),
                ListTile(
                  leading: Icon(
                    Icons.delete_outline,
                    color: AppColors.dangerOf(sheetCtx),
                  ),
                  title: Text(
                    sheetCtx.tr('حذف العملية'),
                    style: TextStyle(
                      color: AppColors.dangerOf(sheetCtx),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  subtitle: Text(
                    sheetCtx.tr(
                      'نقل العملية لسلة المهملات وتحديث رصيد العميل فوراً',
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                  onTap: () => Navigator.pop(sheetCtx, 'delete'),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (action == null || !context.mounted) return;

    switch (action) {
      case 'view':
        await showTxDetails(
          context,
          ref,
          tx: tx,
          account: account,
        );
        await onChanged();
      case 'edit':
        await openTxForm(context, ref, existing: tx);
        await onChanged();
      case 'share':
        await TxShare.sendNow(context, ref, tx: tx, account: account);
        await onChanged();
      case 'image':
        await showReceiptPreview(context, ref, tx: tx, account: account);
        await onChanged();
      case 'print':
        await _printTxDocument(context, ref);
      case 'delete':
        final ok = await confirmDialog(
          context,
          title: context.tr('حذف العملية'),
          message: context.tr(
            'سيُنقل السجل إلى سلة المهملات ويُحدَّث رصيد الحساب وإجمالياته تلقائياً. هل تريد المتابعة؟',
          ),
          confirmText: context.tr('حذف'),
          danger: true,
        );
        if (ok && tx.id != null) {
          await ref.read(repoProvider).deleteTx(tx.id!);
          await onChanged();
          if (context.mounted) {
            showSnack(context, context.tr('تم حذف العملية وتحديث الرصيد'));
          }
        }
    }
  }

  String _compactDateStr(DateTime date, DateTime createdAt) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    final hh = createdAt.hour.toString().padLeft(2, '0');
    final mm = createdAt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d\n$hh:$mm';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCashSale = tx.type == OpType.revenue;
    final effect = tx.effectOn(accountId) ?? 0;
    final isDebitOp = !isCashSale && effect > 0;
    final isCreditOp = isCashSale || effect < 0;

    // ألوان الخلايا الملونة للعمود الثاني (المبلغ) والعمود الرابع (الرصيد)
    const softGreenBg = Color(0xFFD1FAE5);
    const softRedBg = Color(0xFFFEE2E2);
    const neutralBg = Color(0xFFF1F5F9);
    const darkInk = Color(0xFF0F172A);

    final amountBg = isDebitOp
        ? softRedBg
        : (isCreditOp ? softGreenBg : neutralBg);
    final amountValue = isCashSale ? tx.amount : effect.abs();
    final amountText = hidden
        ? '••••'
        : Fmt.money(amountValue, currency.decimal);
    final amountNature = isCashSale
        ? context.tr('نقداً')
        : (isDebitOp
            ? context.tr('عليه')
            : (isCreditOp ? context.tr('له') : ''));

    final balIsDebit = runningBalance > 0.0001;
    final balIsCredit = runningBalance < -0.0001;
    final balBg = balIsDebit
        ? softRedBg
        : (balIsCredit ? softGreenBg : neutralBg);
    final balText = hidden
        ? '••••'
        : Fmt.money(runningBalance.abs(), currency.decimal);
    final balNature = balIsDebit
        ? context.tr('عليه')
        : (balIsCredit ? context.tr('له') : '—');

    final rawDesc = tx.description.trim();
    final fallbackTitle = isCashSale
        ? context.tr('فاتورة نقدية مدفوعة')
        : context.tr(tx.type.label);
    final baseDetail = rawDesc.isNotEmpty ? rawDesc : fallbackTitle;
    final refSuffix = tx.reference.trim().isNotEmpty
        ? ' (#${tx.reference.trim().replaceFirst(RegExp(r'^#+'), '')})'
        : '';
    final detailsText = '$baseDetail$refSuffix';

    return Tooltip(
      message: context.tr('خيارات العملية'),
      child: InkWell(
        onTap: () => _openActionsMenu(context, ref),
        onLongPress: () => _openActionsMenu(context, ref),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1) العمود الأول (أقصى اليمين): التاريخ (YYYY-MM-DD HH:mm)
              Expanded(
                flex: 24,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 4,
                    ),
                    child: Text(
                      _compactDateStr(tx.date, tx.createdAt),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textOf(context),
                      ),
                    ),
                  ),
                ),
              ),
              // 2) العمود الثاني (يمين الوسط): المبلغ داخل مربع مستطيل ملون
              Expanded(
                flex: 25,
                child: Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 1,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: amountBg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          amountText,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w900,
                            color: darkInk,
                          ),
                        ),
                      ),
                      if (amountNature.isNotEmpty)
                        Text(
                          amountNature,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            color: darkInk.withValues(alpha: 0.78),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // 3) العمود الثالث (يسار الوسط): التفاصيل مع التفاف النص تلقائياً
              Expanded(
                flex: 26,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: Text(
                      detailsText,
                      textAlign: TextAlign.center,
                      softWrap: true,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textOf(context),
                      ),
                    ),
                  ),
                ),
              ),
              // 4) العمود الرابع (أقصى اليسار): الرصيد التراكمي داخل مربع مستطيل ملون
              Expanded(
                flex: 25,
                child: Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 1,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: balBg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          balText,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w900,
                            color: darkInk,
                          ),
                        ),
                      ),
                      Text(
                        balNature,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: darkInk.withValues(alpha: 0.78),
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
    ),
  );
  }
}

/// كبسولة عملة: رصيد مستقل بعملة واحدة + طبيعة الرصيد (له/عليه).
class _CurrencyCapsule extends StatelessWidget {
  final String code;
  final CurrencyDef def;
  final double balance;
  final bool hidden;
  final bool selected;
  final VoidCallback onTap;
  const _CurrencyCapsule({
    required this.code,
    required this.def,
    required this.balance,
    required this.hidden,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const debtRed = Color(0xFFEF4444);
    const creditGreen = Color(0xFF10B981);
    final natureColor = balance > 0
        ? debtRed
        : (balance < 0 ? creditGreen : Theme.of(context).hintColor);
    final nature = balance > 0
        ? context.tr('عليه')
        : (balance < 0 ? context.tr('له') : '—');
    final amount =
        hidden ? '••••' : Fmt.money(balance.abs(), def.decimal);
    return Material(
      color: selected
          ? natureColor.withValues(alpha: 0.16)
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? natureColor : Theme.of(context).dividerColor,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$amount ${def.symbol}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: AppColors.textOf(context),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                nature,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: natureColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

