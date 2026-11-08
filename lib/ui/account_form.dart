import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_contacts/flutter_contacts.dart' hide Account;

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/keep_alive_service.dart';
import '../core/theme.dart';
import '../core/models.dart';
import '../core/sfx.dart';
import '../data/providers.dart';
import 'widgets.dart';
import '../core/platform_info.dart';

/// فتح نموذج إضافة/تعديل حساب كبطاقة منبثقة مدمجة تعلو الكيبورد.
Future<bool> openAccountForm(
  BuildContext context,
  WidgetRef ref, {
  Account? existing,
}) async {
  final r = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      clipBehavior: Clip.antiAlias,
      backgroundColor: AppColors.surfaceOf(ctx),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: AccountFormScreen(
          existing: existing,
          embedded: true,
        ),
      ),
    ),
  );
  return r ?? false;
}

class AccountFormScreen extends ConsumerStatefulWidget {
  final Account? existing;
  final bool embedded;

  const AccountFormScreen({super.key, this.existing, this.embedded = false});

  @override
  ConsumerState<AccountFormScreen> createState() => _State();
}

class _State extends ConsumerState<AccountFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _opening;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late final TextEditingController _notes;
  late final TextEditingController _category;
  late final TextEditingController _limit;
  late final TextEditingController _tags;

  late AccountKind _kind;
  late String _currency;
  late bool _archived;

  /// قناة إرسال إشعار السند لهذا الحساب.
  late String _notifyChannel;

  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  static const List<(String, String)> _shareOptions = <(String, String)>[
    ('none', '🚫 عدم المشاركة'),
    ('auto_whatsapp', '💬 واتساب'),
    ('auto_w4b', '💼 واتساب أعمال'),
    ('auto_sms', '✉️ رسائل SMS'),
    ('auto_system', '📤 خيارات النظام'),
  ];

  @override
  void initState() {
    super.initState();
    final a = widget.existing;
    _name = TextEditingController(text: a?.name ?? '');
    _opening = TextEditingController(
      text: a == null || a.openingBalance == 0
          ? ''
          : Fmt.money(a.openingBalance, 2),
    );
    _phone = TextEditingController(
      text: a?.whatsapp.isNotEmpty == true ? a!.whatsapp : (a?.phone ?? ''),
    );
    _address = TextEditingController(text: a?.address ?? '');
    _notes = TextEditingController(text: a?.notes ?? '');
    _category = TextEditingController(text: a?.category ?? '');
    _limit = TextEditingController(
      text: a?.creditLimit == null ? '' : Fmt.money(a!.creditLimit!, 2),
    );
    _tags = TextEditingController(text: a?.tags.join('، ') ?? '');
    _kind = a?.kind ?? AccountKind.customer;
    _currency = a?.currency ?? 'YER';
    _archived = a?.archived ?? false;
    final rawNotify = (a?.notifyChannel ?? 'none').trim();
    _notifyChannel = switch (rawNotify) {
      'auto_whatsapp' || 'auto_w4b' || 'auto_sms' || 'auto_system' => rawNotify,
      'whatsapp' => 'auto_whatsapp',
      'sms' => 'auto_sms',
      _ => 'none',
    };
    _initialSnapshot = _formSnapshot();
  }

  /// بصمة قيم النموذج — لاكتشاف التغييرات غير المحفوظة عند الرجوع.
  late String _initialSnapshot;
  String _formSnapshot() => [
        _name.text,
        _opening.text,
        _phone.text,
        _address.text,
        _notes.text,
        _category.text,
        _limit.text,
        _tags.text,
        _kind.name,
        _currency,
        '$_archived',
        _notifyChannel,
      ].join('\u0001');

  bool get _dirty => _formSnapshot() != _initialSnapshot;

  /// حارس التغييرات: يسأل قبل تجاهل تعديلات لم تُحفظ.
  Future<void> _guardedPop(bool didPop) async {
    if (didPop || _saving) return;
    if (!_dirty) {
      Navigator.of(context).maybePop();
      return;
    }
    final discard = await confirmDialog(
      context,
      title: 'تغييرات غير محفوظة',
      message: 'هل تريد تجاهل التغييرات؟',
      confirmText: 'تجاهل',
      danger: true,
    );
    if (discard && mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _opening,
      _phone,
      _address,
      _notes,
      _category,
      _limit,
      _tags,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final rawOpening = _opening.text.trim();
      final parsedOpening = Fmt.parseAmount(rawOpening) ?? 0;
      final double finalOpening = parsedOpening;
      final limit = Fmt.parseAmount(_limit.text);
      final now = DateTime.now();

      final acc = Account(
        id: widget.existing?.id,
        name: _name.text.trim(),
        kind: _kind,
        openingBalance: finalOpening,
        currency: _currency,
        phone: Fmt.phoneDigits(_phone.text),
        whatsapp: Fmt.phoneDigits(_phone.text),
        address: _address.text.trim(),
        notes: _notes.text.trim(),
        category: widget.existing?.category ?? '',
        creditLimit: limit,
        tags: _tags.text
            .split(RegExp('[,،]'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        archived: _archived,
        notifyChannel: _notifyChannel,
        createdAt: widget.existing?.createdAt ?? now,
        updatedAt: now,
      );

      await ref.read(repoProvider).saveAccount(acc);
      if (!mounted) return;
      bump(ref);
      Navigator.pop(context, true);
      showSnack(context, _isEdit ? 'تم تحديث الحساب' : 'تمت إضافة الحساب');
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر الحفظ: $e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// جلب اسم ورقم العميل من تطبيق جهات الاتصال الرسمي في الهاتف،
  /// مع طلب إذن النظام مباشرة دون أي نافذة خاصة للتطبيق.
  Future<void> _pickContact() async {
    if (!PlatformInfo.isMobile) {
      showSnack(context, 'اختيار جهة الاتصال متاح على الهاتف فقط', error: true);
      return;
    }
    try {
      if (!await NexKeepAlive.hasPermission(NexKeepAlive.permReadContacts)) {
        await NexKeepAlive.requestPermission(NexKeepAlive.permReadContacts);
      }
      if (!mounted) return;

      final picked = await NexKeepAlive.pickContact();
      String name = (picked?['name'] ?? '').trim();
      String phone = Fmt.phoneDigits(picked?['phone'] ?? '');

      if (name.isEmpty && phone.isEmpty) {
        final contact = await FlutterContacts.openExternalPick();
        if (contact == null) return;
        name = contact.displayName.trim();
        phone = contact.phones.isNotEmpty
            ? Fmt.phoneDigits(contact.phones.first.number)
            : '';
      }

      if (name.isEmpty && phone.isEmpty) return;

      setState(() {
        if (name.isNotEmpty && (_name.text.trim().isEmpty || !_isEdit)) {
          _name.text = name;
        }
        if (phone.isNotEmpty) _phone.text = phone;
      });
      Sfx.success();
      if (mounted) showSnack(context, 'تم جلب بيانات العميل من جهات الاتصال');
    } catch (e) {
      if (mounted) {
        showSnack(context, 'تعذّر جلب جهة الاتصال: $e', error: true);
      }
    }
  }

  Widget _buildShareMenuButton(BuildContext context, {bool onHeader = false}) {
    final active = _notifyChannel != 'none';
    return PopupMenuButton<String>(
      tooltip: 'إعداد مشاركة العمليات تلقائياً',
      initialValue: _notifyChannel,
      onSelected: (v) {
        Sfx.tap();
        setState(() => _notifyChannel = v);
      },
      itemBuilder: (_) => [
        const PopupMenuItem<String>(
          enabled: false,
          height: 30,
          child: Text(
            'مشاركة العمليات تلقائياً:',
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
          ),
        ),
        for (final opt in _shareOptions)
          PopupMenuItem<String>(
            value: opt.$1,
            height: 38,
            child: Row(
              children: [
                Icon(
                  _notifyChannel == opt.$1
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 17,
                  color: _notifyChannel == opt.$1
                      ? AppColors.primaryOf(context)
                      : Colors.grey,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(opt.$2, style: const TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: onHeader
              ? Colors.white.withValues(alpha: active ? 0.24 : 0.14)
              : AppColors.primaryOf(context).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? Icons.share_rounded : Icons.share_outlined,
              size: 16,
              color: onHeader ? Colors.white : AppColors.primaryOf(context),
            ),
            if (active) ...[
              const SizedBox(width: 4),
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFF10B981),
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final curs =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;

    final formBody = Form(
      key: _formKey,
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ══ الصف 1: اسم الحساب + أيقونة جهات الاتصال + قائمة نوع الحساب (عميل ▾) ══
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 6,
                  child: TextFormField(
                    controller: _name,
                    style: const TextStyle(fontSize: 13.5),
                    decoration: const InputDecoration(
                      labelText: 'اسم الحساب *',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                    textInputAction: TextInputAction.next,
                    validator: (v) =>
                        (v ?? '').trim().isEmpty ? 'الاسم مطلوب' : null,
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filledTonal(
                  tooltip: 'جلب من جهات الاتصال',
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.blue.withValues(alpha: 0.12),
                    foregroundColor: Colors.blue.shade700,
                    minimumSize: const Size(38, 40),
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.contacts_rounded, size: 19),
                  onPressed: _pickContact,
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 4,
                  child: DropdownButtonFormField<AccountKind>(
                    initialValue: _kind,
                    isExpanded: true,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textOf(context),
                    ),
                    decoration: const InputDecoration(
                      labelText: 'النوع',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 9,
                      ),
                    ),
                    items: AccountKind.values
                        .map(
                          (k) => DropdownMenuItem<AccountKind>(
                            value: k,
                            child: Text(
                              k.label,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _kind = v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // ══ الصف 2: الرصيد الافتتاحي (يمين) + العملة (يسار) ══
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _opening,
                    style: const TextStyle(fontSize: 13.5),
                    decoration: const InputDecoration(
                      labelText: 'الرصيد الافتتاحي',
                      hintText: '0.00',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    validator: (v) {
                      if ((v ?? '').trim().isEmpty) return null;
                      return Fmt.parseAmount(v!) == null
                          ? 'مبلغ غير صالح'
                          : null;
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue:
                        curs.any((c) => c.code == _currency) ? _currency : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'العملة',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 9,
                      ),
                    ),
                    items: curs
                        .map(
                          (c) => DropdownMenuItem(
                            value: c.code,
                            child: Text(
                              '${c.name} (${c.symbol})',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _currency = v ?? 'YER'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // ══ الصف 3: رقم الجوال (يمين) + الحد الائتماني (يسار) ══
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(fontSize: 13.5),
                    decoration: const InputDecoration(
                      labelText: 'رقم الجوال',
                      hintText: '7xxxxxxxx',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    controller: _limit,
                    style: const TextStyle(fontSize: 13.5),
                    decoration: const InputDecoration(
                      labelText: 'حد ائتماني',
                      hintText: '0.00',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              height: 42,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check, size: 18),
                label: Text(_isEdit ? 'حفظ التعديلات' : 'إضافة الحساب'),
              ),
            ),
          ],
        ),
      ),
    );

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) => _guardedPop(didPop),
      child: widget.embedded
          ? Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primaryOf(context),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.person_add_alt_1_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _isEdit ? 'تعديل حساب' : 'حساب جديد',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        _buildShareMenuButton(context, onHeader: true),
                        const SizedBox(width: 4),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          padding: EdgeInsets.zero,
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                      ],
                    ),
                  ),
                  Flexible(child: formBody),
                ],
              ),
            )
          : Scaffold(
              resizeToAvoidBottomInset: false,
              appBar: AppBar(
                title: Text(_isEdit ? 'تعديل حساب' : 'حساب جديد'),
                actions: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: _buildShareMenuButton(context, onHeader: true),
                  ),
                ],
              ),
              body: SafeArea(
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: formBody,
                ),
              ),
            ),
    );
  }
}
