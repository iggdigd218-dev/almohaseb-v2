import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/accounting.dart';
import '../core/format.dart';
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
    // (2026-09-22) التحكم يظهر حسب صلاحية العضو: التعديل/الأرشفة
    // بإذن تعديل العمليات، والحذف النهائي بإذن الحذف — المدير يرى الكل.
    final me = ref.watch(currentUserProvider).valueOrNull;
    final canEdit = me == null || me.can('edit_tx');
    final canDelete = me == null || me.can('delete_tx');
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
            body: const EmptyState(
              icon: Icons.person_off_outlined,
              title: 'الحساب غير موجود',
            ),
          );
        }
        final allTxs = _latestTxs ??
            ref.read(accountTxProvider(accountId)).valueOrNull ??
            [];

        // فصل الأرصدة لكل عملة: لا دمج بقيمة محوّلة واحدة — الحساب
        // متعدد العملات يعرض رصيداً مستقلاً لكل عملة (كبسولات).
        final balByCur = <String, double>{a.currency: a.openingBalance};
        for (final t in allTxs) {
          final e = t.effectOn(accountId);
          if (e == null) continue;
          balByCur[t.currency] = (balByCur[t.currency] ?? 0.0) + e;
        }
        // العملات مرتبة: عملة الحساب أولاً ثم البقية.
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
        // إن اختفت العملة المفلترة (حذف عملياتها) نعود للعرض الكامل.
        if (_capsuleCur != null && !balByCur.containsKey(_capsuleCur)) {
          _capsuleCur = null;
        }
        final activeCur = _capsuleCur ?? a.currency;
        final c = defOf(activeCur);
        // السجل المعروض: كل العمليات أو عملة الكبسولة المختارة فقط.
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
          // (دفعة التدقيق) حصر إجمالي المبيعات بفواتير المبيعات الفعلية:
          // نقدي (revenue) أو آجل (debit) لغير المورد — مطابق لتعريف
          // الفواتير في المستودع؛ إدخالات «عليه» على الموردين ليست مبيعات.
          final isSale = !isRet &&
              (t.type == OpType.revenue ||
                  (t.type == OpType.debit &&
                      t.accountKind != AccountKind.supplier));
          if (isSale) {
            totalSales += t.amount;
          } else if (isRet) {
            // (دفعة التدقيق) المرتجعات تُجمع صافية داخل الحلقة ويُحصر
            // الناتج مرة واحدة بعدها — الحصر داخل الحلقة كان يصفّر
            // مبكراً ويخطئ مع مرتجع يسبق فاتورته في الترتيب.
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
        // (دفعة التدقيق) الرصيد الافتتاحي جزء من كشف الحساب عند عملة
        // الحساب: موجب ⇒ مدين (عليه)، سالب ⇒ دائن (له).
        if (activeCur == a.currency && a.openingBalance != 0) {
          if (a.openingBalance > 0) {
            totalDebit += a.openingBalance;
          } else {
            totalCredit += a.openingBalance.abs();
          }
        }
        // الحصر بعد اكتمال الجمع الصافي.
        totalSales = totalSales.clamp(0.0, double.infinity);

        return Scaffold(
          appBar: AppBar(
            toolbarHeight: 60,
            title: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                a.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(height: 1.35),
              ),
            ),
            actions: [
              // (3.98.34) كان زراً عائماً — صار أيقونة في شريط العنوان بلا تراكب.
              IconButton(
                tooltip: 'عملية جديدة',
                icon: const Icon(Icons.add_rounded),
                onPressed: () async {
                  await openTxForm(context, ref, presetAccountId: accountId);
                  _refreshAccountData();
                },
              ),
              if (canEdit)
                IconButton(
                  tooltip: 'تعديل',
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
                        child: Text(a.archived ? 'إلغاء الأرشفة' : 'أرشفة'),
                      ),
                    if (canDelete)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('حذف نهائي'),
                      ),
                  ],
                ),
            ],
          ),
          body: SafeArea(
            top: true,
            bottom: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 18, 14, 90),
              children: [
                Card(
                  margin: const EdgeInsets.only(top: 6),
                  clipBehavior: Clip.none,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 4, bottom: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: AppColors.teal.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  a.kind.icon,
                                  style: const TextStyle(fontSize: 21),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        a.name,
                                        strutStyle: const StrutStyle(
                                          fontSize: 17,
                                          height: 1.45,
                                          forceStrutHeight: true,
                                        ),
                                        style: const TextStyle(
                                          fontSize: 17,
                                          height: 1.45,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${a.kind.label} · ${c.name}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.35,
                                          color: Theme.of(context).hintColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Divider(height: 1),
                        const SizedBox(height: 14),
                        // كبسولات العملات: رصيد مستقل لكل عملة، والنقر
                        // يفلتر السجل أدناه على تلك العملة فقط.
                        if (curCodes.length > 1) ...[
                          SizedBox(
                            height: 40,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: [
                                for (final code in curCodes)
                                  Padding(
                                    padding: const EdgeInsetsDirectional.only(
                                        end: 7),
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
                          const SizedBox(height: 12),
                        ],
                        Text(
                          _capsuleCur == null
                              ? 'الرصيد الحالي'
                              : 'الرصيد الحالي (${c.name})',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Theme.of(context).hintColor,
                          ),
                        ),
                        const SizedBox(height: 6),
                        BalanceText(
                          value: balance,
                          currency: c,
                          hidden: hidden,
                          size: 26,
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            if (a.kind == AccountKind.customer) ...[
                              Expanded(
                                child: _MiniStat(
                                  label: 'إجمالي المبيعات',
                                  value: hidden
                                      ? '••••'
                                      : Fmt.money(totalSales, c.decimal),
                                  color: AppColors.primaryOf(context),
                                ),
                              ),
                              Container(
                                width: 1,
                                height: 32,
                                color: Theme.of(context).dividerColor,
                              ),
                            ],
                            Expanded(
                              child: _MiniStat(
                                label: 'إجمالي عليه',
                                value: hidden
                                    ? '••••'
                                    : Fmt.money(totalDebit, c.decimal),
                                color: AppColors.green,
                              ),
                            ),
                            Container(
                              width: 1,
                              height: 32,
                              color: Theme.of(context).dividerColor,
                            ),
                            Expanded(
                              child: _MiniStat(
                                label: 'إجمالي له',
                                value: hidden
                                    ? '••••'
                                    : Fmt.money(totalCredit, c.decimal),
                                color: AppColors.red,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (a.contactNumber.isNotEmpty)
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          // 🔒 رسائل الرصيد للعملاء ميزة مدفوعة.
                          // (دفعة 65-ب) الإشعار المباشر مسموح دائماً —
                          // الحساب المقيد يُرسل الإجمالي مختوماً فقط.
                          onPressed: () async {
                            final stamp = await featureNeedsStamp(
                                ref, Feature.whatsappClaims);
                            if (context.mounted) {
                              await _whatsapp(context, a, balance, c,
                                  stamp: stamp);
                            }
                          },
                          icon: const Icon(Icons.chat, size: 18),
                          label: const Text('واتساب'),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _call(context, a),
                          icon: const Icon(Icons.call, size: 18),
                          label: const Text('اتصال'),
                        ),
                      ),
                    ],
                  ),
                if (a.address.isNotEmpty || a.notes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
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
                const SizedBox(height: 6),
                SectionTitle(_capsuleCur == null
                    ? 'سجل العمليات (${txs.length})'
                    : 'سجل عمليات ${c.name} (${txs.length})'),
                if (txs.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 28),
                      child: EmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: 'لا عمليات على هذا الحساب',
                      ),
                    ),
                  )
                else
                  Card(
                    child: Column(
                      children: [
                        for (var i = 0; i < txs.length; i++) ...[
                          if (i > 0) const Divider(height: 1, indent: 52),
                          // كل سطر يعرض عملته الحقيقية لا عملة الحساب —
                          // فصل صارم للعملات في الكشف.
                          _TxTile(
                            tx: txs[i],
                            account: a,
                            accountId: accountId,
                            currency: defOf(txs[i].currency),
                            canEdit: canEdit,
                            canDelete: canDelete,
                            onChanged: _refreshAccountData,
                          ),
                        ],
                      ],
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
        showSnack(context, a.archived ? 'تمت الاستعادة' : 'تمت الأرشفة');
      }
    } else if (v == 'delete') {
      final ok = await confirmDialog(
        context,
        title: 'حذف الحساب',
        message:
            'سيُحذف «${a.name}» وكل عملياته. يمكن استرجاعه من سلة المحذوفات.',
        confirmText: 'حذف',
        danger: true,
      );
      if (!ok) return;
      await repo.deleteAccount(a.id!);
      bump(ref);
      if (context.mounted) {
        Navigator.pop(context);
        showSnack(context, 'تم حذف الحساب');
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
    // (دفعة 65-ب) الإجمالي فقط — لا تفصيل — وختم التطبيق للحساب المقيد.
    final text = 'مرحباً ${a.name}\n'
        'رصيدكم الحالي: ${Fmt.money(balance.abs(), c.decimal)} ${c.symbol} '
        '($nature)'
        '${stamp ? '\n―\n$kWatermarkText' : ''}';
    final uri = Uri.parse(
      'https://wa.me/${Fmt.waNumber(a.contactNumber)}?text=${Uri.encodeComponent(text)}',
    );
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        showSnack(context, 'تعذّر فتح واتساب', error: true);
      }
    }
  }

  Future<void> _call(BuildContext context, Account a) async {
    final uri = Uri.parse('tel:${a.phone.isEmpty ? a.whatsapp : a.phone}');
    if (!await launchUrl(uri)) {
      if (context.mounted) showSnack(context, 'تعذّر الاتصال', error: true);
    }
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _MiniStat({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor),
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

class _TxTile extends ConsumerWidget {
  final Tx tx;
  final Account account;
  final int accountId;
  final CurrencyDef currency;
  final bool canEdit;
  final bool canDelete;
  final Future<void> Function() onChanged;

  const _TxTile({
    required this.tx,
    required this.account,
    required this.accountId,
    required this.currency,
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
        showSnack(context, 'تعذر فتح الطباعة: $e', error: true);
      }
    }
  }

  Future<void> _openActionsMenu(BuildContext context, WidgetRef ref) async {
    Sfx.tap();
    final isCashSale = tx.type == OpType.revenue;
    final effect = tx.effectOn(accountId) ?? 0;
    final color = isCashSale
        ? AppColors.green
        : (effect > 0
            ? AppColors.green
            : (effect < 0
                ? AppColors.red
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
              // بطاقة ملخص العملية في أعلى القائمة مع عرض البيان الكامل غير المقتطع
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: color.withValues(alpha: 0.25)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            tx.type.icon,
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isCashSale
                                    ? 'فاتورة نقدية مدفوعة'
                                    : tx.type.label,
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
                              : '${effect > 0 ? '+' : '−'}${Fmt.money(effect.abs(), currency.decimal)} ${currency.symbol}',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            color: color,
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
                title: const Text(
                  'عرض التفاصيل الكاملة / الفاتورة',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: const Text(
                  'عرض البيان الكامل وتفاصيل الأصناف والفاتورة',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: () => Navigator.pop(sheetCtx, 'view'),
              ),
              if (canEdit)
                ListTile(
                  leading: Icon(
                    Icons.edit_outlined,
                    color: AppColors.primaryOf(sheetCtx),
                  ),
                  title: const Text(
                    'تعديل العملية',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text(
                    'تعديل المبلغ أو البيان أو التاريخ وتحديث الرصيد فوراً',
                    style: TextStyle(fontSize: 12),
                  ),
                  onTap: () => Navigator.pop(sheetCtx, 'edit'),
                ),
              ListTile(
                leading: Icon(
                  Icons.share_outlined,
                  color: AppColors.greenOf(sheetCtx),
                ),
                title: const Text(
                  'مشاركة سند الإشعار (واتساب / صورة)',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: const Text(
                  'إرسال سند العملية كصورة إشعار أو عبر واتساب',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: () => Navigator.pop(sheetCtx, 'share'),
              ),
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text(
                  'معاينة صورة السند',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: const Text(
                  'معاينة سند العملية وإعادة توليده أو مشاركته',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: () => Navigator.pop(sheetCtx, 'image'),
              ),
              ListTile(
                leading: const Icon(Icons.print_outlined),
                title: const Text(
                  'طباعة السند / الفاتورة (حرارية / PDF)',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: const Text(
                  'طباعة حرارية مباشرة أو حفظ كملف PDF',
                  style: TextStyle(fontSize: 12),
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
                    'حذف العملية',
                    style: TextStyle(
                      color: AppColors.dangerOf(sheetCtx),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  subtitle: const Text(
                    'نقل العملية لسلة المهملات وتحديث رصيد العميل فوراً',
                    style: TextStyle(fontSize: 12),
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
          title: 'حذف العملية',
          message:
              'سيُنقل السجل إلى سلة المهملات ويُحدَّث رصيد الحساب وإجمالياته تلقائياً. هل تريد المتابعة؟',
          confirmText: 'حذف',
          danger: true,
        );
        if (ok && tx.id != null) {
          await ref.read(repoProvider).deleteTx(tx.id!);
          await onChanged();
          if (context.mounted) {
            showSnack(context, 'تم حذف العملية وتحديث الرصيد');
          }
        }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCashSale = tx.type == OpType.revenue;
    final effect = tx.effectOn(accountId) ?? 0;
    // (دفعة التدقيق) توحيد الألوان مع الملخص والكبسولات: «عليه»
    // (موجب، مستحق لنا) أخضر و«له» (سالب، مستحق علينا) أحمر — كان
    // معكوساً هنا بينما الملخص المجاور يستخدم الاتجاه الصحيح.
    final color = isCashSale
        ? AppColors.green
        : (effect > 0
            ? AppColors.green
            : (effect < 0
                ? AppColors.red
                : Theme.of(context).hintColor));

    return ListTile(
      onTap: () => _openActionsMenu(context, ref),
      onLongPress: () => _openActionsMenu(context, ref),
      contentPadding:
          const EdgeInsetsDirectional.fromSTEB(13, 4, 6, 4),
      leading: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(tx.type.icon, style: const TextStyle(fontSize: 16)),
      ),
      title: Text(
        isCashSale ? 'فاتورة نقدية مدفوعة' : tx.type.label,
        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
      ),
      // (دفعة 58 — متطلب 10) وقت التنفيذ HH:MM بجانب التاريخ.
      subtitle: Text(
        '${Fmt.date(tx.date)} · ${Fmt.clock(tx.createdAt)}'
        '${tx.description.isEmpty ? '' : ' · ${tx.description}'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5, height: 1.35),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                isCashSale
                    ? '${Fmt.money(tx.amount, currency.decimal)} ${currency.symbol}'
                    : '${effect > 0 ? '+' : '−'}${Fmt.money(effect.abs(), currency.decimal)} ${currency.symbol}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
              Text(
                isCashSale
                    ? 'مدفوع نقداً'
                    : (effect > 0 ? 'عليه' : (effect < 0 ? 'له' : '')),
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(width: 2),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: 'خيارات العملية',
            icon: Icon(
              Icons.more_vert_rounded,
              size: 20,
              color: AppColors.text2Of(context),
            ),
            onPressed: () => _openActionsMenu(context, ref),
          ),
        ],
      ),
    );
  }
}

/// كبسولة عملة: رصيد مستقل بعملة واحدة + طبيعة الرصيد (له/عليه).
/// النقر يفلتر كشف الحساب على هذه العملة، ونقرة ثانية تلغي الفلتر.
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
    final color = balance > 0
        ? AppColors.green
        : (balance < 0 ? AppColors.red : Theme.of(context).hintColor);
    final nature = balance > 0 ? 'عليه' : (balance < 0 ? 'له' : '—');
    final amount =
        hidden ? '••••' : Fmt.money(balance.abs(), def.decimal);
    return Material(
      color: selected
          ? color.withValues(alpha: 0.16)
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
              color: selected ? color : Theme.of(context).dividerColor,
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
                  color: color,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                nature,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
