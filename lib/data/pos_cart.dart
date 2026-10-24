import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';

/// سطر في سلة نقطة البيع.
class CartEntry {
  final Item item;
  final double quantity;
  final double unitPrice;

  const CartEntry({
    required this.item,
    this.quantity = 1.0,
    required this.unitPrice,
  });

  double get total => quantity * unitPrice;

  CartEntry copyWith({Item? item, double? quantity, double? unitPrice}) =>
      CartEntry(
        item: item ?? this.item,
        quantity: quantity ?? this.quantity,
        unitPrice: unitPrice ?? this.unitPrice,
      );

  Map<String, dynamic> toJson() => {
        'item': item.toMap(),
        'quantity': quantity,
        'unitPrice': unitPrice,
      };

  factory CartEntry.fromJson(Map<String, dynamic> json) => CartEntry(
        item: Item.fromMap(Map<String, Object?>.from(json['item'] as Map)),
        quantity: (json['quantity'] as num?)?.toDouble() ?? 1.0,
        unitPrice: (json['unitPrice'] as num?)?.toDouble() ?? 0.0,
      );
}

/// حالة مسودة فاتورة نقطة البيع كاملة — تعيش في Riverpod لا في حالة
/// الشاشة، فالتنقل بعيداً عن تبويب POS (حتى بالخطأ) لا يُفقد السلة؛
/// تُصفَّر فقط عند إتمام البيع أو الإفراغ الصريح.
class PosDraft {
  final Map<int, CartEntry> cart;
  final int? customerId;
  final String payment; // cash | credit | partial
  final String paidText;
  final String discountText;
  final bool discountIsPercent;
  final String notesText;
  final String? holdLabel;
  final DateTime? heldAt;
  final String? holdId;

  const PosDraft({
    this.cart = const {},
    this.customerId,
    this.payment = 'cash',
    this.paidText = '',
    this.discountText = '',
    this.discountIsPercent = false,
    this.notesText = '',
    this.holdLabel,
    this.heldAt,
    this.holdId,
  });

  static const _sentinel = Object();

  PosDraft copyWith({
    Map<int, CartEntry>? cart,
    Object? customerId = _sentinel,
    String? payment,
    String? paidText,
    String? discountText,
    bool? discountIsPercent,
    String? notesText,
    String? holdLabel,
    DateTime? heldAt,
    String? holdId,
  }) =>
      PosDraft(
        cart: cart ?? this.cart,
        customerId: identical(customerId, _sentinel)
            ? this.customerId
            : customerId as int?,
        payment: payment ?? this.payment,
        paidText: paidText ?? this.paidText,
        discountText: discountText ?? this.discountText,
        discountIsPercent: discountIsPercent ?? this.discountIsPercent,
        notesText: notesText ?? this.notesText,
        holdLabel: holdLabel ?? this.holdLabel,
        heldAt: heldAt ?? this.heldAt,
        holdId: holdId ?? this.holdId,
      );

  Map<String, dynamic> toJson() => {
        'cart': cart.map((k, v) => MapEntry(k.toString(), v.toJson())),
        'customerId': customerId,
        'payment': payment,
        'paidText': paidText,
        'discountText': discountText,
        'discountIsPercent': discountIsPercent,
        'notesText': notesText,
        'holdLabel': holdLabel,
        'heldAt': heldAt?.toIso8601String(),
        'holdId': holdId,
      };

  factory PosDraft.fromJson(Map<String, dynamic> json) {
    final rawCart = json['cart'] as Map<String, dynamic>? ?? {};
    final cart = <int, CartEntry>{};
    rawCart.forEach((k, v) {
      final id = int.tryParse(k);
      if (id != null && v is Map) {
        cart[id] = CartEntry.fromJson(Map<String, dynamic>.from(v));
      }
    });
    return PosDraft(
      cart: cart,
      customerId: json['customerId'] as int?,
      payment: json['payment'] as String? ?? 'cash',
      paidText: json['paidText'] as String? ?? '',
      discountText: json['discountText'] as String? ?? '',
      discountIsPercent: json['discountIsPercent'] as bool? ?? false,
      notesText: json['notesText'] as String? ?? '',
      holdLabel: json['holdLabel'] as String?,
      heldAt: json['heldAt'] != null
          ? DateTime.tryParse(json['heldAt'] as String)
          : null,
      holdId: json['holdId'] as String?,
    );
  }

