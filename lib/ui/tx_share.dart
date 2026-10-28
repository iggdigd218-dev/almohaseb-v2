import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/media_paths.dart';
import '../core/models.dart';
import '../core/receipt_image.dart';
import '../core/theme.dart';
import '../core/whatsapp.dart';
import '../data/providers.dart';
import '../data/repository.dart';
import 'widgets.dart';

String _quantity(double value) =>
    value == value.roundToDouble() ? Fmt.money(value) : Fmt.money(value, 2);

/// توليد صورة إيصال العملية وإرسالها عبر واتساب.
///
/// المسار كاملًا بلا نافذة مشاركة: تُولَّد الصورة، تُحفظ في العملية، ثم
/// تُفتح محادثة العميل مباشرة ومعها الصورة والنص.
enum TxShareOutcome { skipped, opened, failed }

class TxShare {
  /// يولّد الصورة ويحفظ مسارها في العملية، ويعيد المسار.
  static Future<String> generate({
    required Repo repo,
    required Tx tx,
    required Account? account,
  }) async {
    final settings = await repo.settings();
    final currencies = await repo.currencies();
    final items = tx.id == null
        ? const <InvoiceLine>[]
        : await repo.transactionItems(tx.id!);
    final cur = currencies.firstWhere(
      (c) => c.code == tx.currency,
      orElse: () => kDefaultCurrencies.first,
    );
    double? after;
    if (account != null) {
      try {
        after = await repo.balanceOf(account);
      } catch (_) {
        after = null;
      }
    }

    final path = await buildReceiptImage(
      ReceiptData.fromTx(
        tx: tx,
        account: account,
        currency: cur,
        balanceAfter: after,
        settings: settings,
        items: items,
      ),
    );

    if (tx.id != null) {
      await repo.updateTxImage(tx.id!, path);
    }
    return path;
  }

