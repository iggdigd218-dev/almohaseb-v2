import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/keep_alive_service.dart';
import '../core/media_paths.dart';
import '../core/models.dart';
import '../core/sfx.dart';
import '../core/receipt_image.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'calculator.dart';
import 'pos_screen.dart';
import 'tx_share.dart';
import 'widgets.dart';

/// يفتح نموذج العملية المالية (إضافة / تعديل / تكرار) كبطاقة مدمجة تعلو الكيبورد.
Future<Object?> openTxForm(
  BuildContext context,
  WidgetRef ref, {
  Tx? existing,
  int? presetAccountId,
  bool isCopy = false,
  OpType? presetType,
}) =>
    showDialog<Object>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        clipBehavior: Clip.antiAlias,
        backgroundColor: AppColors.surfaceOf(ctx),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: TxForm(
            existing: existing,
            presetAccountId: presetAccountId,
            isCopy: isCopy,
            presetType: presetType,
          ),
        ),
      ),
    );

class TxForm extends ConsumerStatefulWidget {
  final Tx? existing;
  final int? presetAccountId;
  final bool isCopy;
  final OpType? presetType;
  const TxForm({
    super.key,
    this.existing,
    this.presetAccountId,
    this.isCopy = false,
    this.presetType,
  });

  @override
  ConsumerState<TxForm> createState() => _TxFormState();
}