  double get subtotal =>
      cart.values.fold<double>(0.0, (sum, e) => sum + e.total);

  /// قيمة الخصم الفعلية وفق النمط: نسبة مئوية من المجموع أو مبلغ مقطوع.
  double get discountValue {
    final raw =
        double.tryParse(discountText.replaceAll(',', '').trim()) ?? 0.0;
    if (raw <= 0) return 0.0;
    if (discountIsPercent) {
      final pct = raw.clamp(0.0, 100.0);
      final disc = subtotal * pct / 100.0;
      return (disc * 100).roundToDouble() / 100.0;
    }
    final disc = raw.clamp(0.0, subtotal);
    return (disc * 100).roundToDouble() / 100.0;
  }

  double get netTotal {
    final net = (subtotal - discountValue).clamp(0.0, double.infinity);
    return (net * 100).roundToDouble() / 100.0;
  }

  int get itemCount => cart.values.fold<int>(
        0,
        (sum, e) => sum + (e.quantity > 0 && e.quantity < 1 ? 1 : e.quantity.round()),
      );
}

class PosDraftNotifier extends StateNotifier<PosDraft> {
  final Ref? _ref;
  List<PosDraft> _heldDrafts = [];

  PosDraftNotifier([this._ref]) : super(const PosDraft()) {
    _loadHeldFromStorage();
  }

  static const String _kHeldDraftsPrefsKey = 'pos_held_invoices_v1';