  /// نص الرسالة المرافقة للسند أو الإشعار النصي المباشر.
  static Future<String> caption({
    required Repo repo,
    required Tx tx,
    required Account? account,
  }) async {
    final st = await repo.settings();
    final org = (st['businessName'] ?? '').trim();
    final currencies = await repo.currencies();
    final cur = currencies.firstWhere(
      (c) => c.code == tx.currency,
      orElse: () => kDefaultCurrencies.first,
    );
    final items = tx.id == null
        ? const <InvoiceLine>[]
        : await repo.transactionItems(tx.id!);

    final rawRef = tx.reference.trim();
    final devicePrefix = (st['devicePrefix'] ?? '').trim();
    final String refCode;
    if (rawRef.isNotEmpty) {
      refCode = rawRef;
    } else if (tx.id != null) {
      refCode = devicePrefix.isNotEmpty
          ? '$devicePrefix-${tx.id!.toString().padLeft(5, '0')}'
          : '${tx.id}';
    } else {
      refCode = '';
    }

    final desc = tx.description.trim();
    final isPosInvoice = items.isNotEmpty ||
        desc.startsWith('فاتورة مبيعات') ||
        desc.startsWith('فاتورة نقدية');

    String title;
    if (isPosInvoice) {
      final modeLabel = tx.type == OpType.revenue ? 'نقداً' : 'آجل';
      title =
          '🧾 *فاتورة مبيعات ($modeLabel)*${refCode.isNotEmpty ? '  •  *#$refCode*' : ''}';
    } else if (tx.type == OpType.inflow) {
      title =
          '🧾 *سند قبض وتوريد*${refCode.isNotEmpty ? '  •  *#$refCode*' : ''}';
    } else {
      title =
          '${tx.type.icon} *${tx.type.label}*${refCode.isNotEmpty ? '  •  *#$refCode*' : ''}';
    }

    final dateStr = (tx.date.hour == 0 && tx.date.minute == 0)
        ? Fmt.date(tx.date)
        : Fmt.dateTime(tx.date);

    final lines = <String>[
      if (org.isNotEmpty) '🏪 *$org*',
      '━━━━━━━━━━━━━',
      title,
      '📅 التاريخ: $dateStr',
      '👤 العميل: ${account?.name ?? 'عميل نقدي'}',
      if (!isPosInvoice && desc.isNotEmpty) '📝 البيان: $desc',
    ];

    if (items.isNotEmpty) {
      lines.add('━━━━━━━━━━━━━');
      lines.add('🛒 *الأصناف:*');
      for (var i = 0; i < items.length; i++) {
        final line = items[i];
        lines.add(
          '${i + 1}. ${line.name} × ${_quantity(line.quantity)} ${line.unit} = '
          '${Fmt.money(line.total, cur.decimal)} ${cur.symbol}',
        );
      }
      final total = items.fold<double>(0, (sum, line) => sum + line.total);
      lines.add('━━━━━━━━━━━━━');
      lines.add(
        '💰 إجمالي الفاتورة: ${Fmt.money(total, cur.decimal)} ${cur.symbol}',
      );
      if (tx.type == OpType.revenue) {
        lines.add(
          '✅ المدفوع: ${Fmt.money(tx.amount, cur.decimal)} ${cur.symbol}',
        );
        lines.add(
          '🔴 المتبقي: ${Fmt.money(0, cur.decimal)} ${cur.symbol}',
        );
      } else {
        final noteLines = tx.notes
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        final hasPaidNote =
            noteLines.any((nl) => nl.startsWith('المبلغ المدفوع'));
        final hasRemNote = noteLines.any(
          (nl) => nl.startsWith('المبلغ المتبقي') || nl.startsWith('المتبقي'),
        );
        if (!hasPaidNote) {
          lines.add(
            '✅ المدفوع: ${Fmt.money(0, cur.decimal)} ${cur.symbol}',
          );
        }
        if (!hasRemNote) {
          lines.add(
            '🔴 المتبقي: ${Fmt.money(tx.amount, cur.decimal)} ${cur.symbol}',
          );
        }
        for (final nl in noteLines) {
          if (nl.startsWith('المبلغ المدفوع')) {
            lines.add('✅ $nl');
          } else if (nl.startsWith('المبلغ المتبقي') ||
              nl.startsWith('المتبقي')) {
            lines.add('🔴 $nl');
          } else {
            lines.add('📝 $nl');
          }
        }
      }
    } else {
      lines.add('━━━━━━━━━━━━━');
      switch (tx.type) {
        case OpType.revenue:
          lines.add(
            '✅ المدفوع: ${Fmt.money(tx.amount, cur.decimal)} ${cur.symbol}',
          );
          lines.add(
            '🔴 المتبقي: ${Fmt.money(0, cur.decimal)} ${cur.symbol}',
          );
          break;
        case OpType.inflow:
        case OpType.credit:
          lines.add(
            '✅ المبلغ المستلَم (له): ${Fmt.money(tx.amount, cur.decimal)} ${cur.symbol}',
          );
          break;
        case OpType.outflow:
        case OpType.expense:
        case OpType.debit:
          lines.add(
            '🔴 المبلغ المطلوب (عليه): ${Fmt.money(tx.amount, cur.decimal)} ${cur.symbol}',
          );
          break;
        default:
          lines.add(
            '💵 المبلغ: ${Fmt.money(tx.amount, cur.decimal)} ${cur.symbol}',
          );
      }
      if (tx.notes.trim().isNotEmpty) {
        for (final nl in tx.notes
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)) {
          if (nl.startsWith('المبلغ المدفوع')) {
            lines.add('✅ $nl');
          } else if (nl.startsWith('المبلغ المتبقي') ||
              nl.startsWith('المتبقي')) {
            lines.add('🔴 $nl');
          } else {
            lines.add('📝 $nl');
          }
        }
      }
    }

    // رصيد العميل الحالي بعد العملية (وضوح كامل للمطلوب).
    if (account != null && account.id != null) {
      try {
        final bal = await repo.balanceOf(account);
        if (bal.abs() > 0.001) {
          final statusLabel = bal > 0 ? 'عليه' : 'له';
          lines.add(
            '📊 الرصيد الحالي للعميل: ${Fmt.money(bal.abs(), cur.decimal)} ${cur.symbol} ($statusLabel)',
          );
        } else {
          lines.add(
            '📊 الرصيد الحالي للعميل: ${Fmt.money(0, cur.decimal)} ${cur.symbol} (مسدد بالكامل ✅)',
          );
        }
      } catch (_) {}
    }

