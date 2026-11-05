import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/models.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/repository.dart';

class GeminiChatTurn {
  final String id;
  final String role; // 'user' | 'model'
  final String text;
  final String timestamp;
  final String? modelUsed;

  const GeminiChatTurn({
    required this.id,
    required this.role,
    required this.text,
    required this.timestamp,
    this.modelUsed,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'text': text,
        'timestamp': timestamp,
        if (modelUsed != null) 'modelUsed': modelUsed,
      };

  factory GeminiChatTurn.fromJson(Map<String, dynamic> m) => GeminiChatTurn(
        id: '${m['id'] ?? ''}',
        role: '${m['role'] ?? 'model'}',
        text: '${m['text'] ?? ''}',
        timestamp: '${m['timestamp'] ?? ''}',
        modelUsed: m['modelUsed']?.toString(),
      );
}

Future<void> openGeminiAssistantSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  Sfx.tap();
  final repo = ref.read(repoProvider);
  final isOwner = await repo.isWorkspaceOwner();
  final current = await repo.currentUser();
  final isAdmin = isOwner || (current != null && current.role == UserRole.admin);
  if (!isAdmin) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('المساعد المالي الذكي متاح لمدير المنشأة فقط حفاظاً على سرية البيانات المالية.'),
        ),
      );
    }
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _GeminiAssistantSheet(),
  );
}

class _GeminiAssistantSheet extends ConsumerStatefulWidget {
  const _GeminiAssistantSheet();

  @override
  ConsumerState<_GeminiAssistantSheet> createState() =>
      _GeminiAssistantSheetState();
}

class _GeminiAssistantSheetState extends ConsumerState<_GeminiAssistantSheet> {
  static const _historyKey = 'gemini.chat.history.v1';
  static const _roleKey = 'gemini.chat.role.v1';
  static const _modelKey = 'gemini.chat.model.v1';
  static const _customPromptKey = 'gemini.chat.customPrompt.v1';
  static const _consentKey = 'gemini.chat.dataConsent.v1';
  static const _endpointKey = 'gemini.chat.endpoint.v1';

  final TextEditingController _inputCtl = TextEditingController();
  final TextEditingController _customPromptCtl = TextEditingController();
  final ScrollController _scrollCtl = ScrollController();

  String _selectedRole = 'accountant';

  /// (دفعة الواجهات) الافتراضي يُشتق من خريطة النماذج الحقيقية نفسها —
  /// كان مثبتاً على معرّف وهمي (`gemini-3.8-flash`) لا وجود له في `_models`
  /// ولا عند المزوّد، فيُرسَل في كل طلب أول تشغيل ويفشل بلا أي مؤشر واجهة.
  String _selectedModel = _models.keys.first;
  bool _showConfig = false;
  bool _sending = false;
  List<GeminiChatTurn> _messages = [];

  static const _roles = <String, ({String label, String desc, IconData icon, String prompt})>{
    'accountant': (
      label: 'المحاسب المالي الذكي',
      desc: 'تحليل المبيعات والديون والأرصدة والقيود المحاسبية',
      icon: Icons.calculate_rounded,
      prompt:
          'أنت «روبوت المحاسب الذكي» في تطبيق «المحاسب». دورك هو محاسب مالي قانوني وخبير في إدارة المبيعات والديون والقيود المحاسبية وسندات القبض والصرف. قدّم إجابات دقيقة ومنظمة باللغة العربية مع أرقام واضحة.',
    ),
    'collector': (
      label: 'مستشار تحصيل الديون',
      desc: 'صياغة رسائل مطالبة وجدولة مديونيات العملاء باحترافية',
      icon: Icons.mark_chat_unread_rounded,
      prompt:
          'أنت «مستشار تحصيل الديون الذكي» في تطبيق «المحاسب». دورك هو مساعدة المدير في متابعة ديون العملاء، جدولة السداد، وصياغة رسائل مطالبة وتذكير احترافية ولَبِقة عبر واتساب.',
    ),
    'inventory': (
      label: 'خبير المخزون والمشتريات',
      desc: 'تحليل النواقص وحركة الأصناف وهوامش الربح',
      icon: Icons.inventory_2_rounded,
      prompt:
          'أنت «خبير المخزون والمشتريات الذكي» في تطبيق «المحاسب». دورك هو تحليل حركة الأصناف، تنبيه المدير للأصناف التي أوشكت على النفاد، واقتراح كميات إعادة الطلب.',
    ),
  };

