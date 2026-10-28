import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../core/accounting.dart';
import '../core/desktop.dart';
import '../core/format.dart';
import '../core/icon_catalog.dart';
import '../core/models.dart';
import '../core/thermal_invoice_doc.dart';
import '../core/shell_nav.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/pos_cart.dart';
import '../data/providers.dart';
import '../data/sync/subscription_guard.dart' show Feature;
import 'barcode_scanner.dart';
import 'pos_gate.dart';
import 'pos_items_grid.dart';
import 'inventory_screen.dart'
    show inventoryShortagesModeProvider, openShortagesListSheet;
import 'transactions_screen.dart' show showTxDetails;
import 'trial_ui.dart' show featureNeedsStamp;
import 'tx_share.dart';
import 'widgets.dart';
import '../core/data_change.dart';

enum _PosPayment {
  cash('نقداً 💵', 'cash'),
  credit('آجل 📑', 'credit'),
  partial('جزئي ⚖️', 'partial');

  final String label;
  final String code;
  const _PosPayment(this.label, this.code);

  static _PosPayment fromCode(String c) => _PosPayment.values
      .firstWhere((p) => p.code == c, orElse: () => _PosPayment.cash);
}

/// شاشة نقطة البيع ونظام المبيعات المتكامل
class PosScreen extends ConsumerStatefulWidget {
  const PosScreen({super.key});

  /// جسر الزر المركزي (Omni): عندما تكون شاشة POS ظاهرة يفتح زر
  /// الإجراء الموحد درج الدفع مباشرة عبر هذا المرجع.
  static void Function()? openCheckoutBridge;

  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends ConsumerState<PosScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  int? _selectedCategoryId;
  // (2026-09-22) القسم المختار في الشريط اللمسي (null = الكل، -1 = عام).
  int? _selectedSectionId;

  /// هل لوحة الأقسام المنسدلة مفتوحة؟ (مطوية افتراضياً لتوفير مساحة لشبكة الأصناف).
  bool _atSectionsGate = false;

  /// الوضع المدمج التدريجي للترويسة العلوية عند تمرير شبكة الأصناف لأسفل.
  bool _isScrolledCompact = false;

  String _searchQuery = '';

  /// (2026-09-24) ترتيب شبكة الأصناف: 0 الاسم · 1 السعر · 2 الكمية.
  int _posSort = 0;
  final TextEditingController _searchCtrl = TextEditingController();
  bool _saving = false;

  /// «السماح بالبيع عند نفاد الرصيد الدفتري» — إعداد المخزون.
  bool get _allowNegative =>
      (ref.read(settingsProvider).valueOrNull ?? const {})['allowNegativeStock'] ==
      '1';

  // السلة الحية تعيش في Riverpod (pos_cart.dart) — التنقل لا يفقدها.
  PosDraft get _draft => ref.read(posDraftProvider);
  PosDraftNotifier get _cartCtl => ref.read(posDraftProvider.notifier);

  // جسور قراءة من المسودة — تبقي بقية الشيفرة كما هي.
  Map<int, CartEntry> get _cart => _draft.cart;
  int? get _selectedCustomerId => _draft.customerId;
  _PosPayment get _payment => _PosPayment.fromCode(_draft.payment);
  double get _subtotal => _draft.subtotal;
  double get _discount => _draft.discountValue;
  double get _netTotal => _draft.netTotal;
  int get _itemCount => _draft.itemCount;
  // حقول نصية تُستعاد من المسودة عند إعادة بناء الشاشة (تُهيأ في
  // initState — التهيئة الكسولة تنفجر لو أول وصول كان في dispose).
  late final TextEditingController _paidCtrl;
  late final TextEditingController _discountCtrl;
  late final TextEditingController _notesCtrl;

  /// (3.70) صلاحية الخصم المحلية — تُحجب عن الكاشير فوراً (بلا شبكة).
  bool _canDiscount = true;
  /// اعتماد المشرف لتخطي حجب الخصم في الفاتورة الحالية فقط (Supervisor Override)
  bool _supervisorOverride = false;

  bool get _hasDiscountPermission {
    if (_supervisorOverride) return true;
    final user = ref.read(currentUserProvider).valueOrNull;
    if (user != null) {
      return user.role == UserRole.admin ||
          user.role == UserRole.agent ||
          user.can('can_discount');
    }
    return _canDiscount;
  }

  Future<void> _promptSupervisorOverride(StateSetter setSheetState) async {
    final pinCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('الموافقة على الخصم (مشرف/مدير)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('أدخل رمز PIN للمشرف أو المدير لتخطي حجب الخصم لهذه الفاتورة:'),
            const SizedBox(height: 12),
            TextField(
              controller: pinCtrl,
              obscureText: true,
              keyboardType: TextInputType.number,
              autofocus: true,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'رمز PIN',
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () async {
              final repo = ref.read(repoProvider);
              final okPin = await repo.verifyPosMasterPin(pinCtrl.text);
              if (okPin) {
                if (ctx.mounted) Navigator.pop(ctx, true);
              } else {
                final st = await repo.settings();
                final configured = (st['pos.master_pin'] ?? '').trim().isNotEmpty;
                if (ctx.mounted) {
                  showSnack(
                    ctx,
                    configured
                        ? 'رمز PIN غير صحيح'
                        : 'لم يتم تعيين رمز PIN للمشرف في الإعدادات بعد',
                    error: true,
                  );
                }
              }
            },
            child: const Text('تأكيد'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() {
        _supervisorOverride = true;
      });
      setSheetState(() {});
      showSnack(context, 'تمت الموافقة على الخصم بواسطة المشرف ✅');
    }
  }

  @override
  void initState() {
    super.initState();
    final d = ref.read(posDraftProvider);
    _paidCtrl = TextEditingController(text: d.paidText);
    _discountCtrl = TextEditingController(text: d.discountText);
    _notesCtrl = TextEditingController(text: d.notesText);
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    // (2026-09-24) بيع من الزر العائم ⇒ حدّث الأرصدة والمسودة فوراً.
    dataChangeTick.addListener(_onExternalDataChange);
    // (3.70 — المرحلة 4) RBAC محلي Offline-Ready: حقل الخصم يظهر فقط
    // لصاحب صلاحية can_discount.
    ref.read(repoProvider).effectivePermissions().then((p) {
      if (mounted && p.canDiscount != _canDiscount) {
        setState(() => _canDiscount = p.canDiscount);
      }
    });
    // ربط الزر المركزي الموحد: على شاشة POS يفتح درج الدفع مباشرة.
    PosScreen.openCheckoutBridge = () {
      if (!mounted) return;
      if (_draft.cart.isEmpty) {
        Sfx.reject();
        showSnack(context, 'السلة فارغة — أضف أصنافاً أولاً', error: true);
        return;
      }
      _openCheckoutSheet();
    };
    // مستمع عالمي لأحداث لوحة المفاتيح (سطح المكتب وقارئات الباركود):
    HardwareKeyboard.instance.addHandler(_onGlobalKeyEvent);
  }

  /// (2026-09-24) كتابة خارجية (الزر العائم): أعد قراءة الأصناف فتظهر
  /// الأرصدة الحديثة، وحدّث المسودة المعروضة.
  void _onExternalDataChange() {
    if (!mounted) return;
    bump(ref);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKeyEvent);
    dataChangeTick.removeListener(_onExternalDataChange);
    if (PosScreen.openCheckoutBridge != null) {
      PosScreen.openCheckoutBridge = null;
    }
    _tabController.dispose();
    _searchCtrl.dispose();
    _paidCtrl.dispose();
    _discountCtrl.dispose();
    _notesCtrl.dispose();
    _shortcutFocus.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// يضيف الصنف إلى السلة بكمية (الافتراضي 1).
  void _addItem(Item item, {double quantity = 1}) {
    final allowNeg = _allowNegative;
    if (!allowNeg && item.quantity <= 0) {
      Sfx.reject();
      showSnack(context, 'الصنف «${item.name}» نفد من المخزون', error: true);
      return;
    }
    final ok = _cartCtl.addItem(item, allowNegative: allowNeg, quantity: quantity);
    if (!ok) {
      Sfx.reject();
      showSnack(
        context,
        'الكمية المتاحة من «${item.name}»: ${item.quantity.toStringAsFixed(0)} ${item.unit} فقط',
        error: true,
      );
      return;
    }
    if (allowNeg && item.quantity - (_draft.cart[item.id]?.quantity ?? 0) < 0) {
      showSnack(context,
          '⚠️ «${item.name}»: البيع تجاوز الرصيد الدفتري (رصيد سالب)',
          error: true, silent: true);
    }
    Sfx.click();
  }

  /// إدخال كمية مباشر: نقرة على رقم الكمية تفتح لوحة إدخال سريعة بدل
  /// تكرار «+» للأعداد الكبيرة.
  Future<void> _editQuantity(CartEntry entry) async {
    final qty = await showQuickAmountPad(
      context,
      title: 'كمية «${entry.item.name}»',
      initial: entry.quantity,
      hint: 'المتاح: ${Fmt.money(entry.item.quantity)} ${entry.item.unit}',
    );
    if (qty == null) return;
    final ok = _cartCtl.setQuantity(entry.item.id!, qty,
        allowNegative: _allowNegative);
    if (!ok) {
      Sfx.reject();
      if (mounted) {
        showSnack(
          context,
          'الكمية المتاحة: ${entry.item.quantity.toStringAsFixed(0)} ${entry.item.unit} فقط',
          error: true,
        );
      }
    }
  }

  /// تعديل سعر بيع الوحدة لصنف داخل الفاتورة الحالية (محمي بصلاحية override_pos_price أو can_discount/مدير).
  Future<void> _editUnitPrice(CartEntry entry) async {
    final repo = ref.read(repoProvider);
    final allowed = await repo.can('override_pos_price') ||
        await repo.can('can_discount') ||
        await repo.isWorkspaceOwner();
    if (!allowed) {
      Sfx.reject();
      if (mounted) {
        showSnack(
          context,
          'ليس لديك صلاحية تعديل سعر بيع الوحدة في الفاتورة',
          error: true,
        );
      }
      return;
    }
    if (!mounted) return;
    final price = await showQuickAmountPad(
      context,
      title: 'سعر بيع «${entry.item.name}»',
      initial: entry.unitPrice,
      hint: 'السعر الأصلي: ${Fmt.money(entry.item.sellPrice)}',
    );
    if (price == null || price <= 0) return;
    _cartCtl.setUnitPrice(entry.item.id!, price);
    if (mounted) setState(() {});
  }

  void _clearCart() {
    _cartCtl.clear();
    _paidCtrl.clear();
    _discountCtrl.clear();
    _notesCtrl.clear();
    _supervisorOverride = false;
    setState(() {});
  }

  // ---------------- اختصارات لوحة مفاتيح سطح المكتب العالمية ----------------
  // F1 دفع نقدي فوري • F2 آجل • F3 تركيز بحث العميل/الأصناف •
  // F9 تعليق وفاتورة جديدة • F12 تعليق الفاتورة • Esc مسح البحث / إفراغ السلة
  // • الكتابة المباشرة توجّه تلقائياً لحقل البحث والباركود/PLU دون نقر الفأرة
  // • Enter يضيف أول صنف مطابق أو يفتح إتمام البيع السريع.
  final FocusNode _shortcutFocus = FocusNode();
  final FocusNode _searchFocus = FocusNode();

  bool _onGlobalKeyEvent(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    // لا نتدخل إذا كانت هناك نافذة حوارية أو شريحة منبثقة مفتوحة فوق شاشة المبيعات.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;

    // لا نتدخل إذا كان المستخدم في تبويب سجل المبيعات على الجوال/التابلت.
    if (!isDesktopLayout(context) && _tabController.index != 0) return false;

    // إذا كان التركيز داخل حقل نصي آخر غير حقل البحث (مثل ملاحظات أو خصم)، نتركه يعمل طبيعياً.
    final primaryFocus = FocusManager.instance.primaryFocus;
    final isOtherEditableFocused = primaryFocus != null &&
        primaryFocus != _searchFocus &&
        primaryFocus.context != null &&
        primaryFocus.context!.findAncestorWidgetOfExactType<EditableText>() !=
            null;
    if (isOtherEditableFocused) return false;

    final key = event.logicalKey;

    if (event is KeyDownEvent) {
      if (key == LogicalKeyboardKey.f1) {
        _quickSettle(_PosPayment.cash);
        return true;
      }
      if (key == LogicalKeyboardKey.f2) {
        _quickSettle(_PosPayment.credit);
        return true;
      }
      if (key == LogicalKeyboardKey.f3 || key == LogicalKeyboardKey.f4) {
        _searchFocus.requestFocus();
        _searchCtrl.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _searchCtrl.text.length,
        );
        return true;
      }
      if (key == LogicalKeyboardKey.f9) {
        _quickHoldAndNewBill();
        return true;
      }
      if (key == LogicalKeyboardKey.f12) {
        _holdInvoice();
        return true;
      }
      if (key == LogicalKeyboardKey.escape) {
        if (_searchCtrl.text.isNotEmpty || _searchQuery.isNotEmpty) {
          _searchCtrl.clear();
          setState(() => _searchQuery = '');
          return true;
        }
        if (_atSectionsGate ||
            _selectedCategoryId != null ||
            _selectedSectionId != null) {
          setState(() {
            _atSectionsGate = false;
            _selectedCategoryId = null;
            _selectedSectionId = null;
          });
          return true;
        }
        if (_cart.isNotEmpty) {
          _clearCart();
          return true;
        }
        return false;
      }
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        // إذا كان حقل البحث مركزاً فسيقوم onSubmitted بمعالجة الحدث، وإلا نعالج الإدخال فوراً.
        if (!_searchFocus.hasFocus) {
          _handleSearchOrQuickSubmit(_searchCtrl.text);
          return true;
        }
        return false;
      }
    }

    // إذا كان حقل البحث يمتلك التركيز حالياً، يكتب فيه فلاتر مباشرة دون تكرار.
    if (_searchFocus.hasFocus) return false;

    final hw = HardwareKeyboard.instance;
    if (hw.isControlPressed || hw.isAltPressed || hw.isMetaPressed) {
      return false;
    }

