// شاشة إعداد المنشأة الجديدة (CreateWorkspaceScreen) + نافذة إدارة المنشآت والتبديل بينها.
//
// تطبّق السيناريو الثاني من معالج فحص وتوجيه الحسابات (Workspace Resolver / Auth Gate):
//   • للمستخدم الجديد تماماً الذي لا يملك أي منشأة سابقة في السحابة:
//     يُمنع فتح أو ربط أي منشأة مخزنة مسبقاً على الهاتف، ويُوجَّه مباشرة لهذه الشاشة.
//   • الحقول الإجبارية (100%):
//     1) اسم المنشأة التجاري
//     2) رقم هاتف المالك
//     3) نوع النشاط التجاري
//     4) العملة الافتراضية
//   • بعد إكمال الحقول بنسبة 100%:
//     إنشاء workspaceId فريد جديد، تسجيلها في فايربيس باسم البريد،
//     إنشاء ملف SQLite جديد ونظيف كلياً (nexora_${workspaceId}.db)،
//     وإدخاله للنظام بحالة اشتراك غير مفعل (unactivated) حتى يتم الترخيص.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounting.dart';
import '../core/cloud_config.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/sync/account_workspace.dart';
import 'home_shell.dart';
import 'lock_gate.dart';
import 'logout_flow.dart';
import 'widgets.dart';

class CreateWorkspaceScreen extends ConsumerStatefulWidget {
  final String ownerEmail;
  final String ownerUid;
  final String ownerDisplayName;
  final bool isAdditionalWorkspace;

  const CreateWorkspaceScreen({
    super.key,
    required this.ownerEmail,
    this.ownerUid = '',
    this.ownerDisplayName = '',
    this.isAdditionalWorkspace = false,
  });

  @override
  ConsumerState<CreateWorkspaceScreen> createState() =>
      _CreateWorkspaceScreenState();
}

class _CreateWorkspaceScreenState extends ConsumerState<CreateWorkspaceScreen> {
  final _formKey = GlobalKey<FormState>();
  final _storeNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _activityCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();

  String _countryDialCode = '+967';
  String _currency = 'YER';
  bool _busy = false;
  String? _errorMsg;

  static const _dialCodes = <(String, String)>[
    ('+967', 'اليمن (+967)'),
    ('+966', 'السعودية (+966)'),
    ('+971', 'الإمارات (+971)'),
    ('+968', 'عُمان (+968)'),
    ('+965', 'الكويت (+965)'),
    ('+974', 'قطر (+974)'),
    ('+973', 'البحرين (+973)'),
    ('+20', 'مصر (+20)'),
    ('+962', 'الأردن (+962)'),
    ('+964', 'العراق (+964)'),
  ];

  static const _suggestedActivities = <String>[
    'مواد غذائية وتموينات',
    'تجارة عامة وجملة',
    'إلكترونيات وهواتف',
    'ملابس وأحذية',
    'مواد بناء وكهرباء',
    'صيدلية ومستلزمات طبية',
    'مطعم وكافيه',
    'قطع غيار وزيوت',
    'خدمات ومقاولات',
  ];

  @override
  void dispose() {
    _storeNameCtrl.dispose();
    _phoneCtrl.dispose();
    _activityCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _errorMsg = null);
    if (!(_formKey.currentState?.validate() ?? false)) {
      Sfx.error();
      return;
    }