  Future<void> _loadHeldFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kHeldDraftsPrefsKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final list = jsonDecode(raw) as List;
        _heldDrafts = list
            .whereType<Map>()
            .map((m) => PosDraft.fromJson(Map<String, dynamic>.from(m)))
            .toList();
        _syncHeldState(saveToPrefs: false);
      }
    } catch (_) {
      // Ignored in unit tests or non-shared_preferences environments
    }
  }

  Future<void> _saveHeldToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_heldDrafts.isEmpty) {
        await prefs.remove(_kHeldDraftsPrefsKey);
      } else {
        final list = _heldDrafts.map((d) => d.toJson()).toList();
        await prefs.setString(_kHeldDraftsPrefsKey, jsonEncode(list));
      }
    } catch (_) {
      // Ignored in unit tests or non-shared_preferences environments
    }
  }

  void _syncHeldState({bool saveToPrefs = true}) {
    if (saveToPrefs) {
      _saveHeldToStorage();
    }
    if (_ref != null) {
      _ref.read(heldInvoicesProvider.notifier).state =
          List.unmodifiable(_heldDrafts);
    }
  }

  /// إضافة صنف (أو زيادة كميته). يعيد false إذا مُنع لنفاد الرصيد.
  /// يضيف الصنف إلى السلة.
  ///
  /// (2026-09-24) [quantity] يسمح بإضافة دفعة واحدة **بشكل ذرّي** — مطلوب
  /// لنظام الترقيم السريع (`7*3` + Enter يضيف ثلاث قطع): التحقق من الرصيد
  /// يتم مرة واحدة على الكمية كاملة، فلا تُضاف قطعتان ثم تفشل الثالثة.
  bool addItem(Item item, {required bool allowNegative, double quantity = 1}) {
    final id = item.id;
    final qty = quantity <= 0 ? 1.0 : quantity;
    if (id == null) return false;
    final inCart = state.cart[id]?.quantity ?? 0.0;
    if (!allowNegative && inCart + qty > item.quantity) return false;
    final next = Map<int, CartEntry>.from(state.cart);
    next[id] = (next[id] ??
            CartEntry(
              item: item,
              quantity: 0,
              unitPrice:
                  item.sellPrice > 0 ? item.sellPrice : item.buyPrice,
            ))
        .copyWith(quantity: inCart + qty);
    state = state.copyWith(cart: next);
    return true;
  }

  /// تحديد كمية سطر مباشرة (إدخال رقمي سريع). يعيد false إن رُفضت.
  bool setQuantity(int itemId, double qty, {required bool allowNegative}) {
    final entry = state.cart[itemId];
    if (entry == null) return false;
    if (qty <= 0) {
      removeItem(itemId);
      return true;
    }
    if (!allowNegative && qty > entry.item.quantity) return false;
    final next = Map<int, CartEntry>.from(state.cart);
    next[itemId] = entry.copyWith(quantity: qty);
    state = state.copyWith(cart: next);
    return true;
  }

  void setUnitPrice(int itemId, double price) {
    final entry = state.cart[itemId];
    if (entry == null || price <= 0) return;
    final next = Map<int, CartEntry>.from(state.cart);
    next[itemId] = entry.copyWith(unitPrice: price);
    state = state.copyWith(cart: next);
  }

  void removeItem(int itemId) {
    final next = Map<int, CartEntry>.from(state.cart)..remove(itemId);
    state = state.copyWith(cart: next);
  }

  void setCustomer(int? id) => state = state.copyWith(customerId: id);
  void setPayment(String p) => state = state.copyWith(payment: p);
  void setPaid(String t) => state = state.copyWith(paidText: t);
  void setDiscount(String t) => state = state.copyWith(discountText: t);
  void setDiscountIsPercent(bool v) =>
      state = state.copyWith(discountIsPercent: v);
  void setNotes(String t) => state = state.copyWith(notesText: t);

  void clear() => state = const PosDraft();

  /// استعادة مسودة كاملة (استئناف فاتورة معلّقة — F12 على سطح المكتب).
  void restore(PosDraft d) => state = d;

  /// تعليق السلة الحالية وحفظها في قائمة المسودات المعلقة، وتصفير السلة الحالية.
  PosDraft? holdCurrentDraft({String? label}) {
    if (state.cart.isEmpty) return null;
    final now = DateTime.now();
    final customLabel = label?.trim();
    final assignedLabel = (customLabel != null && customLabel.isNotEmpty)
        ? customLabel
        : 'فاتورة #${_heldDrafts.length + 1}';
    final held = state.copyWith(
      holdLabel: assignedLabel,
      heldAt: now,
      holdId: '${now.millisecondsSinceEpoch}',
    );
    _heldDrafts.add(held);
    _syncHeldState();
    clear();
    return held;
  }

  /// يعيد قائمة الفواتير المعلقة.
  List<PosDraft> getHeldDrafts() {
    if (_heldDrafts.isEmpty && _ref != null) {
      final ext = _ref.read(heldInvoicesProvider);
      if (ext.isNotEmpty) return ext;
    }
    return List.unmodifiable(_heldDrafts);
  }

  /// يستعيد فاتورة معلقة إلى السلة النشطة ويحذفها من قائمة المعلقات.
  PosDraft? resumeDraft(int index) {
    if (_heldDrafts.isEmpty && _ref != null) {
      final ext = _ref.read(heldInvoicesProvider);
      if (ext.isNotEmpty) _heldDrafts = List.of(ext);
    }
    if (index < 0 || index >= _heldDrafts.length) return null;
    final draft = _heldDrafts.removeAt(index);
    _syncHeldState();
    restore(draft);
    return draft;
  }

  /// يحذف فاتورة معلقة نهائياً.
  PosDraft? discardDraft(int index) {
    if (_heldDrafts.isEmpty && _ref != null) {
      final ext = _ref.read(heldInvoicesProvider);
      if (ext.isNotEmpty) _heldDrafts = List.of(ext);
    }
    if (index < 0 || index >= _heldDrafts.length) return null;
    final draft = _heldDrafts.removeAt(index);
    _syncHeldState();
    return draft;
  }

  /// مزامنة المسودات يدوياً إن تم تعديل heldInvoicesProvider من الخارج.
  void syncHeldDrafts(List<PosDraft> drafts) {
    _heldDrafts = List.of(drafts);
    _syncHeldState();
  }
}

/// فواتير معلّقة (تعليق/استئناف — F12): الأحدث آخر القائمة.
final heldInvoicesProvider =
    StateProvider<List<PosDraft>>((ref) => const []);

/// مسودة نقطة البيع الحية — تبقى عبر التنقل بين التبويبات.
final posDraftProvider =
    StateNotifierProvider<PosDraftNotifier, PosDraft>(
        (ref) => PosDraftNotifier(ref));