    if (key == LogicalKeyboardKey.backspace) {
      if (_searchCtrl.text.isNotEmpty) {
        final next =
            _searchCtrl.text.substring(0, _searchCtrl.text.length - 1);
        _searchCtrl.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        );
        setState(() => _searchQuery = next.trim());
        _searchFocus.requestFocus();
        return true;
      }
      return false;
    }

    // التقاط الأحرف والأرقام والرموز القابلة للطباعة وتوجيهها تلقائياً لحقل البحث.
    final ch = event.character;
    if (ch != null &&
        ch.isNotEmpty &&
        ch.runes.every((r) => r >= 0x20 && r != 0x7F)) {
      final next = '${_searchCtrl.text}$ch';
      _searchCtrl.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
      setState(() => _searchQuery = next.trim());
      _searchFocus.requestFocus();
      return true;
    }

    return false;
  }

  KeyEventResult _handleDesktopKey(FocusNode node, KeyEvent event) {
    // المعالجة تتم عبر المستمع العالمي _onGlobalKeyEvent لضمان العمل مع أو بدون تركيز مسبق.
    return KeyEventResult.ignored;
  }

  /// معالجة الضغط على Enter في البحث أو الشاشة:
  /// 1) إن وُجد نص بحث: يطابق الباركود أو PLU أولاً، وإلا يضيف أول صنف مطابق في الشبكة.
  /// 2) إن كان البحث فارغاً والسلة تحتوي أصنافاً: يفتح نافذة إتمام البيع السريع.
  void _handleSearchOrQuickSubmit(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isNotEmpty) {
      if (_handleQuickIndex(trimmed)) return;
      final allItems = ref.read(itemsProvider).valueOrNull ?? const <Item>[];
      final categories =
          ref.read(itemCategoriesProvider).valueOrNull ?? const <ItemCategory>[];
      final filtered = _computeFilteredItems(allItems, categories);
      if (filtered.isNotEmpty) {
        final first = filtered.first;
        _addItem(first);
        _searchCtrl.clear();
        setState(() => _searchQuery = '');
        _searchFocus.requestFocus();
        return;
      }
      setState(() => _searchQuery = trimmed);
      return;
    }
    if (_cart.isNotEmpty && !_saving) {
      _openCheckoutSheet();
    }
  }

  /// تسوية سريعة من الاختصار: نقدي ينفّذ فوراً؛ آجل يتطلب عميلاً —
  /// إن لم يُحدد نفتح درج الدفع على وضع الآجل ليختار.
  void _quickSettle(_PosPayment mode) {
    if (_cart.isEmpty) {
      Sfx.reject();
      showSnack(context, 'السلة فارغة — أضف أصنافاً أولاً', error: true);
      return;
    }
    _cartCtl.setPayment(mode.code);
    if (mode == _PosPayment.cash) {
      _executeSale(null);
    } else if (_selectedCustomerId != null) {
      _executeSale(null);
    } else {
      _openCheckoutSheet();
    }
  }

  /// تعليق الفاتورة الحالية (F12) — تُحفظ في قائمة المعلّقات وتُفرغ السلة.
  /// تعليق الفاتورة الحالية برمجياً (أو عبر F12).
  void _holdInvoice() {
    _promptHoldInvoice();
  }

  /// زر «تعليق / فاتورة جديدة» بضغطة واحدة بجانب زر الفواتير المعلقة.
  void _quickHoldAndNewBill() {
    if (_cart.isEmpty) {
      if (_selectedCustomerId != null ||
          _discountCtrl.text.isNotEmpty ||
          _notesCtrl.text.isNotEmpty ||
          _paidCtrl.text.isNotEmpty) {
        _clearCart();
        Sfx.pop();
        showSnack(context, 'فاتورة جديدة جاهزة ✨');
      } else {
        Sfx.tap();
        showSnack(context, 'الفاتورة جاهزة ✨');
      }
      return;
    }
    final heldList = ref.read(heldInvoicesProvider);
    final customers =
        ref.read(allAccountsProvider).valueOrNull ?? const <Account>[];
    String? custName;
    if (_selectedCustomerId != null) {
      for (final c in customers) {
        if (c.id == _selectedCustomerId) {
          custName = c.name;
          break;
        }
      }
    }
    final autoLabel = (custName != null && custName.trim().isNotEmpty)
        ? '$custName (#${heldList.length + 1})'
        : 'فاتورة #${heldList.length + 1}';
    _cartCtl.holdCurrentDraft(label: autoLabel);
    _paidCtrl.clear();
    _discountCtrl.clear();
    _notesCtrl.clear();
    _supervisorOverride = false;
    setState(() {});
    Sfx.pop();
    showSnack(context, 'عُلّقت «$autoLabel» ⏸️');
  }

  /// تعليق الفاتورة مع طلب تسمية اختيارية (مثل: زبون رقم 1 أو طاولة 4).
  Future<void> _promptHoldInvoice() async {
    if (_cart.isEmpty) {
      Sfx.reject();
      showSnack(context, 'لا توجد فاتورة لتعليقها', error: true);
      return;
    }
    final heldList = ref.read(heldInvoicesProvider);
    final defaultLabel = 'فاتورة #${heldList.length + 1}';
    final ctrl = TextEditingController(text: defaultLabel);

    final ok = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.pause_circle_outline_rounded, color: AppColors.primary),
            SizedBox(width: 8),
            Text('تعليق الفاتورة الحالية'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'أدخل اسماً أو وصفاً اختيارياً للفاتورة المعلقة (مثل: اسم الزبون أو رقم الطلب):',
              style: TextStyle(fontSize: 13.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'تسمية الفاتورة المعلقة',
                prefixIcon: Icon(Icons.label_outline_rounded),
              ),
              onSubmitted: (_) => Navigator.of(dlgCtx).pop(true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dlgCtx).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dlgCtx).pop(true),
            icon: const Icon(Icons.pause_rounded),
            label: const Text('تعليق الفاتورة'),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;
    final label = ctrl.text.trim();
    _cartCtl.holdCurrentDraft(label: label.isEmpty ? defaultLabel : label);
    _paidCtrl.clear();
    _discountCtrl.clear();
    _notesCtrl.clear();
    setState(() {});
    Sfx.pop();
    showSnack(context, 'تم تعليق الفاتورة ⏸️');
  }

  /// استئناف فاتورة معلّقة (تحل محل السلة الحالية إن كانت فارغة).
  void _resumeHeld(int index) {
    final held = ref.read(heldInvoicesProvider);
    if (index < 0 || index >= held.length) return;
    if (_cart.isNotEmpty) {
      Sfx.reject();
      showSnack(context, 'أفرغ السلة الحالية أو علّقها أولاً لاستئناف هذه الفاتورة', error: true);
      return;
    }
    final d = _cartCtl.resumeDraft(index);
    if (d != null) {
      _paidCtrl.text = d.paidText;
      _discountCtrl.text = d.discountText;
      _notesCtrl.text = d.notesText;
      setState(() {});
      Sfx.pop();
      showSnack(context, 'تم استئناف الفاتورة ▶️');
    }
  }

  /// حذف فاتورة معلّقة نهائياً من القائمة والتخزين.
  void _discardHeld(int index) {
    final held = ref.read(heldInvoicesProvider);
    if (index < 0 || index >= held.length) return;
    final d = _cartCtl.discardDraft(index);
    if (d != null) {
      setState(() {});
      Sfx.pop();
      showSnack(context, 'تم حذف المعلّقة 🗑️');
    }
  }

  @override
  Widget build(BuildContext context) {
    // مراقبة المسودة: أي تغيير في السلة (حتى من جلسة سابقة قبل تنقل
    // عرضي بين التبويبات) يعيد بناء الشريط السفلي فوراً.
    ref.watch(posDraftProvider);
    // سطح المكتب (>900dp): مركز قيادة ثنائي اللوحين مع اختصارات لوحة
    // المفاتيح؛ الهاتف يعرض واجهة المبيعات المرجعية مباشرة.
    if (isDesktopLayout(context)) {
      return Focus(
        focusNode: _shortcutFocus,
        onKeyEvent: _handleDesktopKey,
        autofocus: true,
        child: _buildDesktopPos(),
      );
    }
    if (_tabController.index == 1) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFF0F3E78),
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            onPressed: () => setState(() => _tabController.animateTo(0)),
          ),
          title: const Text(
            'المرتجعات وسجل فواتير المبيعات',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        body: const _PosHistoryTab(),
      );
    }
    return Scaffold(
      body: _buildPosSaleTab(),
      bottomNavigationBar: _buildCartBottomBar(),
    );
  }

  /// تخطيط سطح المكتب: يمين (60%) كتالوج الأصناف والبحث؛ يسار (40%)
  /// لوح الفاتورة الحية بإطار بارز مع الملخص المالي وأزرار التسوية.
  Widget _buildDesktopPos() {
    final currencies =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;
    final cur = currencies.first;
    final held = ref.watch(heldInvoicesProvider);
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---- اللوح الأيمن في RTL (الأول): الكتالوج 60% ----
            Expanded(
              flex: 6,
              child: DesktopPanel(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                      child: Row(
                        children: [
                          const Icon(Icons.point_of_sale_outlined, size: 20),
                          const SizedBox(width: 8),
                          Text('نقطة البيع',
                              style:
                                  Theme.of(context).textTheme.titleMedium),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _quickHoldAndNewBill,
                            onLongPress: _promptHoldInvoice,
                            icon: const Icon(Icons.post_add_rounded, size: 18),
                            label: Text(_cart.isNotEmpty
                                ? 'تعليق / جديد'
                                : 'فاتورة جديدة'),
                          ),
                          if (held.isNotEmpty)
                            TextButton.icon(
                              onPressed: () => _showHeldSheet(),
                              icon: const Icon(Icons.pause_circle_outline,
                                  size: 18),
                              label: Text('معلّقة (${held.length})'),
                            ),
                          TextButton.icon(
                            onPressed: () => showModalBottomSheet(
                              context: context,
                              isScrollControlled: true,
                              useSafeArea: true,
                              builder: (_) => const FractionallySizedBox(
                                heightFactor: 0.85,
                                child: _PosHistoryTab(),
                              ),
                            ),
                            icon: const Icon(Icons.history_edu_outlined,
                                size: 18),
                            label: const Text('سجل المبيعات'),
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: _buildPosSaleTab()),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            // ---- اللوح الأيسر: الفاتورة الحية 40% ----
            Expanded(
              flex: 4,
              child: DesktopPanel(
                padding: EdgeInsets.zero,
                child: _buildDesktopInvoicePane(cur),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// قائمة الفواتير المعلّقة مع الإجماليات والتوقيت وخياري [استئناف] و [حذف].
  void _showHeldSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return Consumer(
          builder: (context, ref, _) {
            final held = ref.watch(heldInvoicesProvider);
            final currencies =
                ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;
            final cur = currencies.first;

            final allAccounts =
                ref.watch(allAccountsProvider).valueOrNull ?? const <Account>[];

            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.78,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.pause_circle_filled_rounded,
                              color: AppColors.primary, size: 24),
                          const SizedBox(width: 8),
                          Text(
                            'الفواتير المعلقة (${held.length})',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (held.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 36),
                          child: EmptyState(
                            icon: Icons.pause_circle_outline_rounded,
                            title: 'لا توجد فواتير معلقة',
                            message:
                                'يمكنك تعليق أي فاتورة مفتوحة للعودة إليها واستئنافها لاحقاً.',
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: held.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (c, i) {
                              final d = held[i];
                              final custName = d.customerId == null
                                  ? null
                                  : allAccounts
                                      .where((a) => a.id == d.customerId)
                                      .firstOrNull
                                      ?.name;
                              final label = (d.holdLabel != null && d.holdLabel!.trim().isNotEmpty)
                                  ? d.holdLabel!
                                  : 'فاتورة معلقة #${i + 1}';
                              final timeStr = d.heldAt != null ? Fmt.dateTime(d.heldAt!) : '';

                              return InkWell(
                                borderRadius: BorderRadius.circular(AppRadius.card),
                                onTap: () async {
                                  if (_cart.isNotEmpty) {
                                    final switchOk = await showDialog<bool>(
                                      context: context,
                                      builder: (dCtx) => AlertDialog(
                                        title: const Text('السلة الحالية غير فارغة'),
                                        content: const Text(
                                            'هل تريد تعليق الفاتورة الحالية واستئناف هذه الفاتورة المعلقة؟'),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.of(dCtx).pop(false),
                                            child: const Text('إلغاء'),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.of(dCtx).pop(true),
                                            child: const Text('تعليق الحالية واستئناف'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (switchOk == true) {
                                      _cartCtl.holdCurrentDraft();
                                      if (ctx.mounted) Navigator.pop(ctx);
                                      _resumeHeld(i);
                                    }
                                  } else {
                                    Navigator.pop(ctx);
                                    _resumeHeld(i);
                                  }
                                },
                                child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceOf(context),
                                  borderRadius: BorderRadius.circular(AppRadius.card),
                                  border: Border.all(
                                    color: AppColors.borderOf(context),
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: AppTone.blue.foreground.withValues(alpha: 0.14),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: const Icon(
                                        Icons.receipt_long_rounded,
                                        color: AppColors.primary,
                                        size: 20,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            label,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 14.5,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          if (custName != null && custName.trim().isNotEmpty) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              '👤 العميل: $custName',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: AppColors.text2Of(context),
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                          const SizedBox(height: 3),
                                          Wrap(
                                            spacing: 8,
                                            crossAxisAlignment: WrapCrossAlignment.center,
                                            children: [
                                              Text(
                                                '${d.itemCount} أصناف • ${Fmt.money(d.netTotal)} ${cur.symbol}',
                                                style: TextStyle(
                                                  fontSize: 12.5,
                                                  fontWeight: FontWeight.w700,
                                                  color: AppColors.greenOf(context),
                                                ),
                                              ),
                                              if (timeStr.isNotEmpty)
                                                Text(
                                                  '• $timeStr',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: AppColors.text3Of(context),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // زر استئناف
                                    FilledButton.tonalIcon(
                                      style: FilledButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 8),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      onPressed: () async {
                                        if (_cart.isNotEmpty) {
                                          final switchOk = await showDialog<bool>(
                                            context: context,
                                            builder: (dCtx) => AlertDialog(
                                              title: const Text('السلة الحالية غير فارغة'),
                                              content: const Text(
                                                  'هل تريد تعليق الفاتورة الحالية واستئناف هذه الفاتورة المعلقة؟'),
                                              actions: [
                                                TextButton(
                                                  onPressed: () =>
                                                      Navigator.of(dCtx).pop(false),
                                                  child: const Text('إلغاء'),
                                                ),
                                                FilledButton(
                                                  onPressed: () =>
                                                      Navigator.of(dCtx).pop(true),
                                                  child: const Text('تعليق الحالية واستئناف'),
                                                ),
                                              ],
                                            ),
                                          );
                                          if (switchOk == true) {
                                            _cartCtl.holdCurrentDraft();
                                            if (ctx.mounted) Navigator.pop(ctx);
                                            _resumeHeld(i);
                                          }
                                        } else {
                                          Navigator.pop(ctx);
                                          _resumeHeld(i);
                                        }
                                      },
                                      icon: const Icon(Icons.play_arrow_rounded, size: 17),
                                      label: const Text('استئناف'),
                                    ),
                                    const SizedBox(width: 4),
                                    // زر حذف
                                    IconButton(
                                      tooltip: 'حذف الفاتورة المعلقة',
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        color: AppColors.red,
                                        size: 20,
                                      ),
                                      onPressed: () async {
                                        final delOk = await showDialog<bool>(
                                          context: context,
                                          builder: (dCtx) => AlertDialog(
                                            title: const Text('حذف الفاتورة المعلقة؟'),
                                            content: Text('هل أنت متأكد من حذف "$label" نهائياً؟'),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.of(dCtx).pop(false),
                                                child: const Text('إلغاء'),
                                              ),
                                              FilledButton(
                                                style: FilledButton.styleFrom(
                                                  backgroundColor: AppColors.dangerOf(context),
                                                ),
                                                onPressed: () =>
                                                    Navigator.of(dCtx).pop(true),
                                                child: const Text('حذف'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (delOk == true) {
                                          _discardHeld(i);
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// لوح الفاتورة المكتبي: بنود السلة + محددات كمية مباشرة + ملخص مالي
  /// حي (الإجمالي/الخصم/الصافي) + أزرار تسوية عريضة مع قفل فوري.
  Widget _buildDesktopInvoicePane(CurrencyDef cur) {
    final entries = _cart.values.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.primaryOf(context).withValues(alpha: 0.06),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Row(
            children: [
              const Icon(Icons.receipt_long_outlined, size: 20),
              const SizedBox(width: 8),
              Text('الفاتورة الحالية',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text('$_itemCount صنف',
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.text2Of(context))),
              if (_cart.isNotEmpty) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'إفراغ السلة (Esc)',
                  icon: const Icon(Icons.delete_sweep_outlined,
                      color: AppColors.red, size: 20),
                  onPressed: _clearCart,
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? const EmptyState(
                  icon: Icons.shopping_cart_outlined,
                  title: 'السلة فارغة',
                  message: 'انقر أصنافاً من الكتالوج لإضافتها للفاتورة.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(10),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (c, i) {
                    final e = entries[i];
                    return HoverLift(
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(e.item.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13.5)),
                                  const SizedBox(height: 2),
                                  InkWell(
                                    onTap: () async {
                                      await _editUnitPrice(e);
                                      setState(() {});
                                    },
                                    borderRadius: BorderRadius.circular(4),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 2),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '${Fmt.money(e.unitPrice)} × ${Fmt.money(e.quantity)} = ${Fmt.money(e.total)} ${cur.symbol}',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color:
                                                    AppColors.text2Of(context)),
                                          ),
                                          const SizedBox(width: 4),
                                          Icon(
                                            Icons.edit_outlined,
                                            size: 13,
                                            color: AppColors.text2Of(context).withValues(alpha: 0.7),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // محدد كمية مباشر: − / كمية قابلة للنقر / +
                            IconButton(
                              tooltip: 'إنقاص',
                              iconSize: 19,
                              icon: const Icon(
                                  Icons.remove_circle_outline),
                              onPressed: () {
                                _cartCtl.setQuantity(
                                    e.item.id!, e.quantity - 1,
                                    allowNegative: _allowNegative);
                                setState(() {});
                              },
                            ),
                            InkWell(
                              onTap: () async {
                                await _editQuantity(e);
                                setState(() {});
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryOf(context)
                                      .withValues(alpha: 0.1),
                                  borderRadius:
                                      BorderRadius.circular(8),
                                ),
                                child: Text(
                                  Fmt.money(e.quantity),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'زيادة',
                              iconSize: 19,
                              icon:
                                  const Icon(Icons.add_circle_outline),
                              onPressed: () => _addItem(e.item),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        // الملخص المالي الحي.
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: BorderDirectional(
              top: BorderSide(
                color:
                    Theme.of(context).dividerColor.withValues(alpha: 0.18),
                width: 1.2,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _summaryRow('الإجمالي', _subtotal, cur),
              if (_discount > 0) _summaryRow('الخصم', -_discount, cur),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('الصافي',
                      style: Theme.of(context).textTheme.titleLarge),
                  Text(
                    '${Fmt.money(_netTotal)} ${cur.symbol}',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: AppColors.primaryOf(context),
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // أزرار تسوية عريضة + تلميحات الاختصارات.
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: _saving || _cart.isEmpty
                          ? null
                          : () => _quickSettle(_PosPayment.cash),
                      icon: const Icon(Icons.payments_outlined),
                      label: const Text('دفع نقدي (F1)'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: _saving || _cart.isEmpty
                          ? null
                          : () => _quickSettle(_PosPayment.credit),
                      icon: const Icon(Icons.schedule_outlined),
                      label: const Text('آجل (F2)'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'تعليق الفاتورة (F12)',
                    style: IconButton.styleFrom(
                      padding: const EdgeInsets.all(15),
                    ),
                    icon: const Icon(Icons.pause_circle_outline_rounded, size: 22),
                    onPressed: _saving || _cart.isEmpty
                        ? null
                        : _promptHoldInvoice,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed:
                    _saving || _cart.isEmpty ? null : _openCheckoutSheet,
                icon: const Icon(Icons.tune),
                label: const Text('خيارات الدفع الكاملة (خصم/جزئي)'),
              ),
              const SizedBox(height: 6),
              Text(
                'F3 بحث • F12 تعليق الفاتورة • Esc إفراغ',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11, color: AppColors.text3Of(context)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _summaryRow(String label, double value, CurrencyDef cur) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 13.5, color: AppColors.text2Of(context))),
            Text(
              '${Fmt.money(value)} ${cur.symbol}',
              style: const TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      );

  List<Item> _computeFilteredItems(
    List<Item> allItems,
    List<ItemCategory> categories,
  ) {
    final hasSearch = _searchQuery.trim().isNotEmpty;
    final normQ = hasSearch ? Fmt.normArabic(_searchQuery) : '';

    final catsInSection = <int>{
      for (final c in categories)
        if (_sectionMatches(c.sectionId) && c.id != null) c.id!,
    };

    final allowedCatIds = <int>{};
    if (!hasSearch && _selectedCategoryId != null) {
      allowedCatIds.add(_selectedCategoryId!);
      for (final c in categories) {
        if (c.parentId == _selectedCategoryId && c.id != null) {
          allowedCatIds.add(c.id!);
        }
      }
    }

    final filteredItems = allItems.where((item) {
      if (hasSearch) {
        final matchPlu = item.plu != null &&
            ('${item.plu}' == normQ || '${item.plu}'.startsWith(normQ));
        final matchSku = Fmt.normArabic(item.sku).contains(normQ);
        final matchNameCat =
            Fmt.smartContains('${item.name} ${item.category}', _searchQuery);
        return matchPlu || matchSku || matchNameCat;
      }

      if (_selectedCategoryId != null) {
        return item.categoryId != null && allowedCatIds.contains(item.categoryId);
      }
      if (_selectedSectionId != null && _selectedCategoryId == null) {
        if (_selectedSectionId == kGeneralSectionId) {
          final allSecs =
              ref.read(sectionsProvider).valueOrNull ?? const <Section>[];
          final activeSecIds = allSecs.map((s) => s.id).toSet();
          final effectiveSecId =
              item.sectionId ?? _sectionOfCat(categories, item.categoryId);
          return effectiveSecId == null ||
              effectiveSecId == kGeneralSectionId ||
              !activeSecIds.contains(effectiveSecId) ||
              item.categoryId == null ||
              catsInSection.contains(item.categoryId);
        } else {
          return item.sectionId == _selectedSectionId ||
              (item.categoryId != null &&
                  catsInSection.contains(item.categoryId));
        }
      }
      return true;
    }).toList();

    // (2026-09-24) الترتيب المختار من زر الفلاتر — **لا يغيّر أرقام PLU**:
    // الأرقام ثابتة للأبد ومستقلة عن أي فرز معروض.
    switch (_posSort) {
      case 1:
        filteredItems.sort((a, b) => b.sellPrice.compareTo(a.sellPrice));
      case 2:
        filteredItems.sort((a, b) => b.quantity.compareTo(a.quantity));
      default:
        filteredItems.sort((a, b) => a.name.compareTo(b.name));
    }
    return filteredItems;
  }

  Widget _buildPosSaleTab() {
    final categories = ref.watch(itemCategoriesProvider).valueOrNull ?? [];
    final allItems = ref.watch(itemsProvider).valueOrNull ?? [];
    final sections =
        ref.watch(sectionsProvider).valueOrNull ?? const <Section>[];
    final roots =
        ref.watch(itemCategoryTreeProvider).valueOrNull ?? const <ItemCategory>[];
    final currencies =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;
    final cur = currencies.first;

    final hasSearch = _searchQuery.trim().isNotEmpty;
    final filteredItems = _computeFilteredItems(allItems, categories);
    final sectionCategories = _categoriesOfSection(roots, categories);

    final catById = <int, ItemCategory>{
      for (final c in categories)
        if (c.id != null) c.id!: c,
    };
    final secById = <int, Section>{
      for (final s in sections)
        if (s.id != null) s.id!: s,
    };

    return PopScope(
      canPop: !hasSearch &&
          !_atSectionsGate &&
          _selectedSectionId == null &&
          _selectedCategoryId == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (hasSearch) {
            setState(() {
              _searchQuery = '';
              _searchCtrl.clear();
            });
          } else if (_selectedCategoryId != null) {
            setState(() => _selectedCategoryId = null);
          } else if (_selectedSectionId != null) {
            setState(() => _selectedSectionId = null);
          } else if (_atSectionsGate) {
            setState(() => _atSectionsGate = false);
          }
        }
      },
      child: Column(
        children: [
          // 1) شريط العنوان العلوي الكحلي الملكي الداكن المدمج
          _buildPosHeader(),

          // 2) حقل البحث المستقل تحت الشريط العلوي
          Container(
            color: AppColors.surfaceOf(context),
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 5),
            child: _buildPillSearch(),
          ),

          if (!hasSearch) ...[
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: _isScrolledCompact
                  ? const SizedBox.shrink()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 3) شريط الأقسام الأفقي ببطاقات الباستيل الملونة
                        PosSectionsStrip(
                          sections: sections,
                          categories: categories,
                          selectedId: _selectedSectionId,
                          onSelect: (sid) => setState(() {
                            _selectedSectionId = sid;
                            _selectedCategoryId = null;
                            _atSectionsGate = false;
                          }),
                          onAllTap: () => setState(() {
                            if (_selectedSectionId == null) {
                              _atSectionsGate = !_atSectionsGate;
                            } else {
                              _selectedSectionId = null;
                              _selectedCategoryId = null;
                              _atSectionsGate = false;
                            }
                          }),
                          onShowAll: () => setState(
                            () => _atSectionsGate = !_atSectionsGate,
                          ),
                        ),

                        // لوحة الأقسام الكاملة عند الضغط على "عرض الكل" أو "كل الأقسام"
                        if (_atSectionsGate)
                          SizedBox(
                            height: 112,
                            child: PosSectionsGate(
                              sections: sections,
                              roots: roots,
                              items: allItems,
                              padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
                              childAspectRatio: 1.25,
                              onOpen: (sid) => setState(() {
                                _selectedSectionId = sid;
                                _selectedCategoryId = null;
                                _atSectionsGate = false;
                              }),
                            ),
                          ),
                      ],
                    ),
            ),

            // 4) شريط الفئات الأفقي التابع للقسم النشط
            if (!_atSectionsGate)
              PosCategoryStrip(
                categories: sectionCategories,
                selectedId: _selectedCategoryId,
                showHeader: true,
                allItemsCount: _countSectionItems(allItems, categories),
                itemCountOf: (cat) =>
                    _countCategoryItems(cat, allItems, categories),
                onPick: (cid) => setState(() => _selectedCategoryId = cid),
                onShowAll: () => setState(() => _selectedCategoryId = null),
              ),
          ],

          // 5) رأس شبكة الأصناف (الأصناف + عرض الكل ←)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            child: Row(
              children: [
                const Icon(
                  Icons.inventory_2_outlined,
                  size: 19,
                  color: Color(0xFF0F3E78),
                ),
                const SizedBox(width: 6),
                Text(
                  'الأصناف',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textOf(context),
                  ),
                ),
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() {
                    _selectedCategoryId = null;
                    _selectedSectionId = null;
                    _searchQuery = '';
                    _searchCtrl.clear();
                  }),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'عرض الكل',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF1565C0),
                          ),
                        ),
                        SizedBox(width: 3),
                        Icon(
                          Icons.arrow_forward_rounded,
                          size: 14,
                          color: Color(0xFF1565C0),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 6) شبكة بطاقات الأصناف (تتطابق مع التصميم المرفق)
          Expanded(
            child: filteredItems.isEmpty
                ? const SingleChildScrollView(
                    child: EmptyState(
                      icon: Icons.inventory_2_outlined,
                      title: 'لا توجد أصناف مطابقة',
                      message: 'أضف أصنافاً من شاشة المخزون أو غيّر نص البحث.',
                    ),
                  )
                : NotificationListener<ScrollNotification>(
                    onNotification: (notif) {
                      if (notif is ScrollUpdateNotification &&
                          notif.metrics.axis == Axis.vertical) {
                        final px = notif.metrics.pixels;
                        if (px > 28 && !_isScrolledCompact) {
                          setState(() {
                            _isScrolledCompact = true;
                            _atSectionsGate = false;
                          });
                        } else if (px <= 8 && _isScrolledCompact) {
                          setState(() => _isScrolledCompact = false);
                        }
                      }
                      return false;
                    },
                    child: PosItemsGrid(
                      items: filteredItems,
                      symbol: cur.symbol,
                      quantityInCart: (it) => _cart[it.id]?.quantity ?? 0,
                      canAdd: (it) => it.quantity > 0 || _allowNegative,
                      onAdd: (it) => _addItem(it),
                      toneFor: (it) {
                        final cat = it.categoryId != null
                            ? catById[it.categoryId!]
                            : null;
                        final secId = it.sectionId ?? cat?.sectionId;
                        final sec = secId != null ? secById[secId] : null;
                        return IconCatalog.resolveTone(
                          colorHex: cat?.colorHex ?? sec?.colorHex,
                          iconKey: cat?.iconKey ?? sec?.iconKey,
                          fallbackSeed: it.id ?? it.name.hashCode,
                        );
                      },
                      iconFor: (it) {
                        final cat = it.categoryId != null
                            ? catById[it.categoryId!]
                            : null;
                        final secId = it.sectionId ?? cat?.sectionId;
                        final sec = secId != null ? secById[secId] : null;
                        return IconCatalog.of(cat?.iconKey ?? sec?.iconKey);
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  int _countSectionItems(List<Item> allItems, List<ItemCategory> categories) {
    if (_selectedSectionId == null) return allItems.length;
    final catsInSection = <int>{
      for (final c in categories)
        if (_sectionMatches(c.sectionId) && c.id != null) c.id!,
    };
    var count = 0;
    for (final it in allItems) {
      if (_selectedSectionId == kGeneralSectionId) {
        final effectiveSecId =
            it.sectionId ?? _sectionOfCat(categories, it.categoryId);
        if (effectiveSecId == null ||
            effectiveSecId == kGeneralSectionId ||
            it.categoryId == null ||
            catsInSection.contains(it.categoryId)) {
          count++;
        }
      } else if (it.sectionId == _selectedSectionId ||
          (it.categoryId != null && catsInSection.contains(it.categoryId))) {
        count++;
      }
    }
    return count;
  }

  int _countCategoryItems(
    ItemCategory cat,
    List<Item> allItems,
    List<ItemCategory> categories,
  ) {
    if (cat.id == null) return 0;
    final allowed = <int>{cat.id!};
    for (final c in categories) {
      if (c.parentId == cat.id && c.id != null) {
        allowed.add(c.id!);
      }
    }
    var count = 0;
    for (final it in allItems) {
      if (it.categoryId != null && allowed.contains(it.categoryId)) {
        count++;
      }
    }
    return count;
  }

  /// فئات القسم النشط مرتّبة للعرض في الشريط العلوي.
  List<ItemCategory> _categoriesOfSection(
    List<ItemCategory> roots,
    List<ItemCategory> flat,
  ) {
    final out = <ItemCategory>[];
    void collect(ItemCategory c) {
      if (_sectionMatches(c.sectionId)) out.add(c);
    }

    if (roots.isNotEmpty) {
      for (final c in roots) {
        collect(c);
      }
    } else {
      for (final c in flat) {
        collect(c);
      }
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  int? _sectionOfCat(List<ItemCategory> cats, int? catId) {
    if (catId == null) return null;
    for (final c in cats) {
      if (c.id == catId) return c.sectionId;
    }
    return null;
  }

  /// هل تنتمي الفئة إلى القسم المختار حالياً؟
  bool _sectionMatches(int? sectionId) {
    if (_selectedSectionId == null) return true;
    return _selectedSectionId == kGeneralSectionId
        ? sectionId == null
        : sectionId == _selectedSectionId;
  }

  void _openMainDrawer(BuildContext ctx) {
    ScaffoldState? drawerScaffold;
    ctx.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScaffoldState) {
        final s = element.state as ScaffoldState;
        if (s.hasDrawer) {
          drawerScaffold = s;
          return false;
        }
      }
      return true;
    });
    if (drawerScaffold != null) {
      drawerScaffold!.openDrawer();
    } else if (Scaffold.maybeOf(ctx)?.hasDrawer == true) {
      Scaffold.of(ctx).openDrawer();
    } else {
      ShellNav.go(ShellNav.home);
    }
  }

  /// الشريط العلوي الكحلي الملكي الداكن المدمج لنقطة البيع (toolbarHeight: 48.0).
  Widget _buildPosHeader() {
    final held = ref.watch(heldInvoicesProvider);
    final hasCartItems = _cart.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F3E78),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F3E78).withValues(alpha: .18),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 48.0,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                // أقصى اليمين (RTL Leading): أيقونة القائمة الجانبية لفتح Drawer التطبيق
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  tooltip: 'القائمة الجانبية',
                  icon: const Icon(Icons.menu, color: Colors.white, size: 22),
                  onPressed: () => _openMainDrawer(context),
                ),
                const SizedBox(width: 4),
                // بجوارها مباشرة: عنوان "المبيعات" (15dp) وتحته مباشرة "الأقسام ← الفئات ← الأصناف" (9.5dp)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'المبيعات',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          height: 1.05,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        'الأقسام ← الفئات ← الأصناف',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: .82),
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          height: 1.05,
                        ),
                      ),
                    ],
                  ),
                ),

                // الجهة اليسرى (Actions): أيقونة السلة مع العداد، الفلترة، الخيارات، والرئيسية
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  tooltip: 'سلة المبيعات',
                  onPressed: _openCheckoutSheet,
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(
                        Icons.shopping_cart_outlined,
                        color: Colors.white,
                        size: 21,
                      ),
                      if (_itemCount > 0)
                        PositionedDirectional(
                          top: -5,
                          end: -5,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4.5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF59E0B),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$_itemCount',
                              style: const TextStyle(
                                color: Colors.black,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                _headerIconButton(
                  icon: Icons.assignment_return_outlined,
                  tooltip: 'المرتجعات والبحث برقم الفاتورة',
                  onTap: () => setState(() => _tabController.animateTo(1)),
                ),
                _headerIconButton(
                  icon: Icons.tune_rounded,
                  tooltip: 'ترتيب وتصفية الأصناف',
                  onTap: _openPosSortSheet,
                ),
                PopupMenuButton<String>(
                  tooltip: 'خيارات إضافية',
                  padding: EdgeInsets.zero,
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(Icons.more_vert, color: Colors.white, size: 21),
                      if (held.isNotEmpty)
                        PositionedDirectional(
                          top: -3,
                          end: -3,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Color(0xFFF59E0B),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                  onSelected: (val) {
                    switch (val) {
                      case 'new_hold':
                        _quickHoldAndNewBill();
                      case 'name_hold':
                        if (hasCartItems) _promptHoldInvoice();
                      case 'held_list':
                        _showHeldSheet();
                      case 'returns':
                      case 'history':
                        setState(() => _tabController.animateTo(1));
                      case 'shortages':
                        openShortagesListSheet(context, ref);
                      case 'shortages_screen':
                        ref.read(inventoryShortagesModeProvider.notifier).state =
                            true;
                        ShellNav.go(ShellNav.inventory);
                      case 'sections_gate':
                        setState(() => _atSectionsGate = !_atSectionsGate);
                    }
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem<String>(
                      value: 'new_hold',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          hasCartItems
                              ? Icons.post_add_rounded
                              : Icons.note_add_outlined,
                        ),
                        title: Text(
                          hasCartItems
                              ? 'تعليق الفاتورة وبدء فاتورة جديدة'
                              : 'فاتورة جديدة فارغة',
                        ),
                      ),
                    ),
                    if (hasCartItems)
                      const PopupMenuItem<String>(
                        value: 'name_hold',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.bookmark_add_outlined),
                          title: Text('تعليق الفاتورة باسم...'),
                        ),
                      ),
                    PopupMenuItem<String>(
                      value: 'held_list',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.pause_circle_outline_rounded),
                        title: Text('الفواتير المعلقة (${held.length})'),
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: 'returns',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.assignment_return_outlined),
                        title: Text('المرتجعات (البحث برقم الفاتورة)'),
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: 'shortages',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.assignment_late_outlined),
                        title: Text('قائمة النواقص (حفظ كصورة / PDF)'),
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: 'shortages_screen',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.warning_amber_rounded),
                        title: Text('قسم النواقص (الأصناف تحت حد التنبيه)'),
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: 'sections_gate',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.grid_view_rounded),
                        title: Text('تصفح شبكة الأقسام'),
                      ),
                    ),
                  ],
                ),
                _headerIconButton(
                  icon: Icons.home_rounded,
                  tooltip: 'الرئيسية',
                  onTap: () => ShellNav.go(ShellNav.home),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _headerIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) =>
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        icon: Icon(icon, color: Colors.white, size: 22),
        onPressed: onTap,
      );

  /// حقل البحث بزوايا دائرية (12dp) وإطار رمادي ناعم وتلميح "ابحث عن صنف ...".
  Widget _buildPillSearch() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 42,
      child: TextField(
        controller: _searchCtrl,
        focusNode: _searchFocus,
        autofocus: isDesktopLayout(context),
        style: TextStyle(
          fontSize: 14,
          color: dark ? Colors.white : const Color(0xFF12223A),
        ),
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          filled: true,
          fillColor: dark ? const Color(0xFF1E293B) : const Color(0xFFF3F6FB),
          hintText: 'ابحث عن صنف ...',
          hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          prefixIcon: const Icon(
            Icons.search_rounded,
            size: 20,
            color: Color(0xFF94A3B8),
          ),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 40, minHeight: 40),
          border: _searchBorder(
            dark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          ),
          enabledBorder: _searchBorder(
            dark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          ),
          focusedBorder: _searchBorder(const Color(0xFF1565C0)),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'مسح الباركود',
                icon: const Icon(
                  Icons.barcode_reader,
                  size: 19,
                  color: Color(0xFF94A3B8),
                ),
                onPressed: () async {
                  final code = await scanBarcode(context);
                  if (code != null && code.isNotEmpty) {
                    _searchCtrl.text = code;
                    setState(() => _searchQuery = code.trim());
                  }
                },
              ),
              if (_searchQuery.isNotEmpty)
                IconButton(
                  icon: const Icon(
                    Icons.clear,
                    size: 19,
                    color: Color(0xFF94A3B8),
                  ),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _searchQuery = '');
                  },
                ),
            ],
          ),
        ),
        onChanged: (v) => setState(() => _searchQuery = v.trim()),
        onSubmitted: _handleSearchOrQuickSubmit,
      ),
    );
  }

  OutlineInputBorder _searchBorder(Color c) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c, width: 1),
      );

  /// (2026-09-24) **نظام الترقيم السريع (PLU) ودعم قارئ الباركود**.
  ///
  /// • يدعم مسح الباركود مباشرة (USB/Bluetooth) بالبحث المطابق للـ SKU وإضافته فوراً للسلة.
  /// • يدعم الترقيم السريع: `7` + Enter يضيف حبة واحدة، و `7*3` أو `7×3` يضيف 3 حبات.
  /// • يدعم الأرقام العربية/الفارسية تلقائياً عبر التطبيع.
  bool _handleQuickIndex(String raw, [List<Item>? itemsList]) {
    final q = Fmt.normArabic(raw).replaceAll('×', '*').trim();
    if (q.isEmpty) return false;

    final items =
        itemsList ?? (ref.read(itemsProvider).valueOrNull ?? const <Item>[]);

    // أولاً: فحص مطابقة باركود صنف (قارئات الباركود الخارجية USB / Bluetooth)
    Item? barcodeHit;
    for (final it in items) {
      if (it.sku.trim().isNotEmpty &&
          it.sku.trim().toLowerCase() == q.toLowerCase()) {
        barcodeHit = it;
        break;
      }
    }
    if (barcodeHit != null) {
      _addItem(barcodeHit, quantity: 1);
      _searchCtrl.clear();
      setState(() => _searchQuery = '');
      _searchFocus.requestFocus();
      showSnack(
        context,
        'أُضيف 1 ${barcodeHit.unit} من «${barcodeHit.name}» (باركود)',
        silent: true,
      );
      return true;
    }

    // ثانياً: مطابقة نمط الترقيم السريع PLU أو PLU*QTY
    final m = RegExp(r'^(\d+)(?:\*(\d+(?:\.\d+)?))?$').firstMatch(q);
    if (m != null) {
      final idx = int.tryParse(m.group(1)!);
      final qty = m.group(2) != null
          ? (double.tryParse(m.group(2)!) ?? 1.0)
          : 1.0;
      if (idx != null && qty > 0) {
        Item? hit;
        for (final it in items) {
          if (it.plu == idx) {
            hit = it;
            break;
          }
        }
        if (hit != null) {
          _addItem(hit, quantity: qty);
          _searchCtrl.clear();
          setState(() => _searchQuery = '');
          _searchFocus.requestFocus();
          showSnack(
            context,
            'أُضيف ${Fmt.money(qty)} ${hit.unit} من «${hit.name}» (رقم $idx)',
            silent: true,
          );
          return true;
        }
      }
    }

    return false;
  }

  /// ترتيب شبكة الأصناف — شريحة سفلية صغيرة.
  void _openPosSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceOf(ctx),
          borderRadius: AppRadius.sheetTop,
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.borderOf(ctx),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text('ترتيب الأصناف',
                style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 8),
            for (final e in const [
              (0, 'بالاسم', Icons.sort_by_alpha),
              (1, 'الأعلى سعراً', Icons.trending_up),
              (2, 'الأكثر توفراً', Icons.inventory_2_outlined),
            ])
              ListTile(
                leading: Icon(e.$3),
                title: Text(e.$2),
                trailing: _posSort == e.$1
                    ? Icon(Icons.check_circle,
                        color: AppColors.primaryOf(ctx))
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                onTap: () {
                  setState(() => _posSort = e.$1);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// شريط السلة السفلي الثابت (مطابق للصورة المرفقة: عدد الأصناف يميناً، الإجمالي بالوسط، وزر عرض السلة الأزرق يساراً).
  Widget _buildCartBottomBar() {
    final currencies =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;
    final cur = currencies.first;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceOf(context),
        border: Border(
          top: BorderSide(
            color: dark ? const Color(0xFF283548) : const Color(0xFFE5EAF2),
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .06),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // جهة اليمين (في RTL): مربع فاتح لأيقونة الفاتورة + "عدد الأصناف" والعدد
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF1E293B) : const Color(0xFFF3F6FB),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: dark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.receipt_long_outlined,
                    size: 20,
                    color: Color(0xFF1565C0),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'عدد الأصناف',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.text3Of(context),
                        ),
                      ),
                      Text(
                        '$_itemCount',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w900,
                          color: AppColors.textOf(context),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),

            // المنتصف: "الإجمالي" وقيمة المبلغ + زر حذف السلة بجانب الإجمالي
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'الإجمالي',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.text3Of(context),
                          ),
                        ),
                        const SizedBox(height: 1),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '${Fmt.money(_netTotal)} ${cur.symbol}',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w900,
                              color: AppColors.textOf(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_cart.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'حذف وإفراغ السلة',
                      child: Material(
                        color: AppColors.dangerOf(context).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(9),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: _clearCart,
                          child: Padding(
                            padding: const EdgeInsets.all(7),
                            child: Icon(
                              Icons.delete_outline_rounded,
                              size: 20,
                              color: AppColors.dangerOf(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 1,
              height: 30,
              color: dark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            ),
            const SizedBox(width: 8),

            // جهة اليسار (في RTL): زر أزرق بارز "عرض السلة (0)" مع أيقونة عربة التسوق
            SizedBox(
              height: 44,
              child: FilledButton.icon(
                onPressed: _openCheckoutSheet,
                icon: const Icon(Icons.shopping_cart_outlined, size: 18),
                label: Text(
                  'عرض السلة ($_itemCount)',
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0D6EFD),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// درج الدفع المنزلق (Slide-to-Pay): قائمة الأصناف تبقى ملء الشاشة،
  /// وكل الإدخال المالي في درج سفلي موسع — لا تغطية من لوحة المفاتيح.
  void _openCheckoutSheet() {
    ref.read(repoProvider).effectivePermissions().then((p) {
      if (mounted && p.canDiscount != _canDiscount) {
        setState(() => _canDiscount = p.canDiscount);
      }
    });
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final kb = MediaQuery.viewInsetsOf(ctx).bottom;
        final bottomSysPad = MediaQuery.of(ctx).viewPadding.bottom;
        final h = MediaQuery.sizeOf(ctx).height;
        final maxH = (h - kb - 20).clamp(260.0, h * 0.78);
        return SafeArea(
          bottom: true,
          child: Padding(
            padding: EdgeInsets.only(bottom: kb + bottomSysPad),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxH),
              child: StatefulBuilder(
                builder: (context, setSheetState) {
                  final accounts =
                      ref.watch(allAccountsProvider).valueOrNull ?? [];
                  final currencies =
                      ref.watch(currenciesProvider).valueOrNull ??
                          kDefaultCurrencies;
                  final cur = currencies.first;
                  final customers = accounts
                      .where(
                        (a) =>
                            a.kind == AccountKind.customer ||
                            a.kind == AccountKind.general,
                      )
                      .toList();
                  final selectedAccount = customers
                      .where((c) => c.id == _selectedCustomerId)
                      .firstOrNull;
                  final isGenericCashCustomer = selectedAccount != null &&
                      (selectedAccount.name.trim() == 'عميل نقدي' ||
                          selectedAccount.name.trim() == 'عميل نقدي عام');
                  final needsAccount = _payment != _PosPayment.cash;
                  final accountMissing = needsAccount &&
                      (_selectedCustomerId == null || isGenericCashCustomer);
                  final paidNow = _payment == _PosPayment.partial
                      ? (Fmt.parseAmount(
                              ThousandsFormatter.strip(_paidCtrl.text)) ??
                          0.0)
                      : (_payment == _PosPayment.cash ? _netTotal : 0.0);
                  final remainingNow =
                      (_netTotal - paidNow).clamp(0.0, double.infinity);
                  final partialInvalid = _payment == _PosPayment.partial &&
                      (_netTotal <= 0.01 ||
                          paidNow < 0.01 ||
                          paidNow > (_netTotal - 0.01) ||
                          paidNow >= _netTotal);

                  final heldCount = ref.watch(heldInvoicesProvider).length;

                  return Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                      Row(
                        children: [
                          const Text(
                            'إتمام الفاتورة 🛒',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          // زر فاتورة جديدة (+): يعلّق الفاتورة الحالية تلقائياً ويفتح سلة جديدة فارغة
                          FilledButton.tonalIcon(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 5,
                              ),
                              textStyle: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            onPressed: () {
                              _quickHoldAndNewBill();
                              setSheetState(() {});
                              setState(() {});
                              if (_cart.isEmpty && Navigator.canPop(ctx)) {
                                Navigator.pop(ctx);
                              }
                            },
                            icon: const Icon(Icons.add_circle_outline_rounded, size: 15),
                            label: const Text('فاتورة جديدة (+)'),
                          ),
                          const SizedBox(width: 6),
                          // زر / شارة الفواتير المعلقة ⏸️ المعلقة (X)
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 5,
                              ),
                              textStyle: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _showHeldSheet();
                            },
                            icon: const Icon(Icons.pause_circle_outline_rounded, size: 15),
                            label: Text('⏸️ المعلقة ($heldCount)'),
                          ),
                          const SizedBox(width: 2),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                      const Divider(height: 8),
                      Flexible(
                        child: SingleChildScrollView(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // قائمة أصناف السلة — الكمية قابلة للنقر لإدخال مباشر.
                              for (final entry in _cart.values) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.item.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                InkWell(
                                  onTap: () async {
                                    await _editUnitPrice(entry);
                                    setSheetState(() {});
                                    setState(() {});
                                  },
                                  borderRadius: BorderRadius.circular(4),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          '${Fmt.money(entry.unitPrice)} ${cur.symbol} / ${entry.item.unit}',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: AppColors.text2Of(context),
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Icon(
                                          Icons.edit_outlined,
                                          size: 13,
                                          color: AppColors.text2Of(context).withValues(alpha: 0.7),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(
                                  Icons.remove_circle_outline,
                                  size: 20,
                                ),
                                onPressed: () {
                                  final q = entry.quantity - 1;
                                  _cartCtl.setQuantity(entry.item.id!, q,
                                      allowNegative: _allowNegative);
                                  setSheetState(() {});
                                  setState(() {});
                                },
                              ),
                              // نقرة على الكمية = لوحة إدخال رقمي سريعة.
                              InkWell(
                                onTap: () async {
                                  await _editQuantity(entry);
                                  setSheetState(() {});
                                  setState(() {});
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                        color: AppColors.primaryOf(context)
                                            .withValues(alpha: .4)),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    Fmt.money(entry.quantity),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.add_circle_outline,
                                  size: 20,
                                ),
                                onPressed: () {
                                  final ok = _cartCtl.setQuantity(
                                      entry.item.id!, entry.quantity + 1,
                                      allowNegative: _allowNegative);
                                  if (!ok) {
                                    Sfx.reject();
                                    showSnack(
                                      context,
                                      'الكمية المتاحة: ${entry.item.quantity.toStringAsFixed(0)} ${entry.item.unit} فقط',
                                      error: true,
                                    );
                                    return;
                                  }
                                  setSheetState(() {});
                                  setState(() {});
                                },
                              ),
                            ],
                          ),
                          SizedBox(
                            width: 75,
                            child: Text(
                              '${Fmt.money(entry.total)} ${cur.symbol}',
                              textAlign: TextAlign.end,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 12),
                    ],

                    const SizedBox(height: 10),

                    // طريقة الدفع أولاً — تحدد هل نحتاج حساب عميل.
                    SegmentedButton<_PosPayment>(
                      segments: _PosPayment.values
                          .map(
                            (p) =>
                                ButtonSegment(value: p, label: Text(p.label)),
                          )
                          .toList(),
                      selected: {_payment},
                      onSelectionChanged: (set) {
                        _cartCtl.setPayment(set.first.code);
                        setSheetState(() {});
                        setState(() {});
                      },
                    ),

                    const SizedBox(height: 12),

                    // اختيار العميل — يتوهج بالأحمر إذا كان الدفع آجلاً
                    // بلا حساب محدد (تنبيه بصري لا نصي فقط).
                    Container(
                      decoration: accountMissing
                          ? BoxDecoration(
                              border: Border.all(
                                  color: AppColors.dangerOf(context),
                                  width: 2),
                              borderRadius: BorderRadius.circular(10),
                            )
                          : null,
                      padding:
                          accountMissing ? const EdgeInsets.all(6) : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (accountMissing)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                'يجب اختيار أو تسجيل حساب عميل لتسجيل المديونية/المتبقي الآجل',
                                style: TextStyle(
                                  color: AppColors.dangerOf(context),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          // آخر 3 مدينين — اختيار بنقرة واحدة في وضع الآجل.
                          if (needsAccount)
                            FutureBuilder<List<Account>>(
                              future: _recentDebtors(customers),
                              builder: (c, snap) {
                                final recents = snap.data ?? const <Account>[];
                                if (recents.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: SizedBox(
                                    height: 38,
                                    child: ListView(
                                      scrollDirection: Axis.horizontal,
                                      children: [
                                        for (final a in recents)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                left: 6),
                                            child: ChoiceChip(
                                              label: Text(a.name,
                                                  overflow:
                                                      TextOverflow.ellipsis),
                                              selected:
                                                  _selectedCustomerId == a.id,
                                              onSelected: (_) {
                                                _cartCtl.setCustomer(a.id);
                                                setSheetState(() {});
                                                setState(() {});
                                              },
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          DropdownButtonFormField<int?>(
                            initialValue: _selectedCustomerId,
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: 'العميل',
                              prefixIcon: Icon(Icons.person_outline),
                            ),
                            items: [
                              const DropdownMenuItem<int?>(
                                value: null,
                                child: Text('عميل نقدي (بدون حساب)'),
                              ),
                              for (final c in customers)
                                DropdownMenuItem<int?>(
                                  value: c.id,
                                  child: Text(
                                    '${c.name} (${c.phone.isNotEmpty ? c.phone : 'بدون هاتف'})',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (val) {
                              _cartCtl.setCustomer(val);
                              setSheetState(() {});
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                    ),

                    // تحذير تجاوز حد الائتمان — قبل السماح بالتأكيد.
                    if (needsAccount && _selectedCustomerId != null)
                      FutureBuilder<_CreditCheck?>(
                        future: _checkCreditLimit(),
                        builder: (c, snap) {
                          final chk = snap.data;
                          if (chk == null || !chk.exceeded) {
                            return const SizedBox.shrink();
                          }
                          return Container(
                            margin: const EdgeInsets.only(top: 10),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.dangerOf(context)
                                  .withValues(alpha: .1),
                              border: Border.all(
                                  color: AppColors.dangerOf(context)),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '🚨 هذه الفاتورة تتجاوز حد الائتمان للعميل!\n'
                              'الحد: ${Fmt.money(chk.limit)} ${cur.symbol} — '
                              'الدين الحالي: ${Fmt.money(chk.currentDebt)} ${cur.symbol}\n'
                              'المتبقي من الحد: ${Fmt.money(chk.remaining)} ${cur.symbol}',
                              style: TextStyle(
                                color: AppColors.dangerOf(context),
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                                height: 1.6,
                              ),
                            ),
                          );
                        },
                      ),

                    if (_payment == _PosPayment.partial) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _paidCtrl,
                        autovalidateMode: AutovalidateMode.always,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: const [ThousandsFormatter()],
                        validator: (val) {
                          final raw = ThousandsFormatter.strip(val ?? '').trim();
                          final p = Fmt.parseAmount(raw);
                          if (p == null || !p.isFinite) {
                            return 'أدخل المبلغ المدفوع مقدماً (من 0.01 إلى ${Fmt.money((_netTotal - 0.01).clamp(0.01, double.infinity), 2)})';
                          }
                          if (p < 0) {
                            return 'لا يُسمح بإدخال مبلغ مدفوع بالسالب';
                          }
                          if (p < 0.01) {
                            return 'المبلغ المدفوع يجب أن يكون 0.01 على الأقل (أو اختر آجل كامل)';
                          }
                          if (p > (_netTotal - 0.01) || p >= _netTotal) {
                            return 'المبلغ المدفوع يجب أن يكون أقل من الصافي (${Fmt.money((_netTotal - 0.01).clamp(0.01, double.infinity), 2)}) — أو اختر نقداً';
                          }
                          return null;
                        },
                        decoration: InputDecoration(
                          labelText: 'المبلغ المدفوع مقدماً',
                          prefixIcon: const Icon(Icons.payments_outlined),
                          isDense: true,
                          // أزرار الأصفار السريعة داخل الحقل.
                          suffixIcon: _ZeroButtons(controller: _paidCtrl,
                              onChanged: () {
                            _cartCtl.setPaid(_paidCtrl.text);
                            setSheetState(() {});
                            setState(() {});
                          }),
                        ),
                        onChanged: (v) {
                          _cartCtl.setPaid(v);
                          setSheetState(() {});
                          setState(() {});
                        },
                      ),
                      AmountWords(controller: _paidCtrl),
                    ],

                    const SizedBox(height: 12),

                    // الخصم المزدوج: نسبة % أو مبلغ مقطوع — صلاحية الخصم مع تخطي المشرف (Supervisor Override)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: _hasDiscountPermission
                                ? null
                                : () => _promptSupervisorOverride(setSheetState),
                            child: IgnorePointer(
                              ignoring: !_hasDiscountPermission,
                              child: TextField(
                                controller: _discountCtrl,
                                enabled: _hasDiscountPermission,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                                inputFormatters: _draft.discountIsPercent
                                    ? null
                                    : const [ThousandsFormatter()],
                                decoration: InputDecoration(
                                  labelText: _draft.discountIsPercent
                                      ? 'نسبة الخصم %'
                                      : 'مبلغ الخصم',
                                  prefixIcon:
                                      const Icon(Icons.discount_outlined),
                                  suffixIcon: !_hasDiscountPermission
                                      ? Tooltip(
                                          message:
                                              'طلب إذن المشرف لتطبيق الخصم',
                                          child: IconButton(
                                            icon: const Icon(
                                              Icons.lock_outline_rounded,
                                              color: Colors.amber,
                                            ),
                                            onPressed: () =>
                                                _promptSupervisorOverride(
                                                    setSheetState),
                                          ),
                                        )
                                      : (_supervisorOverride
                                          ? const Icon(Icons.verified,
                                              color: Colors.green)
                                          : null),
                                  helperText: !_hasDiscountPermission
                                      ? 'الخصم مقفل — انقر لطلب إذن المشرف برمز PIN'
                                      : (_supervisorOverride
                                          ? 'معتمد من المشرف ✅'
                                          : null),
                                  helperStyle: !_hasDiscountPermission
                                      ? const TextStyle(
                                          color: Colors.amber, fontSize: 11)
                                      : const TextStyle(
                                          color: Colors.green, fontSize: 11),
                                  isDense: true,
                                  filled: !_hasDiscountPermission,
                                  fillColor: !_hasDiscountPermission
                                      ? (Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? Colors.white10
                                          : Colors.black.withValues(alpha: .04))
                                      : null,
                                ),
                                onChanged: (v) {
                                  _cartCtl.setDiscount(v);
                                  setSheetState(() {});
                                  setState(() {});
                                },
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Opacity(
                          opacity: _hasDiscountPermission ? 1.0 : 0.5,
                          child: IgnorePointer(
                            ignoring: !_hasDiscountPermission,
                            child: SegmentedButton<bool>(
                              style: const ButtonStyle(
                                visualDensity: VisualDensity.compact,
                              ),
                              segments: const [
                                ButtonSegment(value: false, label: Text('مبلغ')),
                                ButtonSegment(value: true, label: Text('٪')),
                              ],
                              selected: {_draft.discountIsPercent},
                              onSelectionChanged: (set) {
                                _cartCtl.setDiscountIsPercent(set.first);
                                setSheetState(() {});
                                setState(() {});
                              },
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
            // الملخص المالي وزر التأكيد مثبتان أسفل النافذة وفوق الكيبورد دائماً
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.primarySoftOf(context),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('المجموع الفرعي:',
                          style: TextStyle(fontSize: 12.5)),
                      Text('${Fmt.money(_subtotal)} ${cur.symbol}',
                          style: const TextStyle(fontSize: 12.5)),
                    ],
                  ),
                  if (_discount > 0) ...[
                    const SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _draft.discountIsPercent
                              ? 'الخصم (${_draft.discountText.trim()}٪):'
                              : 'الخصم:',
                          style: const TextStyle(
                              color: AppColors.red, fontSize: 12.5),
                        ),
                        Text(
                          '-${Fmt.money(_discount)} ${cur.symbol}',
                          style: const TextStyle(
                              color: AppColors.red, fontSize: 12.5),
                        ),
                      ],
                    ),
                  ],
                  const Divider(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'الصافي الإجمالي:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        '${Fmt.money(_netTotal)} ${cur.symbol}',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 17,
                          color: AppColors.primaryOf(context),
                        ),
                      ),
                    ],
                  ),
                  if (_payment == _PosPayment.partial) ...[
                    const Divider(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'المبلغ المدفوع مقدماً:',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.green,
                          ),
                        ),
                        Text(
                          '${Fmt.money(paidNow, cur.decimal)} ${cur.symbol}',
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            color: AppColors.green,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'المبلغ المتبقي (آجل):',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.red,
                          ),
                        ),
                        Text(
                          '${Fmt.money(remainingNow, cur.decimal)} ${cur.symbol}',
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            color: AppColors.red,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            // زر تأكيد عريض مع قفل فوري ضد النقر المزدوج وحظر عند غياب العميل أو عدم صحة الدفعة الجزئية.
            SizedBox(
              width: double.infinity,
              height: 46,
              child: FilledButton.icon(
                onPressed: (_saving || accountMissing || partialInvalid)
                    ? null
                    : () => _executeSale(ctx),
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_circle_outline, size: 20),
                label: Text(
                  _saving ? 'جارٍ الحفظ…' : 'تأكيد وإصدار الفاتورة',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  ),
),
),
);
      },
    );
  }

  /// أحدث 3 عملاء لهم مبيعات آجلة — للاختيار بنقرة واحدة بدون مسح جدول العمليات كاملاً.
  Future<List<Account>> _recentDebtors(List<Account> customers) async {
    try {
      final repo = ref.read(repoProvider);
      final ids = await repo.recentDebtorAccountIds(limit: 3);
      final out = <Account>[];
      for (final id in ids) {
        final a = customers.where((c) => c.id == id).firstOrNull;
        if (a != null) out.add(a);
        if (out.length >= 3) break;
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// فحص حد الائتمان للعميل المحدد مقابل صافي الفاتورة الحالية.
  Future<_CreditCheck?> _checkCreditLimit() async {
    final id = _selectedCustomerId;
    if (id == null) return null;
    try {
      final repo = ref.read(repoProvider);
      final acc = await repo.account(id);
      if (acc == null || acc.creditLimit == null || acc.creditLimit! <= 0) {
        return null;
      }
      final balance = await repo.balanceOf(acc);
      // الرصيد الموجب = دين على العميل. الجزئي يضيف المتبقي فقط.
      final debt = balance > 0 ? balance : 0.0;
      var added = _netTotal;
      if (_payment == _PosPayment.partial) {
        final paid =
            Fmt.parseAmount(ThousandsFormatter.strip(_paidCtrl.text)) ?? 0.0;
        added = (_netTotal - paid).clamp(0.0, double.infinity);
      }
      final limit = acc.creditLimit!;
      return _CreditCheck(
        limit: limit,
        currentDebt: debt,
        exceeded: debt + added > limit,
        remaining: (limit - debt).clamp(0.0, double.infinity),
      );
    } catch (_) {
      return null;
    }
  }

  /// ينفّذ البيع. [sheetCtx] سياق درج الدفع ليُغلق بعد النجاح —
  /// null عند التنفيذ المباشر (اختصارات سطح المكتب F1/F2) بلا درج.
  Future<void> _executeSale(BuildContext? sheetCtx) async {
    if (_cart.isEmpty || _saving) return;

    final repo = ref.read(repoProvider);
    if (_payment == _PosPayment.credit || _payment == _PosPayment.partial) {
      if (_selectedCustomerId == null) {
        Sfx.reject();
        showSnack(
          context,
          'يجب اختيار أو تسجيل حساب عميل لتسجيل المديونية/المتبقي الآجل',
          error: true,
          silent: true,
        );
        return;
      }
      final acc = await repo.account(_selectedCustomerId!);
      final accName = acc?.name.trim() ?? '';
      if (acc == null || accName == 'عميل نقدي' || accName == 'عميل نقدي عام') {
        Sfx.reject();
        if (!mounted) return;
        showSnack(
          context,
          'يجب اختيار أو تسجيل حساب عميل لتسجيل المديونية/المتبقي الآجل',
          error: true,
          silent: true,
        );
        return;
      }
      // (منع صارم) تجاوز حد الائتمان يوقف إتمام الفاتورة الآجلة/الجزئية —
      // كان مجرد تحذير بصري في درج الدفع لا يمنع التنفيذ إطلاقًا.
      final creditLimit = acc.creditLimit ?? 0;
      if (creditLimit > 0) {
        final balance = await repo.balanceOf(acc);
        final debtNow = balance > 0 ? balance : 0.0;
        var added = _netTotal;
        if (_payment == _PosPayment.partial) {
          final paidNow = Fmt.parseAmount(
              ThousandsFormatter.strip(_paidCtrl.text));
          final paidVal = paidNow ?? 0.0;
          added = (_netTotal - paidVal).clamp(0.0, double.infinity);
        }
        if (debtNow + added > creditLimit) {
          Sfx.reject();
          if (!mounted) return;
          showSnack(
            context,
            '🚨 تجاوز حد الائتمان للعميل «${acc.name}»: الحد ${Fmt.money(creditLimit)} — '
            'الدين الحالي ${Fmt.money(debtNow)} — المتاح من الحد '
            '${Fmt.money((creditLimit - debtNow).clamp(0.0, double.infinity))}. '
            'عدّل حد الائتمان أو اختر الدفع النقدي.',
            error: true,
            silent: true,
          );
          return;
        }
      }
      if (_payment == _PosPayment.partial) {
        final paidRaw =
            Fmt.parseAmount(ThousandsFormatter.strip(_paidCtrl.text));
        if (paidRaw == null || !paidRaw.isFinite || paidRaw < 0) {
          Sfx.reject();
          if (!mounted) return;
          showSnack(
            context,
            'لا يمكن إدخال مبلغ مدفوع سالب أو غير صالح في الدفع الجزئي',
            error: true,
            silent: true,
          );
          return;
        }
        if (paidRaw < 0.01) {
          Sfx.reject();
          if (!mounted) return;
          showSnack(
            context,
            'في الدفع الجزئي يجب أن يكون المبلغ المدفوع 0.01 على الأقل (أو اختر البيع الآجل الكامل)',
            error: true,
            silent: true,
          );
          return;
        }
        if (paidRaw > (_netTotal - 0.01) || paidRaw >= _netTotal) {
          Sfx.reject();
          if (!mounted) return;
          showSnack(
            context,
            'المبلغ المدفوع يساوي أو يتجاوز إجمالي الفاتورة — اختر الدفع النقدي الكامل أو أدخل مبلغاً أقل من الإجمالي',
            error: true,
            silent: true,
          );
          return;
        }
      }
    }

    setState(() => _saving = true);

    try {
      final currencies = await repo.currencies();
      final cur = currencies.first;
      // رقم فاتورة تسلسلي رقمي بحت (بدون أحرف)
      final refNum = await repo.nextTxNumber();

      // 1. تجهيز أسطر الفاتورة
      final lines = _cart.values.map((e) {
        return InvoiceLine(
          itemId: e.item.id,
          name: e.item.name,
          unit: e.item.unit,
          quantity: e.quantity,
          unitPrice: e.unitPrice,
          total: e.total,
        );
      }).toList();

      // 2. حفظ الفاتورة وخصم المخزون في معاملة ذرية موحدة (Single DB Transaction)
      // إذا فشل خصم أي صنف (بسبب نفاد الكمية أو غيره)، يتم التراجع عن المعاملة بالكامل (Rollback) تلقائياً.
      late final int txId;
      final now = DateTime.now();
      final user = ref.read(currentUserProvider).valueOrNull;
      final int? creatorId = user?.id;
      final cashierName = user?.name.trim().isNotEmpty == true ? user!.name : 'الكاشير';
      final discountNote = _discount > 0
          ? '\nالخصم: ${Fmt.money(_discount)} ${cur.symbol}'
          : '';
      final supNote = _supervisorOverride
          ? '\n[تم اعتماد الخصم بواسطة المشرف]'
          : '';
      final selectedAcc = _selectedCustomerId == null
          ? null
          : await repo.account(_selectedCustomerId!);
      final selectedAccKind = selectedAcc?.kind ?? AccountKind.customer;

      if (_payment == _PosPayment.cash) {
        // مبيعات نقدية: إيراد بصفر أثر على مديونية العميل (فاتورة نقدية مدفوعة)
        final tx = Tx(
          accountId: _selectedCustomerId,
          accountKind: selectedAccKind,
          amount: _netTotal,
          currency: cur.code,
          type: OpType.revenue,
          date: now,
          description: 'فاتورة نقدية مدفوعة رقم #$refNum',
          reference: refNum,
          notes:
              'طريقة الدفع: مدفوع نقداً\nالمبلغ المدفوع: ${Fmt.money(_netTotal)} ${cur.symbol}\nالمتبقي: 0.00 ${cur.symbol}$discountNote$supNote',
          createdByUserId: creatorId,
          cashierName: cashierName,
          createdAt: now,
          updatedAt: now,
        );
        txId = await repo.saveTx(tx, items: lines, deductStock: true);
      } else if (_payment == _PosPayment.credit) {
        // مبيعات آجلة: قيد مدين على العميل (عليه)
        final tx = Tx(
          accountId: _selectedCustomerId!,
          accountKind: selectedAccKind,
          amount: _netTotal,
          currency: cur.code,
          type: OpType.debit,
          date: now,
          description: 'فاتورة مبيعات آجلة رقم #$refNum',
          reference: refNum,
          notes:
              'طريقة الدفع: آجل (على الحساب)\nالمبلغ المدفوع: 0.00 ${cur.symbol}\nالمبلغ المتبقي: ${Fmt.money(_netTotal)} ${cur.symbol}$discountNote$supNote',
          createdByUserId: creatorId,
          cashierName: cashierName,
          createdAt: now,
          updatedAt: now,
        );
        txId = await repo.saveTx(tx, items: lines, deductStock: true);
      } else {
        // مبيعات جزئية: قيد بالباقي + قبض بالمقدم + خصم المخزون في معاملة ذرية واحدة
        final paid =
            Fmt.parseAmount(ThousandsFormatter.strip(_paidCtrl.text)) ?? 0.0;
        final remainder = (_netTotal - paid).clamp(0.0, double.infinity);

        final debitTx = Tx(
          accountId: _selectedCustomerId!,
          accountKind: selectedAccKind,
          amount: _netTotal,
          currency: cur.code,
          type: OpType.debit,
          date: now,
          description:
              'فاتورة مبيعات جزئية رقم #$refNum (إجمالي ${Fmt.money(_netTotal)} ${cur.symbol} — مدفوع ${Fmt.money(paid)} ${cur.symbol} — متبقي ${Fmt.money(remainder)} ${cur.symbol})',
          reference: refNum,
          notes:
              'طريقة الدفع: جزئي (مقدم + آجل)\nالمبلغ المدفوع: ${Fmt.money(paid)} ${cur.symbol}\nالمبلغ المتبقي: ${Fmt.money(remainder)} ${cur.symbol}$discountNote$supNote',
          createdByUserId: creatorId,
          cashierName: cashierName,
          createdAt: now,
          updatedAt: now,
        );

        final payTx = Tx(
          accountId: _selectedCustomerId!,
          accountKind: selectedAccKind,
          amount: paid,
          currency: cur.code,
          type: OpType.inflow,
          date: now,
          description:
              'دفعة مقدمة من فاتورة #$refNum (المتبقي: ${Fmt.money(remainder)} ${cur.symbol})',
          reference: '',
          createdByUserId: creatorId,
          cashierName: cashierName,
          createdAt: now,
          updatedAt: now,
        );

        txId = await repo.saveTx(
          debitTx,
          items: lines,
          deductStock: true,
          companionTx: payTx,
        );
      }

      // تحديث البيانات
      bump(ref);
      if (mounted && (await repo.settings())['warnLowStock'] != '0') {
        final low = <String>[];
        for (final line in lines) {
          if (line.itemId == null) continue;
          final it = await repo.item(line.itemId!);
          if (it != null &&
              it.minQuantity > 0 &&
              it.quantity <= it.minQuantity) {
            low.add(
              '${it.name} (${it.quantity.toStringAsFixed(0)} ${it.unit})',
            );
          }
        }
        if (low.isNotEmpty && mounted) {
          Sfx.warning();
          showSnack(
            context,
            '⚠️ أصناف وصلت حد إعادة الطلب:\n${low.join('، ')}',
            error: true,
            silent: true,
          );
        }
      }

      if (mounted) {
        final isPartialSale = _payment == _PosPayment.partial;
        final paidAmt = isPartialSale
            ? (Fmt.parseAmount(ThousandsFormatter.strip(_paidCtrl.text)) ?? 0.0)
            : (_payment == _PosPayment.cash ? _netTotal : 0.0);
        final remAmt = (_netTotal - paidAmt).clamp(0.0, double.infinity);
        final totAmt = _netTotal;
        final sym = cur.symbol;
        if (sheetCtx != null && sheetCtx.mounted) Navigator.pop(sheetCtx);
        Sfx.opCreated(); // صوت الدفع + اهتزاز طويل (1.5 ث) عند إنشاء العملية.
        _clearCart();

        if (isRealDesktop) {
          // في نسخة الويندوز: إرسال أمر الطباعة في الخلفية فوراً دون إرباك الموظف بنوافذ إضافية.
          showSnack(
            context,
            'تم حفظ الفاتورة #$refNum وإرسال أمر الطباعة في الخلفية ✅',
            silent: true,
          );
          unawaited(_printThermalInvoiceInBackground(txId, selectedAcc, lines));
        } else if (TxShare.isAutoShareConfigured(selectedAcc)) {
          final savedTx = await repo.transactionById(txId);
          if (savedTx != null && mounted) {
            unawaited(
              TxShare.sendNow(
                context,
                ref,
                tx: savedTx,
                account: selectedAcc,
              ),
            );
          }
        } else {
          _showSuccessDialog(
            txId,
            refNum,
            lines,
            totalAmount: totAmt,
            paidAmount: isPartialSale ? paidAmt : null,
            remainingAmount: isPartialSale ? remAmt : null,
            currencySymbol: sym,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Sfx.error();
        final msg = e is StateError ? e.message : 'تعذّر إتمام الفاتورة: $e';
        showSnack(
          context,
          msg,
          error: true,
          silent: true,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _printThermalInvoiceInBackground(
    int txId,
    Account? account,
    List<InvoiceLine> lines,
  ) async {
    try {
      final repo = ref.read(repoProvider);
      final tx = await repo.transactionById(txId);
      if (tx == null) return;
      final acc = account ??
          (tx.accountId == null ? null : await repo.account(tx.accountId!));
      final stamp = await featureNeedsStamp(ref, Feature.reportsExport);
      final st = await repo.settings();
      final orgName = (st['businessName'] ?? 'المتجر').trim();
      final orgPhone = (st['phone'] ?? '').trim();
      final orgAddress =
          (st['address'] ?? st['businessAddress'] ?? st['orgAddress'] ?? '')
              .trim();
      var sellerOrDevice = (st['user.name'] ??
              st['currentUserName'] ??
              st['cashierName'] ??
              st['ownerName'] ??
              st['devicePrefix'] ??
              '')
          .trim();
      if (sellerOrDevice.isEmpty) {
        sellerOrDevice = 'الجهاز الرئيسي';
      }
      final footer = (st['voucherFooter'] ?? 'شكراً لزيارتكم!').trim();
      final logoPath = (st['logo'] ??
              st['logoPath'] ??
              st['account.photoPath'] ??
              '')
          .trim();
      final logoBase64 =
          (st['org.icon.b64'] ?? st['logoBase64'] ?? '').trim();

      final bytes = await buildThermalInvoicePdf(
        tx: tx,
        account: acc,
        lines: lines,
        orgName: orgName,
        orgPhone: orgPhone,
        footer: footer,
        orgAddress: orgAddress,
        sellerOrDevice: sellerOrDevice,
        logoPath: logoPath,
        logoBase64: logoBase64,
        stamp: stamp,
      );

      try {
        final printers = await Printing.listPrinters();
        final defaultPrinter = printers.where((p) => p.isDefault).firstOrNull ??
            printers.firstOrNull;
        if (defaultPrinter != null) {
          final printed = await Printing.directPrintPdf(
            printer: defaultPrinter,
            onLayout: (_) async => bytes,
            name: 'invoice-${tx.reference}.pdf',
          );
          if (printed) return;
        }
      } catch (_) {}

      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: 'invoice-${tx.reference}.pdf',
      );
    } catch (_) {}
  }

  void _showSuccessDialog(
    int txId,
    String refNum,
    List<InvoiceLine> lines, {
    double? totalAmount,
    double? paidAmount,
    double? remainingAmount,
    String currencySymbol = '',
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        bool sharing = false;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.check_circle, color: AppColors.green),
                SizedBox(width: 8),
                Text('تمت العملية بنجاح ✅'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('رقم الفاتورة: $refNum'),
                Text('عدد الأصناف: ${lines.length}'),
                if (totalAmount != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'إجمالي الفاتورة: ${Fmt.money(totalAmount)} $currencySymbol',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
                if (paidAmount != null && remainingAmount != null) ...[
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.orange.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '✅ المبلغ المدفوع: ${Fmt.money(paidAmount)} $currencySymbol',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: AppColors.green,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '🔴 المبلغ المتبقي (آجل): ${Fmt.money(remainingAmount)} $currencySymbol',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: AppColors.red,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                const Text(
                  'يمكنك طباعة الإيصال الحراري أو مشاركة الفاتورة وصورة السند عالية الدقة عبر نافذة مشاركة النظام:',
                ),
              ],
            ),
            actions: [
              OutlinedButton.icon(
                icon: const Icon(Icons.print_outlined),
                label: const Text('طباعة إيصال حراري (80mm)'),
                onPressed: sharing
                    ? null
                    : () async {
                        final repo = ref.read(repoProvider);
                        final tx = await repo.transactionById(txId);
                        if (tx == null) return;
                        final acc = tx.accountId == null
                            ? null
                            : await repo.account(tx.accountId!);
                        final stamp =
                            await featureNeedsStamp(ref, Feature.reportsExport);
                        if (context.mounted) {
                          await _printThermalInvoice(
                            tx,
                            acc,
                            lines,
                            stamp: stamp,
                          );
                        }
                      },
              ),
              FilledButton.icon(
                icon: sharing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.share_outlined),
                label: Text(sharing ? 'جارٍ التجهيز…' : 'مشاركة'),
                onPressed: sharing
                    ? null
                    : () async {
                        setDialogState(() => sharing = true);
                        try {
                          final repo = ref.read(repoProvider);
                          final tx = await repo.transactionById(txId);
                          if (!mounted || tx == null) return;
                          final acc = tx.accountId == null
                              ? null
                              : await repo.account(tx.accountId!);
                          if (!mounted) return;
                          if (TxShare.isAutoShareConfigured(acc)) {
                            await TxShare.sendNow(
                              context,
                              ref,
                              tx: tx,
                              account: acc,
                            );
                          } else {
                            await TxShare.shareViaSystemSheet(
                              context,
                              ref,
                              tx: tx,
                              account: acc,
                            );
                          }
                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                          }
                        } finally {
                          if (ctx.mounted) {
                            setDialogState(() => sharing = false);
                          }
                        }
                      },
              ),
              TextButton(
                onPressed: sharing ? null : () => Navigator.pop(ctx),
                child: const Text('فاتورة جديدة'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _printThermalInvoice(
    Tx tx,
    Account? account,
    List<InvoiceLine> lines, {
    bool stamp = false,
  }) async {
    final repo = ref.read(repoProvider);
    final st = await repo.settings();
    final orgName = (st['businessName'] ?? 'المتجر').trim();
    final orgPhone = (st['phone'] ?? '').trim();
    final orgAddress =
        (st['address'] ?? st['businessAddress'] ?? st['orgAddress'] ?? '')
            .trim();
    var sellerOrDevice = (st['user.name'] ??
            st['currentUserName'] ??
            st['cashierName'] ??
            st['ownerName'] ??
            st['devicePrefix'] ??
            '')
        .trim();
    if (sellerOrDevice.isEmpty) {
      sellerOrDevice = 'الجهاز الرئيسي';
    }
    final footer = (st['voucherFooter'] ?? 'شكراً لزيارتكم!').trim();
    final logoPath = (st['logo'] ??
            st['logoPath'] ??
            st['account.photoPath'] ??
            '')
        .trim();
    final logoBase64 =
        (st['org.icon.b64'] ?? st['logoBase64'] ?? '').trim();

    // (2026-09-24) بناء الفاتورة انتقل إلى thermal_invoice_doc.dart: المستند
    // صار يحمل الخط العربي المدمج (Cairo) واتجاه RTL، بدل مستند بلا ثيم
    // الذي كان يُخرج الحروف العربية مربعات «▯» في المعاينة والطباعة.
    final bytes = await buildThermalInvoicePdf(
      tx: tx,
      account: account,
      lines: lines,
      orgName: orgName,
      orgPhone: orgPhone,
      footer: footer,
      orgAddress: orgAddress,
      sellerOrDevice: sellerOrDevice,
      logoPath: logoPath,
      logoBase64: logoBase64,
      stamp: stamp,
    );

    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: 'invoice-${tx.reference}.pdf',
    );
  }
}
/// تبويب المرتجعات وسجل فواتير المبيعات (البحث برقم الفاتورة أو اسم العميل وإرجاع صنف أو فاتورة كاملة).
class _PosHistoryTab extends ConsumerStatefulWidget {
  const _PosHistoryTab();

  @override
  ConsumerState<_PosHistoryTab> createState() => _PosHistoryTabState();
}

class _PosHistoryTabState extends ConsumerState<_PosHistoryTab> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  int _revision = 0;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _openReturnForInvoice(Tx tx, Account? account) async {
    final returned = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.88,
        child: _SalesReturnSheet(tx: tx, account: account),
      ),
    );
    if (returned == true && mounted) {
      setState(() => _revision++);
    }
  }

  @override
  Widget build(BuildContext context) {
    // مراقبة التغييرات العامة لتحديث قائمة الفواتير تلقائياً بعد أي بيع أو مرتجع
    ref.watch(txPageProvider);
    final allAccounts =
        ref.watch(allAccountsProvider).valueOrNull ?? const <Account>[];
    final accountById = <int, Account>{
      for (final a in allAccounts)
        if (a.id != null) a.id!: a,
    };

    return Column(
      children: [
        // شريط البحث برقم الفاتورة أو اسم العميل لعمل مرتجع سريع
        Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          decoration: BoxDecoration(
            color: AppColors.surfaceOf(context),
            border: Border(
              bottom: BorderSide(color: AppColors.borderOf(context)),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.assignment_return_rounded,
                    color: Color(0xFF0F3E78),
                    size: 20,
                  ),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'البحث عن فاتورة لإرجاع صنف أو إرجاع الفاتورة بالكامل',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _searchCtrl,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF1E293B)
                      : const Color(0xFFF3F6FB),
                  hintText: 'ادخل رقم الفاتورة (مثال: 105) أو اسم العميل...',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: AppColors.borderOf(context)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: AppColors.borderOf(context)),
                  ),
                ),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ],
          ),
        ),

        // نتائج فواتير المبيعات
        Expanded(
          child: FutureBuilder<List<Tx>>(
            key: ValueKey('sales_inv_${_query}_$_revision'),
            future: ref.read(repoProvider).searchSalesInvoices(query: _query),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting &&
                  !snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return EmptyState(
                  icon: Icons.error_outline,
                  title: 'تعذّر تحميل سجل الفواتير',
                  message: '${snap.error}',
                );
              }
              final posTxs = snap.data ?? const <Tx>[];
              if (posTxs.isEmpty) {
                return EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: _query.isEmpty
                      ? 'لا توجد فواتير مبيعات مسجلة'
                      : 'لا توجد فاتورة مطابقة للرقم أو الاسم «$_query»',
                  message: _query.isEmpty
                      ? 'قم بإجراء عمليات بيع من نقطة البيع وستظهر هنا مع إمكانية عمل مرتجع.'
                      : 'تأكد من رقم الفاتورة أو امسح نص البحث لعرض جميع الفواتير.',
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: posTxs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final tx = posTxs[i];
                  final account =
                      tx.accountId != null ? accountById[tx.accountId!] : null;
                  final isCash = tx.type == OpType.revenue;
                  final isPartial =
                      !isCash && tx.notes.contains('طريقة الدفع: جزئي');
                  final hasReturnNote = tx.notes.contains('تم إرجاع (');
                  final customerName = account?.name.trim().isNotEmpty == true
                      ? account!.name
                      : (isCash ? 'عميل نقدي' : 'عميل مسجل');
                  final customerPhone = account?.phone.trim().isNotEmpty == true
                      ? ' • ${account!.phone}'
                      : '';
                  final badgeText = isCash
                      ? 'مدفوع نقداً'
                      : (isPartial ? 'جزئي (عليه)' : 'آجل (عليه)');
                  final badgeColor = isCash
                      ? AppColors.greenOf(context)
                      : (isPartial
                          ? Colors.deepOrange
                          : AppColors.dangerOf(context));
                  final invNumber = tx.reference.trim().isNotEmpty
                      ? tx.reference.trim()
                      : '${tx.id ?? ''}';

                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => showTxDetails(
                              context,
                              ref,
                              tx: tx,
                              account: account,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 19,
                                  backgroundColor:
                                      badgeColor.withValues(alpha: 0.14),
                                  child: Icon(
                                    isCash
                                        ? Icons.payments_outlined
                                        : (isPartial
                                            ? Icons.pie_chart_outline
                                            : Icons.receipt_long_outlined),
                                    color: badgeColor,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              invNumber.isNotEmpty
                                                  ? 'فاتورة #$invNumber'
                                                  : tx.description,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w900,
                                                fontSize: 14.5,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: badgeColor.withValues(
                                                  alpha: 0.12),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              border: Border.all(
                                                color: badgeColor.withValues(
                                                    alpha: 0.35),
                                              ),
                                            ),
                                            child: Text(
                                              badgeText,
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w800,
                                                color: badgeColor,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '$customerName$customerPhone • ${Fmt.date(tx.date)}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.text2Of(context),
                                        ),
                                      ),
                                      if (hasReturnNote)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 3),
                                          child: Text(
                                            tx.notes
                                                .split('\n')
                                                .where((l) =>
                                                    l.contains('تم إرجاع ('))
                                                .join('\n'),
                                            style: const TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w800,
                                              color: Color(0xFFD97706),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${Fmt.money(tx.amount)} ${tx.currency}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 14,
                                    color: AppColors.primaryOf(context),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () => showTxDetails(
                                  context,
                                  ref,
                                  tx: tx,
                                  account: account,
                                ),
                                icon: const Icon(
                                    Icons.visibility_outlined, size: 16),
                                label: const Text(
                                  'التفاصيل',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              const SizedBox(width: 4),
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () async {
                                  if (TxShare.isAutoShareConfigured(account)) {
                                    await TxShare.sendNow(
                                      context,
                                      ref,
                                      tx: tx,
                                      account: account,
                                    );
                                  } else {
                                    await TxShare.shareViaSystemSheet(
                                      context,
                                      ref,
                                      tx: tx,
                                      account: account,
                                    );
                                  }
                                },
                                icon:
                                    const Icon(Icons.share_outlined, size: 16),
                                label: const Text(
                                  'مشاركة',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              const SizedBox(width: 6),
                              FilledButton.tonalIcon(
                                style: FilledButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  backgroundColor: const Color(0xFFD97706)
                                      .withValues(alpha: 0.15),
                                  foregroundColor: const Color(0xFFB45309),
                                ),
                                onPressed: () =>
                                    _openReturnForInvoice(tx, account),
                                icon: const Icon(
                                  Icons.assignment_return_rounded,
                                  size: 17,
                                ),
                                label: const Text(
                                  'إرجاع صنف / الفاتورة',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ReturnLineState {
  final InvoiceLine originalLine;
  final double previouslyReturned;
  double returnQty;

  _ReturnLineState({
    required this.originalLine,
    required this.previouslyReturned,
    required this.returnQty,
  });

  double get maxReturnable {
    final rem = originalLine.quantity - previouslyReturned;
    return rem > 0 ? rem : 0;
  }

  double get unitNetPrice => originalLine.quantity > 0
      ? originalLine.total / originalLine.quantity
      : originalLine.unitPrice;

  double get returnSubtotal => returnQty * unitNetPrice;
}

/// نافذة إرجاع الفاتورة (إرجاع صنف محدد أو إرجاع الفاتورة بالكامل مع إعادة الكميات للمبيعات).
class _SalesReturnSheet extends ConsumerStatefulWidget {
  final Tx tx;
  final Account? account;

  const _SalesReturnSheet({required this.tx, required this.account});

  @override
  ConsumerState<_SalesReturnSheet> createState() => _SalesReturnSheetState();
}

class _SalesReturnSheetState extends ConsumerState<_SalesReturnSheet> {
  final List<_ReturnLineState> _lines = [];
  final TextEditingController _reasonCtrl = TextEditingController();
  bool _loading = true;
  bool _submitting = false;
  late bool _refundCash;

  @override
  void initState() {
    super.initState();
    _refundCash = widget.tx.accountId == null ||
        widget.tx.type == OpType.revenue;
    _loadInvoiceItems();
  }

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadInvoiceItems() async {
    try {
      final repo = ref.read(repoProvider);
      final id = widget.tx.id!;
      final items = await repo.transactionItems(id);
      final prevMap = await repo.returnedQuantitiesForInvoice(id);
      if (!mounted) return;
      setState(() {
        _lines.clear();
        if (items.isEmpty) {
          // في حال كانت الفاتورة مسجلة بدون تفصيل أسطر، ننشئ سطراً يمثل إجمالي الفاتورة
          final key = 'name:${widget.tx.description.trim().toLowerCase()}';
          final prev = prevMap[key] ?? 0;
          _lines.add(
            _ReturnLineState(
              originalLine: InvoiceLine(
                name: widget.tx.description.isNotEmpty
                    ? widget.tx.description
                    : 'كامل الفاتورة',
                quantity: 1,
                unitPrice: widget.tx.amount,
              ),
              previouslyReturned: prev,
              returnQty: prev < 1 ? 1 - prev : 0,
            ),
          );
        } else {
          for (final l in items) {
            final key = l.itemId != null
                ? 'id:${l.itemId}'
                : 'name:${l.name.trim().toLowerCase()}';
            final prev = prevMap[key] ?? 0;
            final rem = (l.quantity - prev) > 0 ? (l.quantity - prev) : 0.0;
            _lines.add(
              _ReturnLineState(
                originalLine: l,
                previouslyReturned: prev,
                returnQty: rem, // افتراضياً محدد للإرجاع السريع مع إمكانية التعديل
              ),
            );
          }
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showSnack(context, 'تعذر قراءة أصناف الفاتورة: $e', error: true);
    }
  }

  double get _totalReturnAmount =>
      _lines.fold<double>(0, (s, l) => s + l.returnSubtotal);

  bool get _hasReturnableItems =>
      _lines.any((l) => l.maxReturnable > 0);

  Future<void> _submitReturn() async {
    final chosen = _lines
        .where((l) => l.returnQty > 0 && l.returnQty <= l.maxReturnable + 1e-6)
        .map(
          (l) => InvoiceLine(
            itemId: l.originalLine.itemId,
            name: l.originalLine.name,
            unit: l.originalLine.unit,
            quantity: l.returnQty,
            unitPrice: l.unitNetPrice,
          ),
        )
        .toList();

    if (chosen.isEmpty) {
      showSnack(
        context,
        'يرجى تحديد كمية أكبر من صفر لصنف واحد على الأقل لإتمام المرتجع.',
        error: true,
      );
      return;
    }

    setState(() => _submitting = true);
    try {
      final repo = ref.read(repoProvider);
      await repo.processSalesReturn(
        originalTx: widget.tx,
        returnLines: chosen,
        refundCash: _refundCash,
        reason: _reasonCtrl.text.trim(),
      );

      // تحديث فوري للمخزون وشاشة المبيعات وكافة المزودات المالية
      ref.invalidate(itemsProvider);
      ref.invalidate(inventorySummaryProvider);
      ref.invalidate(txPageProvider);
      ref.invalidate(allAccountsProvider);
      ref.invalidate(summaryProvider);
      bump(ref);

      if (!mounted) return;
      Navigator.pop(context, true);
      showSnack(
        context,
        '✅ تم تسجيل المرتجع بنجاح وإعادة الأصناف المرتجعة إلى شاشة المبيعات والمخزون',
      );
    } catch (e) {
      if (!mounted) return;
      showSnack(context, 'تعذر تنفيذ المرتجع: $e', error: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final invRef = widget.tx.reference.trim().isNotEmpty
        ? widget.tx.reference.trim()
        : '${widget.tx.id ?? ''}';

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 4,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ترويسة نافذة المرتجع
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFD97706).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.assignment_return_rounded,
                  color: Color(0xFFD97706),
                  size: 22,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'مرتجع مبيعات — فاتورة #$invRef',
                      style: const TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      'الأصناف المرتجعة تعود تلقائياً إلى رصيد المبيعات والمخزون',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.text2Of(context),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context, false),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: 10),

          if (_loading)
            const Expanded(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (!_hasReturnableItems)
            const Expanded(
              child: EmptyState(
                icon: Icons.check_circle_outline_rounded,
                title: 'تم إرجاع هذه الفاتورة بالكامل مسبقاً',
                message: 'لا توجد كميات متبقية قابلة للإرجاع في هذه الفاتورة.',
              ),
            )
          else ...[
            // أزرار سريعة: إرجاع الفاتورة بالكامل / تصفير التحديد
            Row(
              children: [
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    setState(() {
                      for (final l in _lines) {
                        l.returnQty = l.maxReturnable;
                      }
                    });
                  },
                  icon: const Icon(Icons.select_all_rounded, size: 17),
                  label: const Text(
                    'إرجاع الفاتورة بالكامل',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    setState(() {
                      for (final l in _lines) {
                        l.returnQty = 0;
                      }
                    });
                  },
                  icon: const Icon(Icons.deselect_outlined, size: 17),
                  label: const Text(
                    'تصفير الكميات',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // قائمة أصناف الفاتورة
            Expanded(
              child: ListView.separated(
                itemCount: _lines.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final l = _lines[i];
                  final maxQ = l.maxReturnable;
                  final active = l.returnQty > 0;
                  return Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: active
                          ? AppColors.surfaceOf(context)
                          : AppColors.surfaceOf(context).withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: active
                            ? const Color(0xFFD97706).withValues(alpha: 0.5)
                            : AppColors.borderOf(context),
                      ),
                    ),
                    child: Row(
                      children: [
                        Checkbox(
                          value: active,
                          visualDensity: VisualDensity.compact,
                          onChanged: maxQ <= 0
                              ? null
                              : (v) {
                                  setState(() {
                                    l.returnQty =
                                        (v ?? false) ? maxQ : 0;
                                  });
                                },
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l.originalLine.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'المباع: ${Fmt.qty(l.originalLine.quantity)} ${l.originalLine.unit}'
                                '${l.previouslyReturned > 0 ? ' • مرتجع سابق: ${Fmt.qty(l.previouslyReturned)}' : ''}'
                                ' • سعر الوحدة: ${Fmt.money(l.unitNetPrice)} ${widget.tx.currency}',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: AppColors.text2Of(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (maxQ <= 0)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              'مرتجع بالكامل',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          )
                        else
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                iconSize: 20,
                                icon: const Icon(Icons.remove_circle_outline),
                                onPressed: l.returnQty > 0
                                    ? () {
                                        setState(() {
                                          l.returnQty = (l.returnQty - 1)
                                              .clamp(0.0, maxQ);
                                        });
                                      }
                                    : null,
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFD97706)
                                      .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  Fmt.qty(l.returnQty),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 13.5,
                                  ),
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                iconSize: 20,
                                icon: const Icon(Icons.add_circle_outline),
                                onPressed: l.returnQty < maxQ
                                    ? () {
                                        setState(() {
                                          l.returnQty = (l.returnQty + 1)
                                              .clamp(0.0, maxQ);
                                        });
                                      }
                                    : null,
                              ),
                            ],
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 8),
            // خيار طريقة التسوية المالية إذا كانت الفاتورة مرتبطة بحساب عميل
            if (widget.tx.accountId != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment<bool>(
                      value: false,
                      icon: Icon(Icons.account_balance_wallet_outlined, size: 17),
                      label: Text('خصم من حساب العميل (له)'),
                    ),
                    ButtonSegment<bool>(
                      value: true,
                      icon: Icon(Icons.payments_outlined, size: 17),
                      label: Text('استرداد نقدي'),
                    ),
                  ],
                  selected: <bool>{_refundCash},
                  onSelectionChanged: (s) =>
                      setState(() => _refundCash = s.first),
                ),
              ),

            TextField(
              controller: _reasonCtrl,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'سبب الإرجاع أو ملاحظة (اختياري)...',
                prefixIcon: const Icon(Icons.notes_rounded, size: 18),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 10),

            // ملخص المبلغ وزر التأكيد
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceOf(context),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.borderOf(context)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'إجمالي قيمة المرتجع',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppColors.text2Of(context),
                          ),
                        ),
                        Text(
                          '${Fmt.money(_totalReturnAmount)} ${widget.tx.currency}',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                            color: AppColors.dangerOf(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0F3E78),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                    ),
                    onPressed: _submitting ? null : _submitReturn,
                    icon: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.assignment_return_rounded, size: 19),
                    label: const Text(
                      'تأكيد المرتجع وإعادة الأصناف',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// نتيجة فحص حد الائتمان للعميل قبل تأكيد فاتورة آجلة.
class _CreditCheck {
  final double limit;
  final double currentDebt;
  final double remaining;
  final bool exceeded;
  const _CreditCheck({
    required this.limit,
    required this.currentDebt,
    required this.remaining,
    required this.exceeded,
  });
}

/// زرا «+00» و«+000» المدمجان في حقول المبالغ لتسريع الإدخال.
class _ZeroButtons extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onChanged;
  const _ZeroButtons({required this.controller, required this.onChanged});

  void _append(String zeros) {
    final raw = ThousandsFormatter.strip(controller.text);
    if (raw.isEmpty || raw == '0' || raw.contains('.')) return;
    controller.value = const ThousandsFormatter().formatEditUpdate(
      controller.value,
      TextEditingValue(text: '$raw$zeros'),
    );
    Sfx.click();
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(38, 32),
            padding: const EdgeInsets.symmetric(horizontal: 6),
          ),
          onPressed: () => _append('00'),
          child: const Text('+00',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
        ),
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(38, 32),
            padding: const EdgeInsets.symmetric(horizontal: 6),
          ),
          onPressed: () => _append('000'),
          child: const Text('+000',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }
}