    final storeName = _storeNameCtrl.text.trim();
    final rawPhone = _phoneCtrl.text.trim().replaceAll(RegExp(r'[^\d]'), '');
    final localDigits =
        rawPhone.startsWith('0') ? rawPhone.substring(1) : rawPhone;
    final fullPhone = '$_countryDialCode$localDigits';
    final activity = _activityCtrl.text.trim();
    final address = _addressCtrl.text.trim();

    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);

      await AccountWorkspace.createAndRegisterNewWorkspace(
        repo,
        backendUrl: url,
        storeName: storeName,
        phone: fullPhone,
        businessActivity: activity,
        defaultCurrency: _currency,
        address: address,
        emailOverride: widget.ownerEmail,
        uidOverride: widget.ownerUid,
        displayNameOverride: widget.ownerDisplayName,
      );

      // إعادة تشغيل محرك المزامنة وتحديث كافة الـ Providers للمنشأة الجديدة المعزولة
      try {
        final engine = ref.read(syncEngineProvider);
        engine.stop();
        await engine.start();
      } catch (_) {}

      ref.invalidate(googleLinkedProvider);
      ref.invalidate(currentUserProvider);
      ref.invalidate(deviceRoleProvider);
      ref.invalidate(effectivePermissionsProvider);
      ref.invalidate(canManageGroupProvider);
      ref.invalidate(settingsProvider);
      ref.invalidate(isOwnerProvider);
      ref.invalidate(workspaceModeProvider);
      ref.invalidate(subscriptionProvider);
      bump(ref);

      Sfx.tap();
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LockGate(child: HomeShell())),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMsg = 'تعذّر إنشاء المنشأة: $e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppColors.primaryOf(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isAdditionalWorkspace
              ? 'إنشاء منشأة جديدة مستقلة'
              : 'إعداد بيانات المنشأة الجديدة',
        ),
        actions: [
          if (!widget.isAdditionalWorkspace)
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      final repo = ref.read(repoProvider);
                      await performCompleteSessionPurge(ref, repo);
                    },
              icon: const Icon(Icons.logout_rounded, size: 18, color: Colors.redAccent),
              label: const Text(
                'تسجيل الخروج',
                style: TextStyle(color: Colors.redAccent, fontSize: 12.5),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: primary.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.domain_add_rounded,
                                  color: primary, size: 28),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  widget.isAdditionalWorkspace
                                      ? 'تأسيس منشأة إضافية بقاعدة بيانات معزولة'
                                      : 'مرحباً بك! يرجى إكمال بيانات منشأتك للبدء',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'الحساب المرتبط: ${widget.ownerEmail}\n'
                            'سيتم إنشاء معرف منشأة فريد وقاعدة بيانات SQLite مستقلة ونظيفة كلياً، '
                            'وتسجيلها سحابياً باسم بريدك الإلكتروني بحالة اشتراك غير مفعل حتى يتم الترخيص.',
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.55,
                              color: AppColors.text2Of(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (_errorMsg != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.redAccent),
                        ),
                        child: Text(
                          _errorMsg!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // 1) اسم المنشأة التجاري (إجباري)
                    TextFormField(
                      controller: _storeNameCtrl,
                      enabled: !_busy,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'اسم المنشأة التجاري *',
                        hintText: 'مثال: مؤسسة النور للتجارة والتوكيلات',
                        prefixIcon: Icon(Icons.storefront_rounded),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) {
                        final s = (v ?? '').trim();
                        if (s.length < 2) {
                          return 'يرجى إدخال اسم المنشأة التجاري (إجباري)';
                        }
                        if (s == 'متجري' || s == 'منشأتي') {
                          return 'يرجى كتابة الاسم التجاري الحقيقي للمنشأة';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // 2) رقم هاتف المالك مع مفتاح الدولة (إجباري)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 155,
                          child: DropdownButtonFormField<String>(
                            value: _countryDialCode,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'مفتاح الدولة *',
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 14),
                            ),
                            items: [
                              for (final c in _dialCodes)
                                DropdownMenuItem(
                                  value: c.$1,
                                  child: Text(
                                    c.$2,
                                    style: const TextStyle(fontSize: 12.5),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: _busy
                                ? null
                                : (v) {
                                    if (v != null) {
                                      setState(() => _countryDialCode = v);
                                    }
                                  },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextFormField(
                            controller: _phoneCtrl,
                            enabled: !_busy,
                            keyboardType: TextInputType.phone,
                            textDirection: TextDirection.ltr,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'رقم هاتف المالك *',
                              hintText: '77xxxxxxx',
                              prefixIcon: Icon(Icons.phone_iphone_rounded),
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) {
                              final digits = (v ?? '')
                                  .trim()
                                  .replaceAll(RegExp(r'[^\d]'), '');
                              if (digits.length < 7) {
                                return 'يرجى إدخال رقم هاتف صحيح للمالك (إجباري)';
                              }
                              return null;
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // 3) نوع النشاط التجاري (إجباري)
                    TextFormField(
                      controller: _activityCtrl,
                      enabled: !_busy,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'نوع النشاط التجاري *',
                        hintText: 'مثال: مواد غذائية، إلكترونيات، تجارة عامة...',
                        prefixIcon: Icon(Icons.category_rounded),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) {
                        if ((v ?? '').trim().length < 2) {
                          return 'يرجى تحديد نوع النشاط التجاري (إجباري)';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final act in _suggestedActivities)
                          ActionChip(
                            label: Text(act, style: const TextStyle(fontSize: 11.5)),
                            onPressed: _busy
                                ? null
                                : () {
                                    setState(() => _activityCtrl.text = act);
                                  },
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // 4) العملة الافتراضية (إجباري)
                    DropdownButtonFormField<String>(
                      value: _currency,
                      decoration: const InputDecoration(
                        labelText: 'العملة الافتراضية للمنشأة *',
                        prefixIcon: Icon(Icons.currency_exchange_rounded),
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final c in kDefaultCurrencies)
                          DropdownMenuItem(
                            value: c.code,
                            child: Text('${c.name} (${c.code})'),
                          ),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) {
                              if (v != null) setState(() => _currency = v);
                            },
                    ),
                    const SizedBox(height: 16),

                    // العنوان (اختياري)
                    TextFormField(
                      controller: _addressCtrl,
                      enabled: !_busy,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(
                        labelText: 'عنوان المنشأة (اختياري)',
                        hintText: 'المدينة - الشارع',
                        prefixIcon: Icon(Icons.location_on_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 26),

                    SizedBox(
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _submit,
                        icon: _busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.rocket_launch_rounded),
                        label: Text(
                          _busy
                              ? 'جاري إنشاء قاعدة البيانات وتسجيل المنشأة...'
                              : 'إنشاء المنشأة والدخول للنظام',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// نافذة «إدارة المنشآت / إنشاء منشأة أخرى» لمن يرغب بإدارة أكثر من نشاط بنفس الحساب
/// دون أن تتداخل حسابات المنشأتين مع بعضهما (قاعدة بيانات SQLite مستقلة لكل منشأة).
Future<void> showWorkspaceManagerDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => const _WorkspaceManagerDialog(),
  );
}

class _WorkspaceManagerDialog extends ConsumerStatefulWidget {
  const _WorkspaceManagerDialog();

  @override
  ConsumerState<_WorkspaceManagerDialog> createState() =>
      _WorkspaceManagerDialogState();
}

class _WorkspaceManagerDialogState
    extends ConsumerState<_WorkspaceManagerDialog> {
  List<WorkspaceInfo> _workspaces = const [];
  bool _loading = true;
  bool _switching = false;
  String _ownerEmail = '';
  String _ownerUid = '';
  String _ownerName = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      _ownerEmail = (st['account.email'] ?? st['email'] ?? '').trim();
      _ownerUid = (st['account.uid'] ?? '').trim();
      _ownerName =
          (st['account.name'] ?? st['sync.deviceName'] ?? '').trim();
      final list = await AccountWorkspace.listUserWorkspaces(
        repo,
        backendUrl: url,
      );
      if (!mounted) return;
      setState(() {
        _workspaces = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _switchTo(WorkspaceInfo ws) async {
    if (_switching || ws.isCurrent) return;
    final ok = await confirmDialog(
      context,
      title: 'التبديل إلى «${ws.storeName}»',
      message:
          'سيتم إغلاق قاعدة بيانات المنشأة الحالية بأمان وفتح قاعدة البيانات المعزولة الخاصة بمنشأة «${ws.storeName}» (${ws.workspaceId}) دون أي تداخل في الحسابات أو العمليات.\n\nهل تريد المتابعة؟',
      confirmText: 'تبديل المنشأة',
    );
    if (ok != true || !mounted) return;

    setState(() => _switching = true);
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);

      try {
        ref.read(syncEngineProvider).stop();
      } catch (_) {}

      final switched = await AccountWorkspace.switchToExistingWorkspace(
        repo,
        backendUrl: url,
        targetWorkspaceId: ws.workspaceId,
      );

      if (switched) {
        try {
          final engine = ref.read(syncEngineProvider);
          await engine.start();
          unawaited(engine.forceSyncNow());
        } catch (_) {}

        ref.invalidate(googleLinkedProvider);
        ref.invalidate(currentUserProvider);
        ref.invalidate(deviceRoleProvider);
        ref.invalidate(effectivePermissionsProvider);
        ref.invalidate(canManageGroupProvider);
        ref.invalidate(settingsProvider);
        ref.invalidate(isOwnerProvider);
        ref.invalidate(workspaceModeProvider);
        ref.invalidate(subscriptionProvider);
        bump(ref);

        if (!mounted) return;
        Navigator.of(context).pop();
        showSnack(context, 'تم التبديل إلى منشأة «${ws.storeName}» بنجاح ✅');
      } else {
        if (!mounted) return;
        showSnack(context, 'تعذّر التبديل إلى المنشأة المحددة', error: true);
        setState(() => _switching = false);
      }
    } catch (e) {
      if (!mounted) return;
      showSnack(context, 'خطأ أثناء تبديل المنشأة: $e', error: true);
      setState(() => _switching = false);
    }
  }

  Future<void> _deleteWorkspace(WorkspaceInfo ws) async {
    if (_switching || ws.isCurrent) return;
    final ok = await confirmDialog(
      context,
      title: 'حذف المنشأة «${ws.storeName}»',
      message:
          'هل أنت متأكد من حذف منشأة «${ws.storeName}» (${ws.workspaceId}) من حسابك وقاعدتك نهائياً؟\n\nتنبيه: لا يمكن التراجع عن هذا الإجراء.',
      confirmText: 'حذف نهائياً',
      danger: true,
    );
    if (ok != true || !mounted) return;

    setState(() => _switching = true);
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      await AccountWorkspace.deleteWorkspaceRegistration(
        repo,
        backendUrl: url,
        workspaceId: ws.workspaceId,
      );
      if (!mounted) return;
      showSnack(context, 'تم حذف المنشأة «${ws.storeName}» بنجاح');
      await _load();
    } catch (e) {
      if (!mounted) return;
      showSnack(context, 'خطأ أثناء حذف المنشأة: $e', error: true);
      setState(() => _switching = false);
    }
  }

  void _openCreateNewWorkspace() {
    Navigator.of(context).pop();
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => CreateWorkspaceScreen(
          ownerEmail: _ownerEmail,
          ownerUid: _ownerUid,
          ownerDisplayName: _ownerName,
          isAdditionalWorkspace: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppColors.primaryOf(context);
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.domain_rounded, color: primary),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'إدارة المنشآت',
              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: _loading || _switching
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 14),
                    Text(
                      _switching
                          ? 'جاري إغلاق المنشأة الحالية وفتح قاعدة بيانات المنشأة المختارة...'
                          : 'جاري تحميل قائمة منشآتك...',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'لكل منشأة معرف مستقل وملف قاعدة بيانات SQLite معزول بالكامل حتى لا تتداخل حسابات أو عمليات المنشآت مع بعضها.',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: AppColors.text2Of(context),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _workspaces.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (ctx, i) {
                        final ws = _workspaces[i];
                        return Container(
                          decoration: BoxDecoration(
                            color: ws.isCurrent
                                ? primary.withValues(alpha: 0.1)
                                : Theme.of(context).cardColor,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: ws.isCurrent
                                  ? primary
                                  : Colors.grey.withValues(alpha: 0.3),
                              width: ws.isCurrent ? 1.5 : 1,
                            ),
                          ),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: ws.isCurrent
                                  ? primary
                                  : Colors.grey.withValues(alpha: 0.2),
                              foregroundColor:
                                  ws.isCurrent ? Colors.white : primary,
                              child: Icon(
                                ws.isCurrent
                                    ? Icons.check_circle_rounded
                                    : Icons.store_rounded,
                                size: 20,
                              ),
                            ),
                            title: Text(
                              ws.storeName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13.5,
                              ),
                            ),
                            subtitle: Text(
                              'المعرف: ${ws.workspaceId}'
                              '${ws.businessActivity.isNotEmpty ? ' • ${ws.businessActivity}' : ''}'
                              ' • ${ws.defaultCurrency}',
                              style: const TextStyle(fontSize: 11.5),
                            ),
                            trailing: ws.isCurrent
                                ? Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: primary,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text(
                                      'النشطة حالياً',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  )
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline,
                                            color: Colors.redAccent, size: 20),
                                        tooltip: 'حذف المنشأة الزائدة',
                                        onPressed: () => _deleteWorkspace(ws),
                                      ),
                                      const SizedBox(width: 4),
                                      OutlinedButton(
                                        onPressed: () => _switchTo(ws),
                                        child: const Text(
                                          'تبديل',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    ],
                                  ),
                            onTap: ws.isCurrent ? null : () => _switchTo(ws),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_workspaces.isNotEmpty) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border:
                            Border.all(color: primary.withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline, color: primary, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'لكل حساب بريد إلكتروني منشأة واحدة فقط. للتنقل بين المنشآت أو إدارة نشاط آخر، يجب تسجيل الخروج والتسجيل ببريد إلكتروني آخر.',
                              style: TextStyle(
                                fontSize: 11.5,
                                height: 1.4,
                                color: AppColors.text2Of(context),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        showSecuredLogout(ref);
                      },
                      icon: const Icon(Icons.logout_rounded, size: 18),
                      label: const Text('تسجيل الخروج للتبديل لحساب آخر'),
                    ),
                  ] else ...[
                    FilledButton.icon(
                      onPressed: _openCreateNewWorkspace,
                      icon: const Icon(Icons.add_business_rounded),
                      label: const Text('إنشاء منشأة جديدة'),
                    ),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _switching ? null : () => Navigator.of(context).pop(),
          child: const Text('إغلاق'),
        ),
      ],
    );
  }
}