class _TxFormState extends ConsumerState<TxForm> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _rate = TextEditingController(text: '1');
  final _desc = TextEditingController();
  final _ref = TextEditingController();
  final _notes = TextEditingController();

  OpType _type = OpType.debit;
  int? _accountId;
  int? _toId;
  String _currency = 'YER';
  String _sign = '+';
  String _status = 'done';
  DateTime _date = DateTime.now();

  List<Account> _accounts = [];
  List<CurrencyDef> _currencies = [];

  /// العملة الأساسية = الأولى في قائمة العملات (سعرها 1 دوماً).
  String get _baseCurrencyCode =>
      _currencies.isNotEmpty ? _currencies.first.code : 'YER';
  List<InvoiceLine> _invoiceLines = [];
  bool _loading = true;
  bool _saving = false;
  bool _saveSlow = false;

  /// مسار الصورة المرفقة بالعملية (اختياري).
  String _image = '';

  /// (3.98.40 / الملاحظة 2) الاقتراحات الذكية التلقائية لحقل البيان / الوصف
  List<String> _descSuggestions = [];
  bool _fetchingDescSuggestions = false;

  @override
  void initState() {
    super.initState();
    _desc.addListener(_onDescChanged);
    _load();
  }

  void _onDescChanged() {
    _fetchDescSuggestions();
  }

  Future<void> _fetchDescSuggestions() async {
    final text = _desc.text.trim();
    if (text.isEmpty) {
      if (_descSuggestions.isNotEmpty && mounted) {
        setState(() => _descSuggestions = []);
      }
      return;
    }
    if (_fetchingDescSuggestions) return;
    _fetchingDescSuggestions = true;
    try {
      final repo = ref.read(repoProvider);
      final suggestions = await repo.transactionDescriptionSuggestions(
        query: text,
        accountId: _accountId,
        limit: 6,
      );
      if (mounted) {
        setState(() {
          _descSuggestions = suggestions.where((s) => s != text).toList();
        });
      }
    } catch (_) {
    } finally {
      _fetchingDescSuggestions = false;
    }
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(repoProvider);
      final accs = await repo.accounts(includeArchived: true);
      final curs = await repo.currencies();
      final t = widget.existing;
      final invoiceLines = t?.id == null
          ? const <InvoiceLine>[]
          : await repo.transactionItems(t!.id!);

      _accounts = accs;
      _currencies = curs;

      if (t != null) {
        _type = t.type;
        _accountId = t.type == OpType.transfer ? t.fromId : t.accountId;
        _toId = t.toId;
        _currency = t.currency;
        _sign = t.sign.isEmpty ? '+' : t.sign;
        _status = t.status;
        _image = MediaPaths.toAbsolute(t.image);
        _date = t.date;
        _amount.text = Fmt.money(t.amount, 2).replaceAll(',', '');
        _rate.text = '${t.rate}';
        _desc.text = t.description;
        _ref.text = widget.isCopy ? '' : t.reference;
        _notes.text = t.notes;
        _invoiceLines = invoiceLines;
      } else {
        if (widget.presetType != null) {
          _type = widget.presetType!;
        } else {
          final s = await repo.settings();
          final mapped = {
            'inflow': OpType.inflow,
            'outflow': OpType.outflow,
            'debit': OpType.debit,
            'credit': OpType.credit,
            'revenue': OpType.revenue,
            'expense': OpType.expense,
          };
          final def = s['defaultOp'];
          if (def != null && mapped.containsKey(def)) _type = mapped[def]!;
          final defNotes = s['defaultVoucherNotes']?.trim();
          if (defNotes != null && defNotes.isNotEmpty) {
            _notes.text = defNotes;
          }
        }
        _accountId =
            widget.presetAccountId ?? (accs.isNotEmpty ? accs.first.id : null);
      }

      final acc = accs.where((a) => a.id == _accountId).firstOrNull;
      if (t == null && acc != null) _currency = acc.currency;
    } catch (e) {
      if (mounted) {
        Sfx.error();
        showSnack(
          context,
          'تعذّر تحميل البيانات: $e',
          error: true,
          silent: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _desc.removeListener(_onDescChanged);
    _amount.dispose();
    _rate.dispose();
    _desc.dispose();
    _ref.dispose();
    _notes.dispose();
    super.dispose();
  }

  Account? get _account =>
      _accounts.where((a) => a.id == _accountId).firstOrNull;

  bool get _isTransfer => _type == OpType.transfer;

  /// تفاصيل فاتورة المبيعات (الأصناف) تظهر فقط لعمليات البيع (قبض أو عليه).
  bool get _hasInvoiceDetails =>
      _type == OpType.debit || _type == OpType.inflow;

  void _openPosShortcut() {
    if (_saving) return;
    Sfx.click();
    final nav = Navigator.of(context);
    nav.pop();
    nav.push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('🛒 المبيعات')),
          body: const PosScreen(),
        ),
      ),
    );
  }

  Future<void> _save() async {
    // Acquire the lock synchronously, before unfocus/validation awaits.
    if (_saving || !mounted) return;
    setState(() {
      _saving = true;
      _saveSlow = false;
    });
    Timer? slowWarning;
    int? savedId;
    try {
      FocusScope.of(context).unfocus();
      if (!Sfx.muted) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!mounted) return;
      final form = _formKey.currentState;
      if (form == null || !form.validate()) {
        Sfx.reject();
        return;
      }
      form.save();
      if (_accountId == null) throw StateError('اختر الحساب');
      if (_isTransfer && (_toId == null || _toId == _accountId)) {
        throw StateError('اختر حساب الوجهة (مختلفًا عن المصدر)');
      }
      final amount = Fmt.parseAmount(_amount.text);
      if (amount == null || amount <= 0) {
        throw StateError('أدخل مبلغًا صحيحًا أكبر من صفر');
      }
      final rate = Fmt.parseAmount(_rate.text);
      if (_isTransfer && (rate == null || rate <= 0)) {
        throw StateError('أدخل سعر صرف صحيحًا أكبر من صفر');
      }
      final repo = ref.read(repoProvider);
      final now = DateTime.now();
      final old = widget.existing;
      final keepId = old != null && !widget.isCopy ? old.id : null;
      final me = ref.read(currentUserProvider).valueOrNull;
      final tx = Tx(
        id: keepId,
        accountId: _isTransfer ? null : _accountId,
        accountKind: _account?.kind ?? AccountKind.general,
        type: _type,
        amount: amount,
        currency: _currency,
        sign: _type == OpType.settle ? _sign : '',
        fromId: _isTransfer ? _accountId : null,
        toId: _isTransfer ? _toId : null,
        rate: rate ?? 1,
        description: _desc.text.trim(),
        reference: _ref.text.trim(),
        notes: _notes.text.trim(),
        image: _image,
        status: _status,
        date: _date,
        createdByUserId: old?.createdByUserId ?? me?.id,
        cashierName: old?.cashierName ?? me?.name ?? '',
        createdAt: keepId != null ? old!.createdAt : now,
        updatedAt: now,
      );
      if (keepId == null) {
        List<Tx> duplicates = const [];
        try {
          duplicates =
              await repo.findDuplicates(tx).timeout(const Duration(seconds: 3));
        } catch (_) {
          // Advisory only; the in-flight lock is independent of this lookup.
        }
        if (!mounted) return;
        if (duplicates.isNotEmpty) {
          final proceed = await confirmDialog(context,
              title: '⚠️ عملية مكررة محتملة',
              message:
                  'توجد ${duplicates.length} عملية مماثلة. هل تريد المتابعة؟',
              confirmText: 'متابعة');
          if (proceed != true || !mounted) return;
        }
      }
      final saleLines =
          _hasInvoiceDetails ? _invoiceLines : const <InvoiceLine>[];
      if (!Sfx.muted) {
        slowWarning = Timer(const Duration(seconds: 10), () {
          if (mounted) setState(() => _saveSlow = true);
        });
      }
      final shouldDeduct =
          (_type == OpType.inflow || _type == OpType.debit) &&
              saleLines.isNotEmpty;
      savedId = await repo.saveTx(
        tx,
        items: saleLines,
        deductStock: shouldDeduct,
      );
      slowWarning?.cancel();
      if (mounted) bump(ref);

      var saved = tx.copyWith(id: savedId);
      try {
        final lookup = repo.transactionById(savedId);
        saved = await (Sfx.muted
                ? lookup
                : lookup.timeout(const Duration(seconds: 2))) ??
            saved;
      } catch (_) {}
      final targetAcc = _account;
      final autoShare =
          !_isTransfer && keepId == null && TxShare.isAutoShareConfigured(targetAcc);
      var share = TxShareOutcome.skipped;
      if (autoShare && targetAcc != null && mounted) {
        try {
          share = await TxShare.sendNow(context, ref,
                  tx: saved, account: targetAcc, silentIfNoPhone: false)
              .timeout(const Duration(seconds: 15));
        } catch (_) {
          share = TxShareOutcome.failed;
        }
      } else if (!_isTransfer && !Sfx.muted) {
        unawaited(
          TxShare.generate(repo: repo, tx: saved, account: targetAcc)
              .then<void>((_) {}, onError: (Object _, StackTrace __) {}),
        );
      }
      if (!mounted) return;
      bump(ref);
      final rootNavContext =
          Navigator.of(context, rootNavigator: true).context;
      final message = StringBuffer(keepId != null
          ? 'تم تعديل العملية وتحديث الرصيد ✅'
          : 'تم حفظ العملية وتحديث الرصيد ✅');
      if (share == TxShareOutcome.opened) {
        message.write(' — تم فتح تطبيق المشاركة');
      }
      if (share == TxShareOutcome.failed) {
        message.write(' — تعذّر فتح المشاركة؛ الحفظ المحلي ناجح');
      }
      showSnack(context, message.toString(),
          error: share == TxShareOutcome.failed, silent: true);
      Navigator.pop(context, true);
      if (widget.existing == null || widget.isCopy) {
        Sfx.opCreated();
        if (!autoShare && !Sfx.muted && rootNavContext.mounted) {
          unawaited(
            showTxSuccessDialog(
              rootNavContext,
              ref,
              tx: saved,
              account: targetAcc,
            ),
          );
        }
      } else {
        Sfx.success();
      }
    } catch (e) {
      if (!mounted) return;
      Sfx.error();
      if (savedId != null) {
        bump(ref);
        showSnack(context, 'تم الحفظ محليًا، لكن تعذّر إكمال خطوة لاحقة: $e',
            error: true);
        Navigator.pop(context, true);
      } else {
        showSnack(
            context, e is StateError ? e.message : 'تعذّر حفظ العملية: $e',
            error: true, silent: true);
      }
    } finally {
      slowWarning?.cancel();
      if (mounted) {
        setState(() {
          _saving = false;
          _saveSlow = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 220,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_accounts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const EmptyState(
              icon: Icons.person_off_outlined,
              title: 'لا توجد حسابات',
              message: 'أضف حسابًا أولًا قبل تسجيل أي عملية.',
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('حسنًا'),
            ),
          ],
        ),
      );
    }
    final title = widget.isCopy
        ? '🔁 تكرار عملية'
        : (widget.existing != null ? '✏️ تعديل عملية' : '＋ عملية جديدة');
    return PopScope(
      canPop: !_saving,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ترويسة زرقاء مدمجة مع أيقونة فاتورة مبيعات وزر الإغلاق X
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [Color(0xFF1E3A5F), AppColors.primary],
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.edit_note_rounded,
                    color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                ),
                if (_hasInvoiceDetails)
                  IconButton(
                    tooltip: 'فتح شاشة المبيعات لإضافة الفاتورة',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    padding: EdgeInsets.zero,
                    icon: const Icon(
                      Icons.point_of_sale_rounded,
                      color: Colors.white,
                      size: 19,
                    ),
                    onPressed: _saving ? null : _openPosShortcut,
                  ),
                const SizedBox(width: 4),
                InkWell(
                  onTap: _saving ? null : () => Navigator.pop(context),
                  borderRadius: BorderRadius.circular(20),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: Form(
              key: _formKey,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ══ الصف 1: نوع العملية (بارتفاع 38px: عليه 🔴 | له 🟢 | أخرى ▾) ══
                    _compactTypeBar(),
                    const SizedBox(height: 8),

                    // ══ الصف 2: الحساب + التاريخ في صف واحد ══
                    _accountAndDateRow(),
                    const SizedBox(height: 8),

                    // ══ الصف 3: المبلغ + العملة في صف واحد ══
                    _amountRow(),
                    const SizedBox(height: 8),

                    // ══ الصف 4: البيان / الوصف + أيقونة الكاميرا/المعرض المدمجة ══
                    _descriptionWithImageField(),

                    if (_saveSlow)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'الحفظ أبطأ من المعتاد. ننتظر نتيجة قاعدة البيانات؛ لا تُكرر العملية.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.orange, fontSize: 12),
                        ),
                      ),
                    const SizedBox(height: 10),

                    // زر «حفظ العملية» بعرض النافذة بالكامل (بدون زر إلغاء سفلي)
                    SizedBox(
                      width: double.infinity,
                      height: 42,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        onPressed: _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.save_outlined, size: 19),
                        label: Text(
                          _saving ? 'جارٍ الحفظ...' : 'حفظ العملية',
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

  /// الصف الأول: شريط أزرار نحيف ومدمج بارتفاع 38px يضم [عليه 🔴] و[له 🟢] و[أخرى ▾].
  Widget _compactTypeBar() {
    final isAlayh = _type == OpType.debit;
    final isLahu = _type == OpType.credit;
    final isOther = !isAlayh && !isLahu;
    const otherTypes = <OpType>[
      OpType.transfer,
      OpType.expense,
      OpType.settle,
      OpType.inflow,
      OpType.outflow,
      OpType.revenue,
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 38,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 4,
                child: InkWell(
                  onTap: () => setState(() => _type = OpType.debit),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isAlayh
                          ? Colors.red.withValues(alpha: 0.12)
                          : AppColors.surface2Of(context),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color:
                            isAlayh ? Colors.red : AppColors.borderOf(context),
                        width: isAlayh ? 1.8 : 1,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('🔴', style: TextStyle(fontSize: 13)),
                        const SizedBox(width: 5),
                        Text(
                          'عليه',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            color: isAlayh
                                ? Colors.red.shade800
                                : AppColors.textOf(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 4,
                child: InkWell(
                  onTap: () => setState(() => _type = OpType.credit),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isLahu
                          ? Colors.green.withValues(alpha: 0.12)
                          : AppColors.surface2Of(context),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color:
                            isLahu ? Colors.green : AppColors.borderOf(context),
                        width: isLahu ? 1.8 : 1,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('🟢', style: TextStyle(fontSize: 13)),
                        const SizedBox(width: 5),
                        Text(
                          'له',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            color: isLahu
                                ? Colors.green.shade800
                                : AppColors.textOf(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 3,
                child: PopupMenuButton<OpType>(
                  tooltip: 'أنواع عمليات أخرى',
                  onSelected: (t) => setState(() => _type = t),
                  itemBuilder: (_) => [
                    for (final t in otherTypes)
                      PopupMenuItem<OpType>(
                        value: t,
                        height: 36,
                        child: Row(
                          children: [
                            Text(t.icon, style: const TextStyle(fontSize: 14)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                t.label,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: _type == t
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: isOther
                          ? AppColors.primaryOf(context).withValues(alpha: 0.12)
                          : AppColors.surface2Of(context),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isOther
                            ? AppColors.primaryOf(context)
                            : AppColors.borderOf(context),
                        width: isOther ? 1.8 : 1,
                      ),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            isOther ? _type.label : 'أخرى',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: isOther
                                  ? AppColors.primaryOf(context)
                                  : AppColors.text2Of(context),
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            Icons.arrow_drop_down_rounded,
                            size: 18,
                            color: isOther
                                ? AppColors.primaryOf(context)
                                : AppColors.text2Of(context),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_type == OpType.settle) ...[
          const SizedBox(height: 6),
          _signPicker(),
        ],
      ],
    );
  }

  /// الصف الثاني: قائمة «الحساب» وبجوارها في نفس الصف زر اختيار «التاريخ».
  Widget _accountAndDateRow() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 6,
              child: DropdownButtonFormField<int>(
                initialValue: _accountId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: _isTransfer ? 'من حساب' : 'الحساب',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                ),
                items: _accounts
                    .map(
                      (a) => DropdownMenuItem(
                        value: a.id,
                        child: Text(
                          '${a.kind.icon} ${a.name}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  setState(() {
                    _accountId = v;
                    if (_toId == v) _toId = null;
                    final acc = _account;
                    if (acc != null && widget.existing == null) {
                      _currency = acc.currency;
                    }
                  });
                },
                validator: (v) => v == null ? 'اختر الحساب' : null,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 4,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(2015),
                    lastDate: DateTime(2100),
                  );
                  if (d != null) setState(() => _date = d);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'التاريخ',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 9,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.event_outlined,
                        size: 15,
                        color: AppColors.primaryOf(context),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          Fmt.date(_date),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
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
        if (_isTransfer) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            key: ValueKey('to_$_accountId'),
            initialValue: _toId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'إلى حساب',
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            ),
            items: _accounts
                .where((a) => a.id != _accountId)
                .map(
                  (a) => DropdownMenuItem(
                    value: a.id,
                    child: Text(
                      '${a.kind.icon} ${a.name}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => _toId = v),
            validator: (v) => v == null ? 'اختر حساب الوجهة' : null,
          ),
        ],
      ],
    );
  }

  /// الصف الثالث: حقل «المبلغ *» وبجواره قائمة «العملة» المختصرة.
  Widget _amountRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 6,
          child: TextFormField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: const [ThousandsFormatter()],
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              labelText: 'المبلغ *',
              hintText: '0.00',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              suffixIcon: IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                tooltip: 'آلة حاسبة',
                icon: const Icon(Icons.calculate_outlined, size: 18),
                onPressed: () async {
                  final v = await openCalculator(
                    context,
                    initial: _amount.text,
                  );
                  if (v == null) return;
                  setState(() {
                    _amount.text =
                        v == v.roundToDouble() ? '${v.toInt()}' : '$v';
                  });
                },
              ),
            ),
            validator: (v) {
              final n = Fmt.parseAmount(v ?? '');
              if (n == null || n <= 0) return 'مبلغ غير صالح';
              return null;
            },
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 4,
          child: DropdownButtonFormField<String>(
            initialValue: _currencies.any((c) => c.code == _currency)
                ? _currency
                : (_currencies.isNotEmpty ? _currencies.first.code : null),
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'العملة',
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            ),
            items: _currencies
                .map(
                  (c) => DropdownMenuItem(
                    value: c.code,
                    child: Text(
                      '${c.symbol} ${c.code}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) async {
              setState(() => _currency = v ?? _currency);
              if (!_isTransfer && _currency != _baseCurrencyCode) {
                try {
                  final st = await ref.read(repoProvider).settings();
                  final r = st['rate_$_currency'];
                  if (r != null && mounted) {
                    setState(() => _rate.text = r);
                  }
                } catch (_) {}
              }
            },
          ),
        ),
        if (_isTransfer || _currency != _baseCurrencyCode) ...[
          const SizedBox(width: 6),
          Expanded(
            flex: 3,
            child: TextFormField(
              controller: _rate,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'الصرف',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 10,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// الصف الرابع: حقل «البيان / الوصف» وبداخله في طرفه الأيسر أيقونة الكاميرا/المعرض لإرفاق صورة
  /// مع شريط اقتراحات ذكي وسريع مدمج من العمليات السابقة.
  Widget _descriptionWithImageField() {
    final hasImage = _image.isNotEmpty && File(_image).existsSync();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextFormField(
          controller: _desc,
          style: const TextStyle(fontSize: 13.5),
          decoration: InputDecoration(
            isDense: true,
            labelText: 'البيان / الوصف',
            hintText: 'وصف مختصر (اختياري)',
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 10,
            ),
            suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 34),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasImage) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: Image.file(
                      File(_image),
                      width: 24,
                      height: 24,
                      fit: BoxFit.cover,
                      cacheWidth: crispCacheWidth(context, 24),
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'إزالة الصورة',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: AppColors.dangerOf(context),
                    ),
                    onPressed: () => setState(() => _image = ''),
                  ),
                ],
                PopupMenuButton<String>(
                  tooltip: 'إرفاق صورة',
                  onSelected: (v) {
                    if (v == 'camera') {
                      _captureImage();
                    } else if (v == 'gallery') {
                      _pickImage();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem<String>(
                      value: 'camera',
                      height: 36,
                      child: Row(
                        children: [
                          Icon(Icons.photo_camera_outlined, size: 18),
                          SizedBox(width: 8),
                          Text('التقاط بالكاميرا', style: TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'gallery',
                      height: 36,
                      child: Row(
                        children: [
                          Icon(Icons.photo_library_outlined, size: 18),
                          SizedBox(width: 8),
                          Text('اختيار من المعرض', style: TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(
                      hasImage
                          ? Icons.photo_camera_back_rounded
                          : Icons.camera_alt_outlined,
                      size: 19,
                      color: AppColors.primaryOf(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
          textInputAction: TextInputAction.done,
        ),
        if (_descSuggestions.isNotEmpty) ...[
          const SizedBox(height: 5),
          SizedBox(
            height: 27,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _descSuggestions.length,
              separatorBuilder: (_, __) => const SizedBox(width: 5),
              itemBuilder: (ctx, i) {
                final s = _descSuggestions[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () {
                    _desc.text = s;
                    _desc.selection = TextSelection.fromPosition(
                      TextPosition(offset: s.length),
                    );
                    setState(() => _descSuggestions = []);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.surface2Of(context),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: AppColors.primaryOf(context).withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.history_rounded,
                          size: 13,
                          color: AppColors.primaryOf(context),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          s,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textOf(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _pickImage() async {
    final x = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
    );
    if (x == null) return;
    final saved = await saveImageBytes(await x.readAsBytes(), prefix: 'tx');
    if (mounted) setState(() => _image = saved);
  }

  Future<void> _captureImage() async {
    try {
      if (!await NexKeepAlive.hasPermission(NexKeepAlive.permCamera)) {
        final granted =
            await NexKeepAlive.requestPermission(NexKeepAlive.permCamera);
        if (!granted) return;
      }
      final x = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 82,
      );
      if (x == null) return;
      final saved = await saveImageBytes(await x.readAsBytes(), prefix: 'tx');
      if (mounted) setState(() => _image = saved);
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر فتح الكاميرا', error: true);
    }
  }

  Widget _signPicker() {
    return RadioGroup<String>(
      groupValue: _sign,
      onChanged: (v) {
        if (v != null) setState(() => _sign = v);
      },
      child: const Row(
        children: [
          Expanded(
            child: RadioListTile<String>(
              value: '+',
              title: Text(
                'بالزيادة (+)',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
          Expanded(
            child: RadioListTile<String>(
              value: '-',
              title: Text(
                'بالنقصان (−)',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
        ],
      ),
    );
  }
}