  // (دفعة التدقيق) أسماء النماذج الحقيقية المتاحة فعلياً من Gemini —
  // كانت المعرفات السابقة وهمية لا تطابق أي إصدار منشور فتفشل الطلبات
  // أو تُخدَم بنموذج احتياطي غير مقصود.
  static const _models = <String, ({String label, String sub, IconData icon})>{
    'gemini-2.5-flash': (
      label: 'متوازن (Flash)',
      sub: 'للمهام العامة',
      icon: Icons.auto_awesome_rounded,
    ),
    'gemini-2.5-flash-lite': (
      label: 'سريع (Lite)',
      sub: 'ردود فورية',
      icon: Icons.bolt_rounded,
    ),
    'gemini-2.5-pro': (
      label: 'معمّق (Pro)',
      sub: 'للتحليل المعقّد',
      icon: Icons.psychology_rounded,
    ),
  };

  static const _quickPrompts = <String>[
    'لخّص الوضع المالي للمنشأة وأهم المؤشرات اليوم',
    'من هم أعلى العملاء مديونية وكيف نجدول تحصيلهم؟',
    'اكتب رسالة واتساب لبقة لتذكير عميل بسداد فاتورته المستحقة',
    'ما هي الأصناف التي أوشكت على النفاد في المخزون؟',
  ];

  @override
  void initState() {
    super.initState();
    _loadSavedChat();
  }

  @override
  void dispose() {
    _inputCtl.dispose();
    _customPromptCtl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  String _nowTime() {
    final n = DateTime.now();
    final h = n.hour.toString().padLeft(2, '0');
    final m = n.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  GeminiChatTurn _welcomeTurn() => GeminiChatTurn(
        id: 'welcome-1',
        role: 'model',
        text:
            'مرحباً بك في روبوت المحاسب الذكي (Gemini)! 🤖📊\n\nيمكنني قراءة وتحليل مؤشرات حساباتك، ديون العملاء، نواقص المخزون، أو صياغة رسائل تحصيل احترافية. كيف يمكنني مساعدتك اليوم؟',
        timestamp: _nowTime(),
        modelUsed: _selectedModel,
      );

  Future<void> _loadSavedChat() async {
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final role = (st[_roleKey] ?? '').trim();
      final model = (st[_modelKey] ?? '').trim();
      final customPrompt = (st[_customPromptKey] ?? '').trim();
      final rawHistory = (st[_historyKey] ?? '').trim();

      final loaded = <GeminiChatTurn>[];
      if (rawHistory.isNotEmpty) {
        final decoded = jsonDecode(rawHistory);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              loaded.add(
                GeminiChatTurn.fromJson(Map<String, dynamic>.from(item)),
              );
            }
          }
        }
      }