    var sellerOrDevice = (st['user.name'] ??
            st['currentUserName'] ??
            st['cashierName'] ??
            st['ownerName'] ??
            '')
        .trim();
    if (sellerOrDevice.isEmpty) {
      try {
        final u = await repo.currentUser();
        if (u != null && u.name.trim().isNotEmpty) {
          sellerOrDevice = u.name.trim();
        }
      } catch (_) {}
    }
    if (sellerOrDevice.isEmpty) {
      sellerOrDevice =
          devicePrefix.isNotEmpty ? devicePrefix : 'الجهاز الرئيسي';
    }

    lines.add('━━━━━━━━━━━━━');
    lines.add('👨‍💼 الموظف / الجهاز: $sellerOrDevice');
    final orgPhone = (st['phone'] ?? '').trim();
    if (orgPhone.isNotEmpty) lines.add('📞 للتواصل: $orgPhone');
    final footer = (st['voucherFooter'] ?? '').trim();
    lines.add('🌿 ${footer.isNotEmpty ? footer : 'شكراً لتعاملكم معنا'}');
    return lines.join('\n');
  }

  static Repo _repoOf(BuildContext context, WidgetRef ref) {
    try {
      return ref.read(repoProvider);
    } catch (_) {
      return ProviderScope.containerOf(context, listen: false)
          .read(repoProvider);
    }
  }

  static void _safeBump(BuildContext context, WidgetRef ref) {
    try {
      bump(ref);
    } catch (_) {
      if (!context.mounted) return;
      try {
        final container = ProviderScope.containerOf(context, listen: false);
        container.read(refreshProvider.notifier).state++;
      } catch (_) {}
    }
  }

  /// هل تم ضبط إعداد مسبق للمشاركة التلقائية لهذا الحساب؟
  static bool isAutoShareConfigured(Account? a) {
    if (a == null) return false;
    final ch = a.notifyChannel.trim();
    return ch == 'auto_whatsapp' ||
        ch == 'auto_w4b' ||
        ch == 'auto_sms' ||
        ch == 'auto_system';
  }

  /// يفتح نافذة المشاركة الرسمية للنظام (System Share Sheet) محمّلة بصورة
  /// السند عالية الدقة ونص الإشعار، مع دعم الدخول المباشر لمحادثة العميل في
  /// واتساب أو الرسائل النصية إن وُجد رقم، ودون حجب المشاركة عند غياب الرقم.
  static Future<TxShareOutcome> shareViaSystemSheet(
    BuildContext context,
    WidgetRef ref, {
    required Tx tx,
    Account? account,
  }) async {
    final repo = _repoOf(context, ref);
    final acc = account ??
        (tx.accountId == null ? null : await repo.account(tx.accountId!));
    final phone = _phoneOf(acc, 'whatsapp');

    if (context.mounted) {
      showSnack(context, 'جارٍ تجهيز صورة السند عالية الدقة للمشاركة…');
    }

    late final String text;
    late final String path;
    try {
      text = await caption(repo: repo, tx: tx, account: acc);
      path = await generate(repo: repo, tx: tx, account: acc);
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر تجهيز بيانات المشاركة: $e', error: true);
      }
      return TxShareOutcome.failed;
    }

    if (context.mounted) {
      _safeBump(context, ref);
    }

    if (Platform.isAndroid) {
      final ok = await WhatsApp.systemShare(
        phone: phone,
        text: text,
        imagePath: path,
      );
      if (ok) return TxShareOutcome.opened;
    }

    final shared = await _shareImageWithText(path, text);
    if (context.mounted && !shared) {
      showSnack(context, 'تعذّر فتح نافذة مشاركة النظام', error: true);
    }
    return shared ? TxShareOutcome.opened : TxShareOutcome.failed;
  }

  /// المسار الكامل: توليد + حفظ + فتح قناة المشاركة المحددة للحساب.
  ///
  /// يعمل للعملية الجديدة (وفق الإعداد المسبق للحساب) ولإعادة الإرسال.
  static Future<TxShareOutcome> sendNow(
    BuildContext context,
    WidgetRef ref, {
    required Tx tx,
    Account? account,
    bool silentIfNoPhone = false,
    String? forceChannel,
  }) async {
    final repo = _repoOf(context, ref);
    final acc = account ??
        (tx.accountId == null ? null : await repo.account(tx.accountId!));

    // نحدد القناة من بيانات الحساب نفسه (أو القناة الممررة صراحة).
    final rawChannel = (forceChannel ?? acc?.notifyChannel ?? 'whatsapp').trim();

    if (rawChannel == 'none') {
      return TxShareOutcome.skipped; // المستخدم فضّل عدم الإرسال التلقائي.
    }

    if (rawChannel == 'system' || rawChannel == 'auto_system') {
      if (!context.mounted) return TxShareOutcome.skipped;
      return shareViaSystemSheet(context, ref, tx: tx, account: acc);
    }

    final isSms = rawChannel == 'sms' || rawChannel == 'auto_sms';
    final phone = _phoneOf(acc, isSms ? 'sms' : 'whatsapp');

    if (phone.isEmpty) {
      if (!silentIfNoPhone) {
        if (!context.mounted) return TxShareOutcome.skipped;
        // إذا كان العميل لا يتضمن رقماً فهذا لا يمنع إظهار خيارات المشاركة من النظام.
        return shareViaSystemSheet(context, ref, tx: tx, account: acc);
      }
      return TxShareOutcome.skipped;
    }

    if (context.mounted) {
      showSnack(
        context,
        isSms
            ? 'جارٍ تجهيز الرسالة وفتح تطبيق الرسائل…'
            : 'جارٍ تجهيز الإيصال وفتح واتساب…',
      );
    }

    late final List<InvoiceLine> itemLines;
    late final Map<String, String> currentSettings;
    try {
      itemLines = tx.id == null
          ? const <InvoiceLine>[]
          : await repo.transactionItems(tx.id!);
      currentSettings = await repo.settings();
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر تحميل بيانات السند: $e', error: true);
      }
      return TxShareOutcome.failed;
    }
    final hasLogo =
        (currentSettings['org.icon.b64'] ?? '').trim().isNotEmpty ||
            (currentSettings['logoBase64'] ?? '').trim().isNotEmpty ||
            (currentSettings['logo'] ?? '').trim().isNotEmpty ||
            (currentSettings['logoPath'] ?? '').trim().isNotEmpty ||
            (currentSettings['account.photoPath'] ?? '').trim().isNotEmpty;
    final needsFreshReceipt =
        tx.type == OpType.debit || itemLines.isNotEmpty || hasLogo;

    late final String text;
    try {
      text = await caption(repo: repo, tx: tx, account: acc);
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر تجهيز نص الإشعار: $e', error: true);
      }
      return TxShareOutcome.failed;
    }

    // === فرع الرسائل النصية ===
    if (isSms) {
      try {
        if (needsFreshReceipt ||
            tx.image.isEmpty ||
            !MediaPaths.exists(tx.image)) {
          unawaited(
            generate(
              repo: repo,
              tx: tx,
              account: acc,
            ).timeout(const Duration(seconds: 5)).then<void>((_) {},
                onError: (Object e, StackTrace st) {
              debugPrint('Receipt generation failed: $e');
            }),
          );
        }
      } catch (_) {}
      final ok = await SmsSender.send(phone: phone, body: text);
      if (context.mounted) {
        _safeBump(context, ref);
        showSnack(
          context,
          ok
              ? 'تم فتح تطبيق الرسائل النصية لمحادثة العميل ✅'
              : 'تعذّر فتح تطبيق الرسائل النصية',
          error: !ok,
        );
      }
      return ok ? TxShareOutcome.opened : TxShareOutcome.failed;
    }

    // === فرع واتساب ===
    String path;
    try {
      if (needsFreshReceipt) {
        path = await generate(repo: repo, tx: tx, account: acc);
      } else if (tx.image.isNotEmpty && MediaPaths.exists(tx.image)) {
        path = MediaPaths.toAbsolute(tx.image);
      } else {
        path = await generate(repo: repo, tx: tx, account: acc);
      }
    } catch (_) {
      if (context.mounted) {
        showSnack(
          context,
          'تعذّر تجهيز صورة السند، لم يتم إرسال إشعار نصي فقط.',
          error: true,
        );
      }
      return TxShareOutcome.failed;
    }

    if (path.isEmpty || !File(path).existsSync()) {
      if (context.mounted) {
        showSnack(
          context,
          'تعذّر العثور على صورة السند، لم يتم إرسال النص وحده.',
          error: true,
        );
      }
      return TxShareOutcome.failed;
    }

    late final WaResult res;
    try {
      final installed = await WhatsApp.installed();
      String? pkg;
      if (rawChannel == 'auto_w4b' && installed.contains('com.whatsapp.w4b')) {
        pkg = 'com.whatsapp.w4b';
      } else if (rawChannel == 'auto_whatsapp' &&
          installed.contains('com.whatsapp')) {
        pkg = 'com.whatsapp';
      } else if (installed.contains('com.whatsapp.w4b')) {
        pkg = 'com.whatsapp.w4b';
      } else if (installed.contains('com.whatsapp')) {
        pkg = null;
      }
      res = await WhatsApp.send(
        phone: phone,
        text: text,
        imagePath: path,
        package: pkg,
      );
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر إرسال السند بالصورة والنص: $e', error: true);
      }
      return TxShareOutcome.failed;
    }

    if (context.mounted) {
      _safeBump(context, ref);
    }
    if (res == WaResult.imageFailed || res == WaResult.error) {
      final shared = await _shareImageWithText(path, text);
      if (context.mounted) {
        showSnack(
          context,
          shared
              ? 'تم فتح مشاركة السند بالصورة والنص.'
              : WhatsApp.messageFor(res),
          error: !shared,
        );
      }
      return shared ? TxShareOutcome.opened : TxShareOutcome.failed;
    } else if (context.mounted && res != WaResult.ok) {
      showSnack(context, WhatsApp.messageFor(res), error: true);
    }
    return res == WaResult.ok ? TxShareOutcome.opened : TxShareOutcome.failed;
  }

  /// مشاركة احتياطية تحفظ الصورة والنص معًا عبر نافذة مشاركة أندرويد.
  static Future<bool> _shareImageWithText(String path, String text) async {
    try {
      await Share.shareXFiles(
        [XFile(path, mimeType: 'image/png')],
        text: text,
        subject: 'سند العملية — إدارة البيانات',
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _phoneOf(Account? a, String channel) {
    if (a == null) return '';
    if (channel == 'sms') return a.phone.trim();
    final w = a.whatsapp.trim();
    return w.isNotEmpty ? w : a.phone.trim();
  }
}

/// نافذة تأكيد نجاح إنشاء العملية (بنمط نافذة نجاح فاتورة المبيعات) مع زر
/// المشاركة عبر نافذة النظام الرسمية وزر معاينة السند.
Future<void> showTxSuccessDialog(
  BuildContext context,
  WidgetRef ref, {
  required Tx tx,
  Account? account,
}) async {
  if (!context.mounted) return;
  final repo = TxShare._repoOf(context, ref);
  final acc = account ??
      (tx.accountId == null ? null : await repo.account(tx.accountId!));
  final currencies = await repo.currencies();
  final cur = currencies.firstWhere(
    (c) => c.code == tx.currency,
    orElse: () => kDefaultCurrencies.first,
  );
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _TxSuccessDialog(
      tx: tx,
      account: acc,
      currency: cur,
    ),
  );
}

class _TxSuccessDialog extends ConsumerStatefulWidget {
  final Tx tx;
  final Account? account;
  final CurrencyDef currency;

  const _TxSuccessDialog({
    required this.tx,
    required this.account,
    required this.currency,
  });

  @override
  ConsumerState<_TxSuccessDialog> createState() => _TxSuccessDialogState();
}

class _TxSuccessDialogState extends ConsumerState<_TxSuccessDialog> {
  bool _sharing = false;

  Future<void> _onSharePressed() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await TxShare.shareViaSystemSheet(
        context,
        ref,
        tx: widget.tx,
        account: widget.account,
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) {
        setState(() => _sharing = false);
      }
    }
  }

  Future<void> _onPreviewPressed() async {
    if (_sharing) return;
    final rootCtx = Navigator.of(context, rootNavigator: true).context;
    Navigator.of(context).pop();
    if (rootCtx.mounted) {
      await showReceiptPreview(
        rootCtx,
        ref,
        tx: widget.tx,
        account: widget.account,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tx = widget.tx;
    final acc = widget.account;
    final cur = widget.currency;
    final refNum = tx.reference.trim().isNotEmpty
        ? tx.reference.trim()
        : (tx.id != null ? '${tx.id}' : '');

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.check_circle, color: AppColors.green),
          SizedBox(width: 8),
          Expanded(child: Text('تمت العملية بنجاح ✅')),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('نوع العملية: ${tx.type.icon} ${tx.type.label}'),
          if (refNum.isNotEmpty) Text('رقم المرجع / السند: #$refNum'),
          if (acc != null) Text('الحساب / العميل: ${acc.name}'),
          const SizedBox(height: 6),
          Text(
            'المبلغ: ${Fmt.money(tx.amount, cur.decimal)} ${cur.symbol}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Text(
            'يمكنك مشاركة إشعار العملية مع صورة السند عالية الدقة عبر نافذة مشاركة النظام (واتساب، الرسائل النصية، وغيرها):',
            style: TextStyle(fontSize: 13),
          ),
        ],
      ),
      actions: [
        OutlinedButton.icon(
          icon: const Icon(Icons.receipt_long_outlined),
          label: const Text('معاينة السند'),
          onPressed: _sharing ? null : _onPreviewPressed,
        ),
        FilledButton.icon(
          icon: _sharing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.share_outlined),
          label: Text(_sharing ? 'جارٍ التجهيز…' : 'مشاركة'),
          onPressed: _sharing ? null : _onSharePressed,
        ),
        TextButton(
          onPressed: _sharing ? null : () => Navigator.of(context).pop(),
          child: const Text('إغلاق'),
        ),
      ],
    );
  }
}

