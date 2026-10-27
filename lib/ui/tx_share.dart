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

  /// المسار الكامل: عرض خيارات المشاركة (واتساب العادي، واتساب الأعمال،
  /// الرسائل النصية SMS، أو مشاركة صورة السند) والدخول المباشر لمحادثة العميل.
  static Future<TxShareOutcome> sendNow(
    BuildContext context,
    WidgetRef ref, {
    required Tx tx,
    Account? account,
    bool silentIfNoPhone = false,
  }) async {
    final repo = ref.read(repoProvider);
    final acc = account ??
        (tx.accountId == null ? null : await repo.account(tx.accountId!));

    final channel = (acc?.notifyChannel ?? 'whatsapp').trim();
    final initialPhone = _phoneOf(acc, channel);

    if (channel == 'none' && silentIfNoPhone) {
      return TxShareOutcome.skipped;
    }

    if (initialPhone.isEmpty && silentIfNoPhone) {
      return TxShareOutcome.skipped;
    }

    if (!context.mounted) return TxShareOutcome.skipped;

    // نولّد صورة السند في الخلفية دائماً لحفظها مع العملية دون إعاقة فتح المحادثة.
    unawaited(
      generate(repo: repo, tx: tx, account: acc)
          .timeout(const Duration(seconds: 6))
          .then<void>((_) {}, onError: (Object e, StackTrace st) {
        debugPrint('Background receipt generation failed: $e');
      }),
    );

    final choice = await _showShareOptionsSheet(
      context,
      accountName: acc?.name ?? 'عميل نقدي',
      initialPhone: initialPhone,
      preferredChannel: channel,
    );

    if (choice == null || !context.mounted) {
      return TxShareOutcome.skipped;
    }

    final phone = choice.phone.trim();
    if (phone.isEmpty && choice.mode != _ShareMode.imageShare) {
      showSnack(
        context,
        'يرجى إدخال رقم هاتف العميل لإرسال الإشعار',
        error: true,
      );
      return TxShareOutcome.skipped;
    }

    late final String text;
    try {
      text = await caption(repo: repo, tx: tx, account: acc);
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر تجهيز نص الإشعار: $e', error: true);
      }
      return TxShareOutcome.failed;
    }

    // 1) الرسائل النصية SMS المباشرة
    if (choice.mode == _ShareMode.sms) {
      final ok = await SmsSender.send(phone: phone, body: text);
      bump(ref);
      if (context.mounted) {
        showSnack(
          context,
          ok
              ? 'تم فتح محادثة الرسائل النصية للعميل بنجاح'
              : 'تعذّر فتح تطبيق الرسائل النصية',
          error: !ok,
        );
      }
      return ok ? TxShareOutcome.opened : TxShareOutcome.failed;
    }

    // 2) واتساب العادي أو واتساب الأعمال — دخول مباشر لمحادثة العميل
    if (choice.mode == _ShareMode.whatsappDirect ||
        choice.mode == _ShareMode.whatsappBusinessDirect) {
      final targetPkg = choice.mode == _ShareMode.whatsappBusinessDirect
          ? 'com.whatsapp.w4b'
          : 'com.whatsapp';
      try {
        final res = await WhatsApp.send(
          phone: phone,
          text: text,
          imagePath: null, // بدون مسار صورة للدخول المباشر لمحادثة العميل فوراً
          package: targetPkg,
        );
        bump(ref);
        if (context.mounted && res != WaResult.ok) {
          showSnack(context, WhatsApp.messageFor(res), error: true);
        }
        return res == WaResult.ok
            ? TxShareOutcome.opened
            : TxShareOutcome.failed;
      } catch (e) {
        if (context.mounted) {
          showSnack(context, 'تعذّر فتح محادثة واتساب: $e', error: true);
        }
        return TxShareOutcome.failed;
      }
    }

    // 3) إرفاق ومشاركة صورة السند مع النص
    String path;
    try {
      path = await generate(repo: repo, tx: tx, account: acc);
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر تجهيز صورة السند: $e', error: true);
      }
      return TxShareOutcome.failed;
    }

    if (path.isEmpty || !File(path).existsSync()) {
      if (context.mounted) {
        showSnack(context, 'تعذّر العثور على صورة السند', error: true);
      }
      return TxShareOutcome.failed;
    }

    final shared = await _shareImageWithText(path, text);
    bump(ref);
    if (context.mounted) {
      showSnack(
        context,
        shared
            ? 'تم فتح نافذة مشاركة السند بالصورة والنص'
            : 'تعذّر مشاركة صورة السند',
        error: !shared,
      );
    }
    return shared ? TxShareOutcome.opened : TxShareOutcome.failed;
  }

  static Future<_ShareChoice?> _showShareOptionsSheet(
    BuildContext context, {
    required String accountName,
    required String initialPhone,
    required String preferredChannel,
  }) async {
    final phoneCtrl = TextEditingController(text: initialPhone);
    return showModalBottomSheet<_ShareChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E2430) : Colors.white,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(22),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFF1E88E5).withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: const Icon(
                            Icons.send_rounded,
                            color: Color(0xFF1E88E5),
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'إرسال إشعار العملية للعميل',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                'العميل: $accountName — اختر وسيلة الإرسال للدخول المباشر للمحادثة',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: isDark
                                      ? Colors.white70
                                      : const Color(0xFF64748B),
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close, size: 20),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: phoneCtrl,
                      keyboardType: TextInputType.phone,
                      textDirection: TextDirection.ltr,
                      decoration: InputDecoration(
                        labelText: 'رقم هاتف / واتساب العميل',
                        hintText: 'مثال: 777123456',
                        prefixIcon: const Icon(Icons.phone_outlined, size: 19),
                        isDense: true,
                        filled: true,
                        fillColor: isDark
                            ? Colors.white.withValues(alpha: 0.05)
                            : const Color(0xFFF8FAFC),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _ShareOptionTile(
                      icon: Icons.chat_rounded,
                      iconColor: const Color(0xFF16A34A),
                      title: 'واتساب (WhatsApp)',
                      subtitle: 'فتح محادثة العميل مباشرة مع تفاصيل الفاتورة/السند',
                      highlighted: preferredChannel != 'sms',
                      onTap: () => Navigator.pop(
                        ctx,
                        _ShareChoice(
                          mode: _ShareMode.whatsappDirect,
                          phone: phoneCtrl.text,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _ShareOptionTile(
                      icon: Icons.storefront_rounded,
                      iconColor: const Color(0xFF00897B),
                      title: 'واتساب الأعمال (WhatsApp Business)',
                      subtitle: 'الدخول المباشر لمحادثة العميل عبر واتساب الأعمال',
                      onTap: () => Navigator.pop(
                        ctx,
                        _ShareChoice(
                          mode: _ShareMode.whatsappBusinessDirect,
                          phone: phoneCtrl.text,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _ShareOptionTile(
                      icon: Icons.sms_outlined,
                      iconColor: const Color(0xFF1E88E5),
                      title: 'الرسائل النصية (SMS)',
                      subtitle: 'إرسال تفاصيل العملية برسالة نصية مباشرة لرقم العميل',
                      highlighted: preferredChannel == 'sms',
                      onTap: () => Navigator.pop(
                        ctx,
                        _ShareChoice(
                          mode: _ShareMode.sms,
                          phone: phoneCtrl.text,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _ShareOptionTile(
                      icon: Icons.image_outlined,
                      iconColor: const Color(0xFF7C3AED),
                      title: 'مشاركة صورة السند مع النص',
                      subtitle: 'إرفاق صورة السند الرسمي عبر نافذة المشاركة',
                      onTap: () => Navigator.pop(
                        ctx,
                        _ShareChoice(
                          mode: _ShareMode.imageShare,
                          phone: phoneCtrl.text,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// مشاركة احتياطية تحفظ الصورة والنص معًا عبر نافذة مشاركة أندرويد.
  static Future<bool> _shareImageWithText(String path, String text) async {
    try {
      await Share.shareXFiles(
        [XFile(path)],
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

enum _ShareMode {
  whatsappDirect,
  whatsappBusinessDirect,
  sms,
  imageShare,
}

class _ShareChoice {
  final _ShareMode mode;
  final String phone;
  const _ShareChoice({required this.mode, required this.phone});
}

class _ShareOptionTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool highlighted;
  final VoidCallback onTap;

  const _ShareOptionTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isDark ? const Color(0xFF262D3D) : Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: highlighted
                  ? iconColor.withValues(alpha: 0.65)
                  : (isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : const Color(0xFFE2E8F0)),
              width: highlighted ? 1.4 : 1.0,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, color: iconColor, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? Colors.white60
                            : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 14,
                color: isDark ? Colors.white38 : const Color(0xFF94A3B8),
              ),
            ],
          ),
        ),
      ),
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
  final repo = ref.read(repoProvider);
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
    builder: (_) => DraggableScrollableSheet(
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
                          bump(ref);
                          if (context.mounted) {
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
                      onPressed: () {
                        Navigator.pop(ctx);
                        TxShare.sendNow(
                          context,
                          ref,
                          tx: tx.copyWith(image: path),
                          account: acc,
                        );
                      },
                      icon: const Icon(Icons.send),
                      label: const Text('إرسال واتساب'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