      if (!mounted) return;
      setState(() {
        if (_roles.containsKey(role)) _selectedRole = role;
        if (_models.containsKey(model)) _selectedModel = model;
        _customPromptCtl.text = customPrompt;
        _messages = loaded.isNotEmpty ? loaded : [_welcomeTurn()];
      });
      _scrollToBottom();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _messages = [_welcomeTurn()];
      });
    }
  }

  Future<void> _saveState() async {
    try {
      final repo = ref.read(repoProvider);
      final trimmed = _messages.length > 35
          ? _messages.sublist(_messages.length - 35)
          : _messages;
      await repo.setSetting(
        _historyKey,
        jsonEncode(trimmed.map((e) => e.toJson()).toList()),
      );
      await repo.setSetting(_roleKey, _selectedRole);
      await repo.setSetting(_modelKey, _selectedModel);
      await repo.setSetting(_customPromptKey, _customPromptCtl.text.trim());
    } catch (_) {}
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtl.hasClients) {
        _scrollCtl.animateTo(
          _scrollCtl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<String> _buildLocalFinancialContext(Repo repo) async {
    try {
      final accounts = await repo.accounts();
      final db = await repo.database;
      final accCount = accounts.length;

      // (دفعة التدقيق) الأرصدة من دوال المستودع المعتمدة (allBalances:
      // الافتتاحي + كل التأثيرات بما فيها القبض/الصرف والتحويلات بسعرها)
      // مجمّعة لكل عملة على حدة — كان السياق يجمع مبالغ debit/credit
      // خاماً عبر كل العملات معاً فتختلط العملات وتُهمل عمليات القبض
      // والصرف كلياً.
      final balances = await repo.allBalances(accounts);
      final receivableByCur = <String, double>{};
      final payableByCur = <String, double>{};
      final debtors = <({String name, String cur, double bal})>[];
      for (final a in accounts) {
        final bal = balances[a.id] ?? 0.0;
        final cur = a.currency.trim().toUpperCase();
        if (bal > 0) {
          receivableByCur[cur] = (receivableByCur[cur] ?? 0) + bal;
          debtors.add((name: a.name, cur: cur, bal: bal));
        } else if (bal < 0) {
          payableByCur[cur] = (payableByCur[cur] ?? 0) + bal.abs();
        }
      }
      debtors.sort((a, b) => b.bal.compareTo(a.bal));

      final lowStock = await db.rawQuery('''
        SELECT name, quantity, min_quantity
        FROM items
        WHERE COALESCE(is_deleted, 0) = 0 AND COALESCE(deleted_at,'') = ''
          AND quantity <= COALESCE(min_quantity, 5)
        ORDER BY quantity ASC
        LIMIT 8
      ''');

      final lowStockStr = lowStock.isEmpty
          ? 'لا توجد نواقص حرجة في المخزون'
          : lowStock
              .map((r) => '${r['name']} (المتبقي: ${r['quantity']})')
              .join('، ');

      final lines = <String>['عدد الحسابات النشطة: $accCount'];
      final allCurs = <String>{...receivableByCur.keys, ...payableByCur.keys}
          .toList()
        ..sort();
      for (final cur in allCurs) {
        final r = receivableByCur[cur] ?? 0;
        final p = payableByCur[cur] ?? 0;
        lines.add('[$cur] المدين (لنا): ${r.toStringAsFixed(0)} • '
            'الدائن (علينا): ${p.toStringAsFixed(0)} • '
            'الصافي: ${(r - p).toStringAsFixed(0)}');
      }
      lines.add(
        debtors.isEmpty
            ? 'لا توجد مديونيات مرتفعة حالياً'
            : 'أعلى الحسابات المدينة: ${debtors.take(6).map((d) => '${d.name} (${d.bal.toStringAsFixed(0)} ${d.cur})').join('، ')}',
      );
      lines.add('أصناف أوشكت على النفاد: $lowStockStr');
      return lines.join('\n');
    } catch (_) {
      return 'بيانات المنشأة المحلية جاهزة.';
    }
  }

  String _generateOfflineFallbackReply(String prompt, String summary) {
    final p = prompt.toLowerCase();
    if (p.contains('واتساب') || p.contains('رسالة') || p.contains('تذكير')) {
      return 'إليك صياغة رسالة تذكير احترافية ولَبِقة لإرسالها عبر واتساب:\n\n'
          '«السلام عليكم ورحمة الله وبركاته،\n'
          'عميلنا العزيز، نود تذكيركم بلطف بالرصيد المستحق لحسابكم لدينا، شاكرين ومقدرين تعاملكم الدائم معنا. '
          'يرجى التكرم بجدولة السداد أو التواصل معنا في حال وجود أي استفسار.\n'
          'مع خالص التحية والتقدير — إدارة الحسابات»';
    }
    return '📊 **تحليل المحاسب الذكي لبيانات منشأتك الحالية:**\n\n$summary\n\n'
        '💡 **توصية محاسبية:**\n'
        '• ركّز على متابعة أعلى الحسابات المدينة بجدولة دفعات أسبوعية منتظمة.\n'
        '• راجع الأصناف التي أوشكت على النفاد لإعادة طلبها قبل توقف المبيعات.';
  }

  Future<void> _sendMessage([String? presetText]) async {
    final text = (presetText ?? _inputCtl.text).trim();
    if (text.isEmpty || _sending) return;

    Sfx.tap();
    final userTurn = GeminiChatTurn(
      id: 'u-${DateTime.now().millisecondsSinceEpoch}',
      role: 'user',
      text: text,
      timestamp: _nowTime(),
    );

    final priorHistory = _messages
        .where((m) => m.id != 'welcome-1')
        .map((m) => {'role': m.role, 'text': m.text})
        .toList();

    setState(() {
      _messages = [..._messages, userTurn];
      if (presetText == null) _inputCtl.clear();
      _sending = true;
    });
    _scrollToBottom();

    final repo = ref.read(repoProvider);
    final st = await repo.settings();
    bool hasConsent = (st[_consentKey] ?? '') == '1';
    final configuredEndpoint = (st[_endpointKey] ?? '').trim();

    if (!hasConsent && configuredEndpoint.isNotEmpty && mounted) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('موافقة مشاركة الملخص المالي'),
          content: const Text(
            'هل توافق على إرسال ملخص المؤشرات المالية (إجمالي الأرصدة، أعلى المدينين، ونواقص المخزون) إلى خدمة التحليل الذكي للإجابة على استفساراتك؟\n\nيمكنك الرفض والاكتفاء بالتحليل المحلي داخل جهازك.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تحليل محلي فقط'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('موافق'),
            ),
          ],
        ),
      );
      if (approved == true) {
        hasConsent = true;
        await repo.setSetting(_consentKey, '1');
      }
    }

    final summary = await _buildLocalFinancialContext(repo);

    String replyText = '';
    String usedModel = _selectedModel;

    if (hasConsent &&
        configuredEndpoint.startsWith('https://') &&
        !configuredEndpoint.contains('ais-pre-')) {
      try {
        final res = await http
            .post(
              Uri.parse(configuredEndpoint),
              headers: const {'Content-Type': 'application/json; charset=utf-8'},
              body: jsonEncode({
                'message': text,
                'history': priorHistory.length > 14
                    ? priorHistory.sublist(priorHistory.length - 14)
                    : priorHistory,
                'role': _selectedRole,
                'model': _selectedModel,
                'customSystemInstruction': _customPromptCtl.text.trim(),
                'clientContext': summary,
              }),
            )
            .timeout(const Duration(seconds: 25));

        if (res.statusCode >= 200 && res.statusCode < 300) {
          final decoded = jsonDecode(utf8.decode(res.bodyBytes));
          if (decoded is Map && '${decoded['reply'] ?? ''}'.trim().isNotEmpty) {
            replyText = '${decoded['reply']}'.trim();
            usedModel = '${decoded['modelUsed'] ?? _selectedModel}';
          }
        }
      } catch (_) {}
    }

    if (replyText.isEmpty) {
      replyText = _generateOfflineFallbackReply(text, summary);
    }

    if (!mounted) return;
    final botTurn = GeminiChatTurn(
      id: 'm-${DateTime.now().millisecondsSinceEpoch}',
      role: 'model',
      text: replyText,
      timestamp: _nowTime(),
      modelUsed: usedModel,
    );

    setState(() {
      _messages = [..._messages, botTurn];
      _sending = false;
    });
    await _saveState();
    _scrollToBottom();
  }

  Future<void> _clearChat() async {
    Sfx.click();
    setState(() {
      _messages = [_welcomeTurn()];
    });
    await _saveState();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final roleMeta = _roles[_selectedRole] ?? _roles['accountant']!;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        height: MediaQuery.sizeOf(context).height * 0.86,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(
            color: const Color(0xFFF59E0B).withValues(alpha: 0.4),
            width: 1.2,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF042F2E), Color(0xFF065F46)],
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                ),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: const Color(0xFFFCD34D),
                            width: 1.2,
                          ),
                        ),
                        child: const Icon(
                          Icons.smart_toy_rounded,
                          color: Color(0xFFFCD34D),
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'روبوت المحاسب الذكي (Gemini)',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              '${roleMeta.label} • ${_models[_selectedModel]?.label ?? ''}',
                              style: const TextStyle(
                                color: Color(0xFFA7F3D0),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'تخصيص الدور والنموذج',
                        onPressed: () =>
                            setState(() => _showConfig = !_showConfig),
                        icon: Icon(
                          _showConfig
                              ? Icons.expand_less_rounded
                              : Icons.tune_rounded,
                          color: const Color(0xFFFCD34D),
                        ),
                      ),
                      IconButton(
                        tooltip: 'مسح المحادثة',
                        onPressed: _clearChat,
                        icon: const Icon(
                          Icons.delete_sweep_rounded,
                          color: Colors.white70,
                        ),
                      ),
                      IconButton(
                        tooltip: 'إغلاق',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  if (_showConfig) ...[
                    const SizedBox(height: 10),
                    const Divider(color: Colors.white24, height: 1),
                    const SizedBox(height: 10),
                    const Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        'اختر دور الروبوت (System Instruction):',
                        style: TextStyle(
                          color: Color(0xFFA7F3D0),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _roles.entries.map((entry) {
                        final active = _selectedRole == entry.key;
                        return ChoiceChip(
                          selected: active,
                          label: Text(
                            entry.value.label,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: active
                                  ? const Color(0xFF042F2E)
                                  : Colors.white,
                            ),
                          ),
                          selectedColor: const Color(0xFFFCD34D),
                          backgroundColor: const Color(0xFF064E3B),
                          onSelected: (_) {
                            setState(() => _selectedRole = entry.key);
                            _saveState();
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 8),
                    const Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        'اختر نموذج Gemini حسب السرعة والتعقيد:',
                        style: TextStyle(
                          color: Color(0xFFA7F3D0),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _models.entries.map((entry) {
                        final active = _selectedModel == entry.key;
                        return ChoiceChip(
                          selected: active,
                          label: Text(
                            '${entry.value.label} (${entry.value.sub})',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: active
                                  ? const Color(0xFF042F2E)
                                  : Colors.white,
                            ),
                          ),
                          selectedColor: const Color(0xFF38BDF8),
                          backgroundColor: const Color(0xFF064E3B),
                          onSelected: (_) {
                            setState(() => _selectedModel = entry.key);
                            _saveState();
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),

            // Quick prompts bar
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                border: Border(
                  bottom: BorderSide(
                    color: isDark
                        ? const Color(0xFF334155)
                        : const Color(0xFFE2E8F0),
                  ),
                ),
              ),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _quickPrompts.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (ctx, i) => Center(
                  child: ActionChip(
                    label: Text(
                      _quickPrompts[i],
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onPressed: _sending ? null : () => _sendMessage(_quickPrompts[i]),
                  ),
                ),
              ),
            ),

            // Scrollable Message Thread
            Expanded(
              child: ListView.builder(
                controller: _scrollCtl,
                padding: const EdgeInsets.all(14),
                itemCount: _messages.length + (_sending ? 1 : 0),
                itemBuilder: (ctx, idx) {
                  if (idx == _messages.length) {
                    return Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF1E293B)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 10),
                            Text(
                              'جاري التحليل المحاسبي...',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  final msg = _messages[idx];
                  final isUser = msg.role == 'user';
                  return Align(
                    alignment: isUser
                        ? AlignmentDirectional.centerStart
                        : AlignmentDirectional.centerEnd,
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * 0.82,
                      ),
                      margin: const EdgeInsets.symmetric(vertical: 5),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: isUser
                            ? const Color(0xFF047857)
                            : (isDark
                                ? const Color(0xFF1E293B)
                                : Colors.white),
                        borderRadius: BorderRadius.circular(18),
                        border: isUser
                            ? null
                            : Border.all(
                                color: isDark
                                    ? const Color(0xFF334155)
                                    : const Color(0xFFE2E8F0),
                              ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.04),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(
                            msg.text,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.5,
                              color: isUser
                                  ? Colors.white
                                  : AppColors.textOf(context),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                isUser ? 'أنت • ${msg.timestamp}' : 'روبوت المحاسب • ${msg.timestamp}',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: isUser
                                      ? const Color(0xFFA7F3D0)
                                      : AppColors.text3Of(context),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            // Input bar
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                border: Border(
                  top: BorderSide(
                    color: isDark
                        ? const Color(0xFF334155)
                        : const Color(0xFFE2E8F0),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputCtl,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      decoration: InputDecoration(
                        hintText: 'اسأل روبوت المحاسب عن المبيعات، الديون، الأصناف...',
                        hintStyle: const TextStyle(fontSize: 12),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF047857),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: _sending ? null : () => _sendMessage(),
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: const Text(
                      'إرسال',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