/// معاينة صورة الإيصال مع أزرار الإرسال وإعادة التوليد.
Future<void> showReceiptPreview(
  BuildContext context,
  WidgetRef ref, {
  required Tx tx,
  Account? account,
}) async {
  if (!context.mounted) return;
  final repo = TxShare._repoOf(context, ref);
  final acc = account ??
      (tx.accountId == null ? null : await repo.account(tx.accountId!));
  var path = MediaPaths.toAbsolute(tx.image);
  final itemLines = tx.id == null
      ? const <InvoiceLine>[]
      : await repo.transactionItems(tx.id!);
  final currentSettings = await repo.settings();
  final hasLogo = (currentSettings['org.icon.b64'] ?? '').trim().isNotEmpty ||
      (currentSettings['logoBase64'] ?? '').trim().isNotEmpty ||
      (currentSettings['logo'] ?? '').trim().isNotEmpty ||
      (currentSettings['logoPath'] ?? '').trim().isNotEmpty ||
      (currentSettings['account.photoPath'] ?? '').trim().isNotEmpty;
  final needsFreshReceipt =
      tx.type == OpType.debit || itemLines.isNotEmpty || hasLogo;
  try {
    if (path.isEmpty || !File(path).existsSync() || needsFreshReceipt) {
      path = await TxShare.generate(repo: repo, tx: tx, account: acc);
    }
  } catch (e) {
    if (context.mounted) {
      showSnack(context, 'تعذّر تجهيز صورة الإيصال: $e', error: true);
    }
    return;
  }
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => Consumer(
      builder: (sheetCtx, sheetRef, _) => DraggableScrollableSheet(
        initialChildSize: .85,
        expand: false,
        builder: (ctx, controller) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(
                children: [
                  Icon(Icons.image_outlined, color: AppColors.primaryOf(ctx)),
                  const SizedBox(width: 8),
                  Text(
                    'إيصال العملية',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: controller,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.file(File(path)),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          try {
                            await TxShare.generate(
                              repo: repo,
                              tx: tx,
                              account: acc,
                            );
                            if (context.mounted) {
                              TxShare._safeBump(context, sheetRef);
                              showSnack(context, 'أُعيد توليد الصورة');
                            }
                          } catch (e) {
                            if (context.mounted) {
                              showSnack(
                                context,
                                'تعذّرت إعادة توليد الصورة: $e',
                                error: true,
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('إعادة التوليد'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () async {
                          await TxShare.shareViaSystemSheet(
                            sheetCtx,
                            sheetRef,
                            tx: tx.copyWith(image: path),
                            account: acc,
                          );
                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                          }
                        },
                        icon: const Icon(Icons.share_outlined),
                        label: const Text('مشاركة السند'),
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
