// ignore_for_file: deprecated_member_use
// تطبيق المدير المستقل — لوحة تفعيل تراخيص ومركز التحكم السحابي (مالك النظام فقط).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:url_launcher/url_launcher.dart';

import 'admin_updater.dart';
import 'rtdb.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ar', null);
  await Rtdb.instance.load();
  runApp(const AdminApp());
}

/// نبضة تحديث عامة: كل تفعيل/تمديد يُبلغ شاشات اللوحة فتُعيد التحميل.
final ValueNotifier<int> adminRefreshTick = ValueNotifier<int>(0);

class AdminApp extends StatelessWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مركز التحكم السحابي — Nexora Admin',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF0284C7),
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFFFFF),
          surfaceTintColor: Colors.transparent,
          foregroundColor: Color(0xFF0F172A),
          elevation: 0,
          scrolledUnderElevation: 0.5,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFFFFFFFF),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFE2E8F0), width: 1),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF8FAFC),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          isDense: true,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

String fmtDate(int ms, {bool lifetime = false}) {
  if (lifetime || ms > DateTime(2090).millisecondsSinceEpoch) return 'دائم ∞';
  if (ms <= 0) return '—';
  try {
    return DateFormat('yyyy/MM/dd — hh:mm a', 'ar')
        .format(DateTime.fromMillisecondsSinceEpoch(ms));
  } catch (_) {
    return DateFormat('yyyy/MM/dd')
        .format(DateTime.fromMillisecondsSinceEpoch(ms));
  }
}

void copyText(BuildContext context, String label, String value) {
  if (value.isEmpty) return;
  Clipboard.setData(ClipboardData(text: value));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('تم نسخ $label ✓ ($value)'),
        duration: const Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
      ),
    );
}

Future<void> callPhone(BuildContext context, String rawPhone) async {
  final clean = rawPhone.replaceAll(RegExp(r'[^0-9\+]'), '');
  if (clean.isEmpty) return;
  final uri = Uri.parse('tel:$clean');
  try {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذّر فتح تطبيق الاتصال')),
      );
    }
  }
}

Future<void> openWhatsApp(BuildContext context, String rawPhone,
    {String? msg}) async {
  final clean = rawPhone.replaceAll(RegExp(r'[^0-9]'), '');
  if (clean.isEmpty) return;
  final text = Uri.encodeComponent(msg ?? '');
  final direct = Uri.parse('whatsapp://send?phone=$clean&text=$text');
  final web = Uri.parse('https://wa.me/$clean?text=$text');

  try {
    if (await canLaunchUrl(direct)) {
      if (await launchUrl(direct, mode: LaunchMode.externalApplication)) return;
    }
  } catch (_) {}
  try {
    if (await launchUrl(web, mode: LaunchMode.externalApplication)) return;
  } catch (_) {}
  try {
    await launchUrl(web);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذّر فتح تطبيق واتساب')),
      );
    }
  }
}

// ==================== الشاشة الرئيسية ====================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  AdminUpdateInfo? _updateInfo;

  @override
  void initState() {
    super.initState();
    _checkAdminUpdateOnStart();
  }

  Future<void> _checkAdminUpdateOnStart() async {
    try {
      final info = await AdminUpdateService().check();
      if (!mounted) return;
      setState(() => _updateInfo = info);
      if (info.hasUpdate && mounted) {
        showAdminUpdateDialog(context, initialInfo: info);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final hasUpdate = _updateInfo?.hasUpdate ?? false;
    return Scaffold(
      appBar: AppBar(
        title: const Text('☁️ مركز التحكم السحابي والتراخيص',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'تحديثات تطبيق التراخيص (v$adminFullVersion)',
            icon: Badge(
              isLabelVisible: hasUpdate,
              backgroundColor: Colors.redAccent,
              child: Icon(
                Icons.system_update_alt_rounded,
                color: hasUpdate ? const Color(0xFF0284C7) : null,
              ),
            ),
            onPressed: () async {
              await showAdminUpdateDialog(context);
              final latest = await AdminUpdateService().check();
              if (mounted) setState(() => _updateInfo = latest);
            },
          ),
          IconButton(
            tooltip: 'إعدادات الاتصال بقاعدة البيانات',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await showDialog<void>(
                  context: context, builder: (_) => const _ConfigDialog());
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            tooltip: 'الإشعارات وطلبات التفعيل والدعم',
            onPressed: () => setState(() => _tab = 3),
            icon: const Text(
              '🔔',
              style: TextStyle(fontSize: 20, height: 1.0),
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: const [
          ActivationScreen(),
          SubscribersScreen(),
          VouchersScreen(),
          SupportInboxScreen(),
          OwnerCompanionScreen(),
          SystemControlScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.verified_outlined),
              selectedIcon: Icon(Icons.verified),
              label: 'تفعيل حساب'),
          NavigationDestination(
              icon: Icon(Icons.people_outline),
              selectedIcon: Icon(Icons.people),
              label: 'المشتركون'),
          NavigationDestination(
              icon: Icon(Icons.confirmation_number_outlined),
              selectedIcon: Icon(Icons.confirmation_number),
              label: 'أكواد الشحن'),
          NavigationDestination(
              icon: Icon(Icons.headset_mic_outlined),
              selectedIcon: Icon(Icons.headset_mic),
              label: 'الدعم الفني'),
          NavigationDestination(
              icon: Icon(Icons.psychology_alt_outlined),
              selectedIcon: Icon(Icons.psychology_alt),
              label: 'رفيق المالك'),
          NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune),
              label: 'مركز التحكم'),
        ],
      ),
    );
  }
}

// ==================== إعدادات الاتصال ومفتاح الذكاء الاصطناعي ====================

class _ConfigDialog extends StatefulWidget {
  const _ConfigDialog();
  @override
  State<_ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<_ConfigDialog> {
  late final _url = TextEditingController(text: Rtdb.instance.baseUrl);
  late final _openRouterKey =
      TextEditingController(text: Rtdb.instance.openRouterApiKey);
  late final _geminiKey =
      TextEditingController(text: Rtdb.instance.geminiApiKey);
  late final _grokKey = TextEditingController(text: Rtdb.instance.grokApiKey);
  late final _grokBaseUrl =
      TextEditingController(text: Rtdb.instance.grokBaseUrl);
  late String _selectedOpenRouterModel =
      kOpenRouterFreeModels.contains(Rtdb.instance.openRouterModel)
          ? Rtdb.instance.openRouterModel
          : kDefaultOpenRouterFreeModel;
  bool _obscureOpenRouterKey = true;
  bool _obscureGeminiKey = true;
  bool _obscureGrokKey = true;
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    _openRouterKey.dispose();
    _geminiKey.dispose();
    _grokKey.dispose();
    _grokBaseUrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
          '⚙️ إعدادات النظام ومفاتيح الديوانية (OpenRouter & Gemini & Grok)'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _url,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                labelText: 'رابط Firebase RTDB',
                hintText: kOfficialRtdbUrl,
                prefixIcon: Icon(Icons.cloud_outlined),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _openRouterKey,
              obscureText: _obscureOpenRouterKey,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: 'مفتاح OpenRouter المجاني (openrouter_api_key)',
                hintText: 'sk-or-v1-...',
                helperText:
                    'يُحفظ محلياً في SharedPreferences للربط مع https://openrouter.ai/api/v1/chat/completions',
                prefixIcon: const Icon(Icons.hub_rounded,
                    color: Color(0xFF0D9488)),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: _obscureOpenRouterKey
                          ? 'إظهار المفتاح'
                          : 'إخفاء المفتاح',
                      icon: Icon(_obscureOpenRouterKey
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () => setState(
                          () => _obscureOpenRouterKey = !_obscureOpenRouterKey),
                    ),
                    IconButton(
                      tooltip: 'لصق من الحافظة',
                      icon: const Icon(Icons.content_paste_rounded),
                      onPressed: () async {
                        final clip =
                            await Clipboard.getData(Clipboard.kTextPlain);
                        final txt = (clip?.text ?? '').trim();
                        if (txt.isNotEmpty) {
                          setState(() => _openRouterKey.text = txt);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _selectedOpenRouterModel,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'نموذج OpenRouter المجاني المعتمد',
                helperText:
                    'درجة الحرارة مضبوطة على 0.85 لردود تفاعلية وساخرة',
                prefixIcon: Icon(Icons.psychology_alt_rounded,
                    color: Color(0xFF0D9488)),
              ),
              items: const [
                DropdownMenuItem(
                  value: kDefaultOpenRouterFreeModel,
                  child: Text(
                    'meta-llama/llama-3.3-70b-instruct:free (الافتراضي)',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: kAltOpenRouterFreeModel,
                  child: Text(
                    'deepseek/deepseek-chat:free (البديل المجاني)',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: (val) {
                if (val != null) {
                  setState(() => _selectedOpenRouterModel = val);
                }
              },
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _geminiKey,
              obscureText: _obscureGeminiKey,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: 'مفتاح Gemini API (gemini_api_key)',
                hintText: 'AIzaSy...',
                helperText: 'يُحفظ محلياً في SharedPreferences لتفعيل Gemini',
                prefixIcon: const Icon(Icons.auto_awesome_rounded,
                    color: Color(0xFF4F46E5)),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: _obscureGeminiKey
                          ? 'إظهار المفتاح'
                          : 'إخفاء المفتاح',
                      icon: Icon(_obscureGeminiKey
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () => setState(
                          () => _obscureGeminiKey = !_obscureGeminiKey),
                    ),
                    IconButton(
                      tooltip: 'لصق من الحافظة',
                      icon: const Icon(Icons.content_paste_rounded),
                      onPressed: () async {
                        final clip =
                            await Clipboard.getData(Clipboard.kTextPlain);
                        final txt = (clip?.text ?? '').trim();
                        if (txt.isNotEmpty) {
                          setState(() => _geminiKey.text = txt);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _grokKey,
              obscureText: _obscureGrokKey,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: 'مفتاح Grok API (grok_api_key)',
                hintText: 'xai-... أو gsk_...',
                helperText: 'يُحفظ محلياً في SharedPreferences لتفعيل Grok',
                prefixIcon:
                    const Icon(Icons.bolt_rounded, color: Color(0xFF7E22CE)),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip:
                          _obscureGrokKey ? 'إظهار المفتاح' : 'إخفاء المفتاح',
                      icon: Icon(_obscureGrokKey
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () =>
                          setState(() => _obscureGrokKey = !_obscureGrokKey),
                    ),
                    IconButton(
                      tooltip: 'لصق من الحافظة',
                      icon: const Icon(Icons.content_paste_rounded),
                      onPressed: () async {
                        final clip =
                            await Clipboard.getData(Clipboard.kTextPlain);
                        final txt = (clip?.text ?? '').trim();
                        if (txt.isNotEmpty) {
                          setState(() => _grokKey.text = txt);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _grokBaseUrl,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                labelText: 'رابط المزود الاختياري (Base URL - Grok/Groq)',
                hintText: 'https://api.x.ai/v1 أو https://api.groq.com/openai/v1',
                helperText:
                    'اختياري: اتركه فارغاً للاستنتاج التلقائي (يدعم xAI وGroq API)',
                prefixIcon: Icon(Icons.link_rounded),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: const Icon(Icons.bolt_rounded, size: 16),
              label: const Text('تعبئة المفتاح المدمج والجاهز تلقائياً'),
              onPressed: () {
                setState(() {
                  _geminiKey.text = kDefaultInjectedDiwaniyaKey;
                  _grokKey.text = kDefaultInjectedDiwaniyaKey;
                  _grokBaseUrl.text = kDefaultGroqBaseUrl;
                });
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء')),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  final nav = Navigator.of(context);
                  setState(() => _busy = true);
                  try {
                    await Rtdb.instance.save(_url.text);
                    await Rtdb.instance.saveDiwaniyaSettings(
                      geminiKey: _geminiKey.text,
                      grokKey: _grokKey.text,
                      customGrokBaseUrl: _grokBaseUrl.text,
                      openRouterKey: _openRouterKey.text,
                      openRouterSelectedModel: _selectedOpenRouterModel,
                    );
                    adminRefreshTick.value++;
                    if (mounted) nav.pop();
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
          child: const Text('حفظ الإعدادات'),
        ),
      ],
    );
  }
}

// ==================== شاشة التفعيل الفردي ====================

class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key});
  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _input = TextEditingController();
  final _clientName = TextEditingController();
  final _storeName = TextEditingController();
  final _phone = TextEditingController();
  final _licenseKey = TextEditingController();
  final _amountCtrl = TextEditingController(text: '0');
  final _notesCtrl = TextEditingController();

  PlanDuration _duration = PlanDuration.year;
  String _planType = 'individual';
  int _maxDevices = 1;
  String _currency = 'YER';
  String _paymentMethod = 'نقداً';
  bool _busy = false;
  ActivationResult? _result;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    _clientName.dispose();
    _storeName.dispose();
    _phone.dispose();
    _licenseKey.dispose();
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  void _showActivationReceipt(
    ActivationResult r,
    double amount,
    String currency,
    String method,
  ) {
    final expStr = fmtDate(r.expiresAtMs, lifetime: r.lifetime);
    final phone = _phone.text.trim();
    final receiptText = '''
══════════════════════════════
 🧾 سند تفعيل ترخيص نظام Nexora
══════════════════════════════
المنشأة: ${r.storeName.isNotEmpty ? r.storeName : (_storeName.text.trim().isNotEmpty ? _storeName.text.trim() : '—')}
المسؤول: ${r.clientName.isNotEmpty ? r.clientName : (_clientName.text.trim().isNotEmpty ? _clientName.text.trim() : '—')}
الهاتف: ${phone.isNotEmpty ? phone : '—'}
كود الترخيص: ${r.licenseKey}
تاريخ التفعيل: ${DateFormat('yyyy/MM/dd hh:mm a', 'ar').format(DateTime.now())}
صالح حتى: $expStr
المبلغ المدفوع: $amount $currency
طريقة الدفع: $method
══════════════════════════════
شكراً لثقتكم بنظام Nexora Ledger
''';

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.receipt_long, color: Color(0xFF7C3AED)),
            SizedBox(width: 8),
            Text('سند التفعيل الإلكتروني'),
          ],
        ),
        content: SelectableText(
          receiptText,
          style: const TextStyle(
              fontFamily: 'monospace', fontSize: 12, height: 1.45),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              copyText(context, 'سند التفعيل', receiptText);
              Navigator.pop(ctx);
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('نسخ السند'),
          ),
          if (phone.isNotEmpty)
            FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF16A34A)),
              onPressed: () {
                Navigator.pop(ctx);
                openWhatsApp(context, phone, msg: receiptText);
              },
              icon: const Icon(Icons.send, size: 16),
              label: const Text('إرسال للعميل عبر واتساب'),
            ),
        ],
      ),
    );
  }

  Future<void> _activate() async {
    final raw = _input.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = 'أدخل معرف الجهاز أو مساحة العمل أولاً');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });

    try {
      final res = await Rtdb.instance.activate(
        rawInput: raw,
        planType: _planType,
        duration: _duration,
        maxDevices: _planType == 'enterprise' ? _maxDevices : 1,
        clientName: _clientName.text.trim(),
        storeName: _storeName.text.trim(),
        phone: _phone.text.trim(),
        licenseKey: _licenseKey.text.trim().isNotEmpty
            ? _licenseKey.text.trim()
            : generateLicenseKey(raw),
      );

      final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0.0;
      if (amount > 0) {
        final txId = 'bill_${DateTime.now().millisecondsSinceEpoch}';
        final record = BillingRecord(
          id: txId,
          workspaceId: res.workspaceId,
          clientName: res.clientName.isNotEmpty
              ? res.clientName
              : _clientName.text.trim(),
          storeName: res.storeName.isNotEmpty
              ? res.storeName
              : _storeName.text.trim(),
          amount: amount,
          currency: _currency,
          paymentMethod: _paymentMethod,
          durationDays: _duration.span.inDays,
          isLifetime: _duration == PlanDuration.lifetime,
          notes: _notesCtrl.text.trim().isNotEmpty
              ? _notesCtrl.text.trim()
              : 'تفعيل ترخيص ${_planType == 'enterprise' ? 'مؤسسة' : 'فردي'} (${_duration.label})',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
        await Rtdb.instance.recordBillingPayment(record);
      }

      setState(() => _result = res);
      adminRefreshTick.value++;

      if (amount > 0 && mounted) {
        _showActivationReceipt(res, amount, _currency, _paymentMethod);
      }
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = (data?.text ?? '').trim();
    if (text.isEmpty) return;

    String? extractField(List<String> keys) {
      for (final line in text.split(RegExp(r'[\r\n]+'))) {
        final clean = line.replaceAll('*', '').replaceAll('•', '').trim();
        for (final k in keys) {
          final idx = clean.indexOf(k);
          if (idx >= 0) {
            final after = clean.substring(idx + k.length).replaceFirst(RegExp(r'^[\s:：\-]+'), '').trim();
            if (after.isNotEmpty) return after;
          }
        }
      }
      return null;
    }

    final parsedId = extractField(['معرف الجهاز', 'معرف مساحة العمل', 'المعرف', 'Device ID', 'Workspace']);
    final parsedStore = extractField(['اسم المنشأة', 'المنشأة', 'المحل', 'المتجر']);
    final parsedClient = extractField(['اسم العميل', 'العميل', 'المسؤول']);
    final parsedPhone = extractField(['رقم الهاتف', 'الهاتف', 'الجوال', 'واتساب']);
    final parsedKey = extractField(['كود الترخيص', 'الترخيص', 'License']);

    setState(() {
      if (parsedId != null && parsedId.isNotEmpty) {
        _input.text = parsedId;
      } else {
        final devMatch = RegExp(r'(DEVICE-[A-Za-z0-9]+|[a-fA-F0-9]{24,64})').firstMatch(text);
        _input.text = devMatch?.group(0) ?? text;
      }
      if (parsedStore != null && parsedStore.isNotEmpty) _storeName.text = parsedStore;
      if (parsedClient != null && parsedClient.isNotEmpty) _clientName.text = parsedClient;
      if (parsedPhone != null && parsedPhone.isNotEmpty) _phone.text = parsedPhone;
      if (parsedKey != null && parsedKey.isNotEmpty) _licenseKey.text = parsedKey;
      if (text.contains('مؤسسة') || text.toLowerCase().contains('enterprise')) {
        _planType = 'enterprise';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('🔑 تفعيل أو تجديد ترخيص عميل',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w800)),
                    ),
                    TextButton.icon(
                      onPressed: _pasteFromClipboard,
                      icon: const Icon(Icons.content_paste_go_rounded, size: 18),
                      label: const Text('لصق طلب واتساب'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _input,
                  decoration: const InputDecoration(
                    labelText: 'معرف الجهاز أو مساحة العمل *',
                    hintText: 'مثال: DEVICE-ABC1234 أو بصمة 32 خانة',
                    prefixIcon: Icon(Icons.phonelink),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _storeName,
                  decoration: const InputDecoration(
                    labelText: 'اسم المنشأة / المحل',
                    hintText: 'سوبرماركت المدينة',
                    prefixIcon: Icon(Icons.storefront_outlined),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _clientName,
                  decoration: const InputDecoration(
                    labelText: 'اسم العميل / المسؤول',
                    hintText: 'محمد علي',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'رقم الهاتف / الواتساب',
                    hintText: '771234567',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                ),
                const SizedBox(height: 14),
                const Text('مدة الاشتراك:',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                DropdownButtonFormField<PlanDuration>(
                  value: _duration,
                  decoration: const InputDecoration(),
                  items: PlanDuration.values
                      .map((d) => DropdownMenuItem(
                            value: d,
                            child: Text(d.label),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _duration = v ?? _duration),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: RadioListTile<String>(
                        title: const Text('فردي'),
                        value: 'individual',
                        groupValue: _planType,
                        onChanged: (v) =>
                            setState(() => _planType = v ?? 'individual'),
                      ),
                    ),
                    Expanded(
                      child: RadioListTile<String>(
                        title: const Text('مؤسسة'),
                        value: 'enterprise',
                        groupValue: _planType,
                        onChanged: (v) =>
                            setState(() => _planType = v ?? 'enterprise'),
                      ),
                    ),
                  ],
                ),
                if (_planType == 'enterprise') ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('عدد الأجهزة المصرحة:'),
                      const SizedBox(width: 14),
                      DropdownButton<int>(
                        value: _maxDevices,
                        items: [2, 3, 5, 10, 20]
                            .map((n) => DropdownMenuItem(
                                value: n, child: Text('$n أجهزة')))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _maxDevices = v ?? 5),
                      ),
                    ],
                  ),
                ],
                const Divider(height: 28),
                const Text('💰 بيانات الدفع والإيرادات:',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _amountCtrl,
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'المبلغ المدفوع / المحصل',
                          hintText: '0',
                          prefixIcon: Icon(Icons.attach_money_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        value: _currency,
                        decoration: const InputDecoration(
                          labelText: 'العملة',
                        ),
                        items: ['YER', 'SAR', 'USD']
                            .map((c) =>
                                DropdownMenuItem(value: c, child: Text(c)))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _currency = v ?? _currency),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: _paymentMethod,
                  decoration: const InputDecoration(
                    labelText: 'طريقة الدفع',
                    prefixIcon: Icon(Icons.payment_rounded),
                  ),
                  items: [
                    'نقداً',
                    'بنك الكريمي',
                    'تحويل بنكي',
                    'جيب',
                    'ون كاش',
                    'أخرى'
                  ]
                      .map((m) =>
                          DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _paymentMethod = v ?? _paymentMethod),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _notesCtrl,
                  decoration: const InputDecoration(
                    labelText: 'ملاحظات الدفع (اختياري)',
                    hintText: 'رقم الحوالة، اسم المودع، إلخ...',
                    prefixIcon: Icon(Icons.note_alt_outlined),
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: const Color(0xFF7C3AED),
                  ),
                  onPressed: _busy ? null : _activate,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.check_circle_outline),
                  label: const Text('تفعيل الترخيص فوراً بالسحابة',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(_error!,
                        style: const TextStyle(
                            color: Color(0xFFDC2626),
                            fontWeight: FontWeight.w700)),
                  ),
                ],
                if (_result != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE7F7EE),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.verified,
                                color: Color(0xFF16A34A), size: 20),
                            SizedBox(width: 6),
                            Text('تم التفعيل بنجاح!',
                                style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF16A34A))),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                            'المساحة: ${_result!.workspaceId}\nينتهي في: ${fmtDate(_result!.expiresAtMs, lifetime: _result!.lifetime)}'),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ==================== سجل المشتركين وبطاقات الإدارة ====================

class SubscribersScreen extends StatefulWidget {
  const SubscribersScreen({super.key});
  @override
  State<SubscribersScreen> createState() => _SubscribersScreenState();
}

class _SubscribersScreenState extends State<SubscribersScreen> {
  final _search = TextEditingController();
  late Future<List<SubscriberEntry>> _future = _load();
  late Future<AdminMetrics> _metricsFuture = _loadMetrics();
  int _serverNow = 0;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    adminRefreshTick.addListener(_onTick);
    _loadServerClock();
  }

  @override
  void dispose() {
    adminRefreshTick.removeListener(_onTick);
    _search.dispose();
    super.dispose();
  }

  void _onTick() => _refresh();

  Future<void> _loadServerClock() async {
    try {
      final now = await Rtdb.instance.serverNowMs();
      if (mounted) setState(() => _serverNow = now);
    } catch (_) {
      if (mounted) {
        setState(() => _serverNow = DateTime.now().millisecondsSinceEpoch);
      }
    }
  }

  Future<List<SubscriberEntry>> _load() => Rtdb.instance.configured
      ? Rtdb.instance.recentSubscribers()
      : Future.value(const []);

  Future<AdminMetrics> _loadMetrics() => Rtdb.instance.configured
      ? Rtdb.instance.metrics()
      : Future.value(const AdminMetrics(
          totalWorkspaces: 0, activePaid: 0, activeTrials: 0, expired: 0));

  Future<void> _refresh() async {
    await _loadServerClock();
    if (!mounted) return;
    setState(() {
      _future = _load();
      _metricsFuture = _loadMetrics();
    });
  }

  Future<void> _extendWithPayment(SubscriberEntry s) async {
    final dur = await showModalBottomSheet<PlanDuration>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('⏳ تمديد الاشتراك — اختر المدة',
                  style: TextStyle(fontWeight: FontWeight.w800)),
            ),
            ...PlanDuration.values.map((x) => ListTile(
                  leading: const Icon(Icons.add_alarm),
                  title: Text(x.label),
                  onTap: () => Navigator.pop(ctx, x),
                )),
          ],
        ),
      ),
    );
    if (dur == null || !mounted) return;

    final amountCtrl = TextEditingController(text: '0');
    final notesCtrl = TextEditingController();
    String method = 'نقداً';
    String currency = 'YER';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          title: const Text('💰 تسجيل الدفع والتحصيل'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'تمديد لـ: ${s.storeName.isNotEmpty ? s.storeName : s.clientName}\nالمدة: ${dur.label}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: amountCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'المبلغ المحصل'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: currency,
                        items: ['YER', 'SAR', 'USD']
                            .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                            .toList(),
                        onChanged: (v) => setDState(() => currency = v ?? currency),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: method,
                  decoration: const InputDecoration(labelText: 'طريقة الدفع'),
                  items: ['نقداً', 'بنك الكريمي', 'تحويل بنكي', 'جيب', 'ون كاش', 'أخرى']
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setDState(() => method = v ?? method),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: notesCtrl,
                  decoration: const InputDecoration(labelText: 'ملاحظات / رقم الإيصال'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('إلغاء'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تخطي الدفع والتمديد فقط'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حفظ وتمديد'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == null) return;

    try {
      final r = await Rtdb.instance.activate(
        rawInput: s.workspaceId.isNotEmpty ? s.workspaceId : s.deviceId,
        planType: s.planType,
        duration: dur,
        maxDevices: s.maxDevices,
        extend: true,
        clientName: s.clientName,
        storeName: s.storeName,
        phone: s.phone,
        licenseKey: s.licenseKey,
      );

      final amount = double.tryParse(amountCtrl.text.trim()) ?? 0.0;
      if (confirmed == true && amount > 0) {
        final txId = 'bill_${DateTime.now().millisecondsSinceEpoch}';
        final record = BillingRecord(
          id: txId,
          workspaceId: s.workspaceId,
          clientName: s.clientName,
          storeName: s.storeName,
          amount: amount,
          currency: currency,
          paymentMethod: method,
          durationDays: dur.span.inDays,
          isLifetime: dur == PlanDuration.lifetime,
          notes: notesCtrl.text.trim(),
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
        await Rtdb.instance.recordBillingPayment(record);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF16A34A),
        content: Text('✅ مُدِّد بنجاح حتى ${fmtDate(r.expiresAtMs, lifetime: r.lifetime)}'),
      ));

      if (mounted) {
        _showRenewalReceipt(s, r, amount, currency, method);
      }

      adminRefreshTick.value++;
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: const Color(0xFFDC2626), content: Text('$e')),
      );
    }
  }

  void _showRenewalReceipt(
    SubscriberEntry s,
    ActivationResult r,
    double amount,
    String currency,
    String method,
  ) {
    final expStr = fmtDate(r.expiresAtMs, lifetime: r.lifetime);
    final receiptText = '''
══════════════════════════════
 🧾 سند تجديد ترخيص نظام Nexora
══════════════════════════════
المنشأة: ${s.storeName.isNotEmpty ? s.storeName : '—'}
المسؤول: ${s.clientName.isNotEmpty ? s.clientName : '—'}
الهاتف: ${s.phone.isNotEmpty ? s.phone : '—'}
كود الترخيص: ${s.licenseKey}
تاريخ التجديد: ${DateFormat('yyyy/MM/dd hh:mm a', 'ar').format(DateTime.now())}
صالح حتى: $expStr
المبلغ المحصل: $amount $currency
طريقة الدفع: $method
══════════════════════════════
شكراً لثقتكم بنظام Nexora Ledger
''';

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.receipt_long, color: Color(0xFF7C3AED)),
            SizedBox(width: 8),
            Text('سند التجديد الإلكتروني'),
          ],
        ),
        content: SelectableText(
          receiptText,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.45),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              copyText(context, 'سند التجديد', receiptText);
              Navigator.pop(ctx);
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('نسخ السند'),
          ),
          if (s.phone.isNotEmpty)
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF16A34A)),
              onPressed: () {
                Navigator.pop(ctx);
                openWhatsApp(context, s.phone, msg: receiptText);
              },
              icon: const Icon(Icons.send, size: 16),
              label: const Text('إرسال للعميل عبر واتساب'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nowMs =
        _serverNow > 0 ? _serverNow : DateTime.now().millisecondsSinceEpoch;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: FutureBuilder<List<SubscriberEntry>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final all = snap.data ?? const [];
          final q = _search.text.trim().toLowerCase();
          final qPhone = q.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');

          var filtered = all.where((s) {
            final matchStore = s.storeName.toLowerCase().contains(q);
            final matchUser = s.clientName.toLowerCase().contains(q);
            final cleanSPhone = s.phone.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
            final matchPhone =
                qPhone.isNotEmpty && cleanSPhone.contains(qPhone);
            final matchDevice = s.deviceId.toLowerCase().contains(q) ||
                s.deviceRef.toLowerCase().contains(q);
            final matchKey = s.licenseKey.toLowerCase().contains(q);
            final matchWs = s.workspaceId.toLowerCase().contains(q);

            return matchStore ||
                matchUser ||
                matchPhone ||
                matchDevice ||
                matchKey ||
                matchWs;
          }).toList();

          if (_filter == 'active') {
            filtered = filtered
                .where((s) =>
                    !s.isFrozen &&
                    s.status == 'active' &&
                    (s.expiresAtMs > nowMs ||
                        s.expiresAtMs >
                            DateTime(2090).millisecondsSinceEpoch))
                .toList();
          } else if (_filter == 'expired') {
            filtered = filtered
                .where((s) =>
                    !s.isFrozen &&
                    s.status != 'trial' &&
                    s.expiresAtMs <= nowMs &&
                    s.expiresAtMs < DateTime(2090).millisecondsSinceEpoch)
                .toList();
          } else if (_filter == 'trial') {
            filtered = filtered
                .where((s) => s.status == 'trial' || s.planType == 'trial')
                .toList();
          } else if (_filter == 'expiring_7d') {
            final sevenDays = nowMs + 7 * 86400000;
            filtered = filtered
                .where((s) =>
                    !s.isFrozen &&
                    s.expiresAtMs > nowMs &&
                    s.expiresAtMs <= sevenDays)
                .toList();
          } else if (_filter == 'suspended') {
            filtered = filtered.where((s) => s.isFrozen).toList();
          }

          return Column(
            children: [
              FutureBuilder<AdminMetrics>(
                future: _metricsFuture,
                builder: (context, mSnap) {
                  final m = mSnap.data;
                  if (m == null) return const SizedBox.shrink();
                  return Container(
                    margin: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _MetricChip(
                            label: 'النشطون',
                            value: '${m.activePaid}',
                            color: const Color(0xFF16A34A),
                            isSelected: _filter == 'active',
                            onTap: () {
                              setState(() {
                                _filter =
                                    _filter == 'active' ? 'all' : 'active';
                              });
                            },
                          ),
                          const SizedBox(width: 8),
                          _MetricChip(
                            label: 'المنتهون',
                            value: '${m.expired}',
                            color: const Color(0xFFDC2626),
                            isSelected: _filter == 'expired',
                            onTap: () {
                              setState(() {
                                _filter =
                                    _filter == 'expired' ? 'all' : 'expired';
                              });
                            },
                          ),
                          const SizedBox(width: 8),
                          _MetricChip(
                            label: 'التجريبيون',
                            value: '${m.activeTrials}',
                            color: const Color(0xFF7C3AED),
                            isSelected: _filter == 'trial',
                            onTap: () {
                              setState(() {
                                _filter = _filter == 'trial' ? 'all' : 'trial';
                              });
                            },
                          ),
                          const SizedBox(width: 8),
                          _MetricChip(
                            label: 'خلال 7 أيام',
                            value: '${m.expiringIn7Days}',
                            color: const Color(0xFFEA580C),
                            isSelected: _filter == 'expiring_7d',
                            onTap: () {
                              setState(() {
                                _filter = _filter == 'expiring_7d'
                                    ? 'all'
                                    : 'expiring_7d';
                              });
                            },
                          ),
                          const SizedBox(width: 8),
                          _MetricChip(
                            label: 'الإيراد الشهري',
                            value: '${m.monthlyRevenue.toInt()}',
                            color: const Color(0xFF2563EB),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    labelText: 'بحث بالمنشأة، العميل، الهاتف، أو كود الترخيص',
                    hintText: 'ابحث باسم المتجر أو المسؤول...',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _search.clear();
                              setState(() {});
                            },
                          ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    FilterChip(
                      label: const Text('الكل'),
                      selected: _filter == 'all',
                      onSelected: (_) => setState(() => _filter = 'all'),
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: const Text('النشطون'),
                      selected: _filter == 'active',
                      onSelected: (_) => setState(() => _filter = 'active'),
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: const Text('المنتهون'),
                      selected: _filter == 'expired',
                      onSelected: (_) => setState(() => _filter = 'expired'),
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: const Text('التجريبيون'),
                      selected: _filter == 'trial',
                      onSelected: (_) => setState(() => _filter = 'trial'),
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: const Text('خلال 7 أيام'),
                      selected: _filter == 'expiring_7d',
                      onSelected: (_) =>
                          setState(() => _filter = 'expiring_7d'),
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: const Text('المعلقون ❄️'),
                      selected: _filter == 'suspended',
                      onSelected: (_) => setState(() => _filter = 'suspended'),
                    ),
                  ],
                ),
              ),
              Expanded(child: _buildList(filtered, nowMs)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildList(List<SubscriberEntry> list, int nowMs) {
    if (list.isEmpty) {
      return ListView(children: const [
        Padding(
          padding: EdgeInsets.all(40),
          child: Column(children: [
            Icon(Icons.inbox_outlined, size: 56, color: Colors.grey),
            SizedBox(height: 10),
            Text('لا توجد سجلات مطابقة',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700)),
          ]),
        ),
      ]);
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: list.length,
      separatorBuilder: (_, i) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final s = list[i];
        return SubscriberCard(
          entry: s,
          nowMs: nowMs,
          onExtend: () => _extendWithPayment(s),
          onRefresh: _refresh,
        );
      },
    );
  }
}

class _MetricChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final bool isSelected;
  final VoidCallback? onTap;

  const _MetricChip({
    required this.label,
    required this.value,
    required this.color,
    this.isSelected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? color : color.withValues(alpha: .1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: color,
            width: isSelected ? 1.8 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: .3),
                    blurRadius: 4,
                    offset: const Offset(0, 1.5),
                  )
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$label: ',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isSelected ? Colors.white : color,
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: isSelected ? Colors.white : color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== بطاقة المشترك الموسعة ====================

class SubscriberCard extends StatelessWidget {
  final SubscriberEntry entry;
  final VoidCallback onExtend;
  final VoidCallback? onRefresh;
  final int? nowMs;

  const SubscriberCard({
    super.key,
    required this.entry,
    required this.onExtend,
    this.onRefresh,
    this.nowMs,
  });

  @override
  Widget build(BuildContext context) {
    final s = entry;
    final currentMs = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final lifetime = s.expiresAtMs > DateTime(2090).millisecondsSinceEpoch;
    final expired = !lifetime && s.expiresAtMs <= currentMs;

    Color color;
    String statusText;

    if (s.isFrozen) {
      color = const Color(0xFF6B7280);
      statusText = 'معلّق ❄️';
    } else if (expired) {
      color = const Color(0xFFDC2626);
      statusText = 'منتهي';
    } else if (lifetime) {
      color = const Color(0xFF7C3AED);
      statusText = 'دائم ∞';
    } else if (s.status == 'trial') {
      color = const Color(0xFFD97706);
      statusText = 'تجريبي';
    } else {
      color = const Color(0xFF16A34A);
      statusText = 'فعّال';
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: .35), width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.storefront_rounded, size: 24, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.storeName.isNotEmpty
                            ? s.storeName
                            : (s.workspaceId.isNotEmpty
                                ? s.workspaceId
                                : 'منشأة غير مسمّاة'),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          const Icon(Icons.person_outline,
                              size: 14, color: Colors.grey),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              s.clientName.isNotEmpty
                                  ? s.clientName
                                  : 'مسؤول غير محدد',
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (s.phone.isNotEmpty) ...[
                            const Text('  •  ',
                                style: TextStyle(color: Colors.grey)),
                            Directionality(
                              textDirection: TextDirection.ltr,
                              child: Text(
                                s.phone,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF2563EB),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: color.withValues(alpha: .3)),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
            if (s.phone.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.phone_in_talk,
                          size: 14, color: Color(0xFF2563EB)),
                      label: const Text('اتصال سريع',
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF2563EB))),
                      backgroundColor:
                          const Color(0xFF2563EB).withValues(alpha: .08),
                      side: BorderSide(
                          color:
                              const Color(0xFF2563EB).withValues(alpha: .2)),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => callPhone(context, s.phone),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.chat_bubble_outline,
                          size: 14, color: Color(0xFF16A34A)),
                      label: const Text('واتساب بنقرة',
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF16A34A))),
                      backgroundColor:
                          const Color(0xFF16A34A).withValues(alpha: .08),
                      side: BorderSide(
                          color:
                              const Color(0xFF16A34A).withValues(alpha: .2)),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => openWhatsApp(
                        context,
                        s.phone,
                        msg:
                            'مرحباً ${s.clientName.isNotEmpty ? s.clientName : ''}، بخصوص ترخيص تطبيق Nexora Ledger.',
                      ),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.notifications_active_outlined,
                          size: 14, color: Color(0xFF7C3AED)),
                      label: const Text('تذكير بالتجديد',
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF7C3AED))),
                      backgroundColor:
                          const Color(0xFF7C3AED).withValues(alpha: .08),
                      side: BorderSide(
                          color:
                              const Color(0xFF7C3AED).withValues(alpha: .2)),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        final storeTitle = s.storeName.isNotEmpty
                            ? s.storeName
                            : (s.clientName.isNotEmpty ? s.clientName : 'عميلنا العزيز');
                        final expStr = fmtDate(s.expiryDate, lifetime: lifetime);
                        final reminderMsg =
                            'مرحباً $storeTitle، نود تذكيركم بأن ترخيص البرنامج سينتهي بتاريخ $expStr، للتجديد يرجى التواصل معنا.';
                        openWhatsApp(context, s.phone, msg: reminderMsg);
                      },
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),

            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: .06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.key, size: 15, color: Color(0xFF7C3AED)),
                  const SizedBox(width: 6),
                  const Text('كود الترخيص: ',
                      style: TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w700)),
                  Expanded(
                    child: Text(
                      s.licenseKey,
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'نسخ كود الترخيص',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    icon: const Icon(Icons.copy, size: 14),
                    onPressed: () =>
                        copyText(context, 'كود الترخيص', s.licenseKey),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 5),

            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: .06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.devices, size: 15, color: Colors.grey),
                  const SizedBox(width: 6),
                  const Text('معرف الجهاز: ',
                      style: TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w700)),
                  Expanded(
                    child: Text(
                      s.deviceId.isNotEmpty ? s.deviceId : s.deviceRef,
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                          fontSize: 11.5, color: Colors.black87),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'نسخ معرف الجهاز',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    icon: const Icon(Icons.copy, size: 14),
                    onPressed: () => copyText(context, 'معرف الجهاز',
                        s.deviceId.isNotEmpty ? s.deviceId : s.deviceRef),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            Row(
              children: [
                Icon(
                  s.planType == 'enterprise' ? Icons.business : Icons.person,
                  size: 15,
                  color: Colors.grey.shade700,
                ),
                const SizedBox(width: 5),
                Text(
                  s.planType == 'enterprise'
                      ? 'باقة مؤسسة (${s.maxDevices} أجهزة مصرحة)'
                      : 'باقة فردية (جهاز واحد مصرح)',
                  style: const TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  'ينتهي: ${fmtDate(s.expiryDate, lifetime: lifetime)}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: expired ? const Color(0xFFDC2626) : Colors.black87,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            Row(
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: onExtend,
                  icon: const Icon(Icons.more_time, size: 16),
                  label: const Text('تمديد بنقرة',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () => _openRemoteActionsMenu(context),
                  icon: const Icon(Icons.settings_remote_rounded, size: 16),
                  label: const Text('إجراءات التحكم عن بعد',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _openRemoteActionsMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.settings_remote, color: Color(0xFF7C3AED)),
                    const SizedBox(width: 8),
                    Text(
                      'إجراءات التحكم عن بعد — ${entry.storeName.isNotEmpty ? entry.storeName : entry.workspaceId}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
              const Divider(),
              ListTile(
                leading: Icon(
                  entry.isFrozen ? Icons.lock_open_rounded : Icons.lock_person_rounded,
                  color: entry.isFrozen ? Colors.green : Colors.red,
                ),
                title: Text(entry.isFrozen ? 'فك تجميد الحساب واستئناف الخدمة' : 'قفل وتعليق التطبيق فوراً (Kill Switch)'),
                subtitle: Text(entry.isFrozen ? 'إلغاء شاشة القفل والسماح للمستخدم بالدخول' : 'إظهار شاشة قفل مانعة للنزاعات أو تأخر السداد'),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await Rtdb.instance.toggleFreezeSubscriber(entry.workspaceId, !entry.isFrozen);
                    onRefresh?.call();
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$e'), backgroundColor: Colors.red),
                      );
                    }
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.link_off_rounded, color: Colors.orange),
                title: const Text('إلغاء الترخيص وفك ارتباط الجهاز (Unlink)'),
                subtitle: const Text('مسح كود الجهاز لإتاحة تفعيله على هاتف جديد'),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await Rtdb.instance.unlinkSubscriberDevice(entry.workspaceId);
                    onRefresh?.call();
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$e'), backgroundColor: Colors.red),
                      );
                    }
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.toggle_on_outlined, color: Colors.teal),
                title: const Text('إدارة الميزات والصلاحيات (Feature Flags)'),
                subtitle: const Text('تفعيل/تعطيل المزامنة، النسخ، وسقوف الأجهزة'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showFeatureFlagsDialog(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.devices_other_rounded, color: Colors.blue),
                title: const Text('استعراض أجهزة المنشأة وطرد جهاز (Kick)'),
                subtitle: const Text('عرض قائمة الكاشيرات المتصلة وفك ارتباط جهاز مسروق/معطل'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showConnectedDevicesDialog(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.cloud_upload_outlined, color: Colors.indigo),
                title: const Text('أمر النسخ الفوري عن بعد (Remote Backup)'),
                subtitle: const Text('إرسال إشارة للتطبيق لأخذ نسخة سحابية في الخلفية فوراً'),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await Rtdb.instance.requestInstantBackup(entry.workspaceId);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('تم إرسال إشارة النسخ الفوري للجهاز ✓')),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$e'), backgroundColor: Colors.red),
                      );
                    }
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.add_alert_outlined, color: Colors.deepPurple),
                title: const Text('إرسال إشعار وتنبيه مباشر للعميل'),
                subtitle: const Text('إشعار مخصص يظهر في شريط إشعارات العميل والتطبيق'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showDirectAlertModal(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.history_edu_rounded, color: Colors.brown),
                title: const Text('سجل المدفوعات والتحصيل السابق'),
                subtitle: const Text('استعراض الفواتير والمبالغ المحصلة من هذه المنشأة'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showBillingHistoryDialog(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever_rounded, color: Colors.red),
                title: const Text('حذف المشترك والترخيص فوراً وبشكل نهائي',
                    style: TextStyle(color: Colors.red, fontWeight: FontWeight.w800)),
                subtitle: const Text('حذف فوري ومباشر من السحابة بدون سلة محذوفات'),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await Rtdb.instance.deleteSubscriberImmediately(entry.workspaceId);
                    onRefresh?.call();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('تم حذف المشترك نهائياً وبشكل مباشر ✓')),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$e'), backgroundColor: Colors.red),
                      );
                    }
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showFeatureFlagsDialog(BuildContext context) {
    final flags = Map<String, bool>.from(entry.featureFlags);
    bool cloudSync = flags['cloud_sync'] ?? true;
    bool cloudBackup = flags['cloud_backup'] ?? true;
    bool multiBranch = flags['multi_branch'] ?? true;
    bool multiUser = flags['multi_user'] ?? true;
    bool advancedInvoicing = flags['advanced_invoicing'] ?? true;
    final maxDevCtrl = TextEditingController(text: '${entry.maxDevices}');

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          title: const Text('⚙️ إدارة الميزات وسقوف الاستخدام'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  title: const Text('المزامنة السحابية'),
                  value: cloudSync,
                  onChanged: (v) => setDState(() => cloudSync = v),
                ),
                SwitchListTile(
                  title: const Text('النسخ الاحتياطي السحابي'),
                  value: cloudBackup,
                  onChanged: (v) => setDState(() => cloudBackup = v),
                ),
                SwitchListTile(
                  title: const Text('تعدد الفروع'),
                  value: multiBranch,
                  onChanged: (v) => setDState(() => multiBranch = v),
                ),
                SwitchListTile(
                  title: const Text('تعدد المستخدمين'),
                  value: multiUser,
                  onChanged: (v) => setDState(() => multiUser = v),
                ),
                SwitchListTile(
                  title: const Text('الفواتير المتقدمة'),
                  value: advancedInvoicing,
                  onChanged: (v) => setDState(() => advancedInvoicing = v),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: maxDevCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'سقف عدد الأجهزة المسموحة',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () async {
                final newFlags = {
                  'cloud_sync': cloudSync,
                  'cloud_backup': cloudBackup,
                  'multi_branch': multiBranch,
                  'multi_user': multiUser,
                  'advanced_invoicing': advancedInvoicing,
                };
                final maxD = int.tryParse(maxDevCtrl.text.trim()) ?? entry.maxDevices;
                await Rtdb.instance.updateFeatureFlags(entry.workspaceId, newFlags, maxDevices: maxD);
                if (ctx.mounted) Navigator.pop(ctx);
                onRefresh?.call();
              },
              child: const Text('حفظ التغييرات'),
            ),
          ],
        ),
      ),
    );
  }

  void _showConnectedDevicesDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => FutureBuilder<List<ConnectedDevice>>(
        future: Rtdb.instance.getConnectedDevices(entry.workspaceId),
        builder: (ctx, snap) {
          final devices = snap.data ?? [];
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.devices, color: Color(0xFF2563EB)),
                SizedBox(width: 8),
                Text('أجهزة المنشأة المتصلة'),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: snap.connectionState == ConnectionState.waiting
                  ? const Center(child: CircularProgressIndicator())
                  : devices.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(20),
                          child: Text('لا توجد أجهزة متصلة مسجلة بعد', textAlign: TextAlign.center),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: devices.length,
                          separatorBuilder: (_, __) => const Divider(),
                          itemBuilder: (ctx, i) {
                            final d = devices[i];
                            return ListTile(
                              leading: const Icon(Icons.point_of_sale_rounded),
                              title: Text(d.deviceName.isNotEmpty ? d.deviceName : d.deviceId),
                              subtitle: Text(
                                'موديل: ${d.model} • نظام: ${d.platform}\nآخر ظهور: ${fmtDate(d.lastSeenAt)}',
                                style: const TextStyle(fontSize: 11),
                              ),
                              trailing: IconButton(
                                tooltip: 'طرد الجهاز (Kick)',
                                icon: const Icon(Icons.delete_forever, color: Colors.red),
                                onPressed: () async {
                                  await Rtdb.instance.kickDevice(entry.workspaceId, d.deviceId);
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  onRefresh?.call();
                                },
                              ),
                            );
                          },
                        ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
            ],
          );
        },
      ),
    );
  }

  void _showDirectAlertModal(BuildContext context) {
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    bool isModal = false;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          title: const Text('🔔 إرسال إشعار موجه للعميل'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(labelText: 'عنوان الإشعار'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: bodyCtrl,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'نص الإشعار'),
              ),
              const SizedBox(height: 10),
              SwitchListTile(
                title: const Text('نافذة منبثقة إجبارية (Modal Dialog)'),
                value: isModal,
                onChanged: (v) => setDState(() => isModal = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () async {
                final t = titleCtrl.text.trim();
                final b = bodyCtrl.text.trim();
                if (t.isEmpty || b.isEmpty) return;
                await Rtdb.instance.sendTargetedNotification(
                  entry.workspaceId,
                  title: t,
                  body: b,
                  isModal: isModal,
                );
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('تم إرسال الإشعار للعميل بنجاح ✓')),
                  );
                }
              },
              child: const Text('إرسال الآن'),
            ),
          ],
        ),
      ),
    );
  }

  void _showBillingHistoryDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => FutureBuilder<List<BillingRecord>>(
        future: Rtdb.instance.getBillingHistory(entry.workspaceId),
        builder: (ctx, snap) {
          final list = snap.data ?? [];
          return AlertDialog(
            title: const Text('📜 سجل المدفوعات والتحصيل'),
            content: SizedBox(
              width: double.maxFinite,
              child: snap.connectionState == ConnectionState.waiting
                  ? const Center(child: CircularProgressIndicator())
                  : list.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(20),
                          child: Text('لا توجد عمليات دفع مسجلة', textAlign: TextAlign.center),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: list.length,
                          separatorBuilder: (_, __) => const Divider(),
                          itemBuilder: (ctx, i) {
                            final b = list[i];
                            return ListTile(
                              leading: const Icon(Icons.monetization_on, color: Colors.green),
                              title: Text('${b.amount} ${b.currency} — ${b.paymentMethod}'),
                              subtitle: Text(
                                'التاريخ: ${fmtDate(b.timestamp)}\nالمدة: ${b.durationDays} يوماً ${b.notes.isNotEmpty ? '• ${b.notes}' : ''}',
                                style: const TextStyle(fontSize: 11),
                              ),
                            );
                          },
                        ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
            ],
          );
        },
      ),
    );
  }
}

// ==================== شاشة أكواد الشحن والتفعيل (Voucher Keys) ====================

class VouchersScreen extends StatefulWidget {
  const VouchersScreen({super.key});
  @override
  State<VouchersScreen> createState() => _VouchersScreenState();
}

class _VouchersScreenState extends State<VouchersScreen> {
  late Future<List<VoucherModel>> _future = Rtdb.instance.getVouchers();
  String _filter = 'all';

  Future<void> _refresh() async {
    setState(() => _future = Rtdb.instance.getVouchers());
  }

  Future<void> _generateDialog() async {
    int durationDays = 30;
    bool isLifetime = false;
    int count = 5;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          title: const Text('🎟️ توليد أكواد تفعيل مسبقة الدفع'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                value: isLifetime ? 99999 : durationDays,
                decoration: const InputDecoration(labelText: 'مدة الصلاحية'),
                items: const [
                  DropdownMenuItem(value: 30, child: Text('شهر واحد (30 يوماً)')),
                  DropdownMenuItem(value: 90, child: Text('3 أشهر (90 يوماً)')),
                  DropdownMenuItem(value: 365, child: Text('سنة كاملة (365 يوماً)')),
                  DropdownMenuItem(value: 99999, child: Text('تفعيل دائم (مدى الحياة)')),
                ],
                onChanged: (v) {
                  setDState(() {
                    if (v == 99999) {
                      isLifetime = true;
                    } else {
                      isLifetime = false;
                      durationDays = v ?? 30;
                    }
                  });
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                value: count,
                decoration: const InputDecoration(labelText: 'عدد الأكواد المطلوبة'),
                items: [1, 5, 10, 20]
                    .map((n) => DropdownMenuItem(value: n, child: Text('$n أكواد')))
                    .toList(),
                onChanged: (v) => setDState(() => count = v ?? 5),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await Rtdb.instance.generateVouchers(
                  durationDays: durationDays,
                  isLifetime: isLifetime,
                  count: count,
                );
                _refresh();
              },
              child: const Text('توليد وحفظ بالسحابة'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<VoucherModel>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final all = snap.data ?? [];
            var list = all;
            if (_filter == 'available') {
              list = all.where((v) => !v.isUsed).toList();
            } else if (_filter == 'used') {
              list = all.where((v) => v.isUsed).toList();
            }

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                  child: Row(
                    children: [
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF7C3AED),
                        ),
                        onPressed: _generateDialog,
                        icon: const Icon(Icons.add_card, size: 18),
                        label: const Text('توليد حزمة أكواد جديدة',
                            style: TextStyle(fontWeight: FontWeight.w800)),
                      ),
                      const Spacer(),
                      Text('الإجمالي: ${all.length}',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      FilterChip(
                        label: const Text('الكل'),
                        selected: _filter == 'all',
                        onSelected: (_) => setState(() => _filter = 'all'),
                      ),
                      const SizedBox(width: 6),
                      FilterChip(
                        label: const Text('متاحة للشحن'),
                        selected: _filter == 'available',
                        onSelected: (_) => setState(() => _filter = 'available'),
                      ),
                      const SizedBox(width: 6),
                      FilterChip(
                        label: const Text('مستخدمة'),
                        selected: _filter == 'used',
                        onSelected: (_) => setState(() => _filter = 'used'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: list.isEmpty
                      ? const Center(child: Text('لا توجد أكواد تفعيل مطابقة'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(14),
                          itemCount: list.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (ctx, i) {
                            final v = list[i];
                            return Card(
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                  color: v.isUsed
                                      ? Colors.grey.shade300
                                      : const Color(0xFF7C3AED).withValues(alpha: .35),
                                ),
                              ),
                              child: ListTile(
                                leading: Icon(
                                  v.isUsed ? Icons.check_circle : Icons.vpn_key_rounded,
                                  color: v.isUsed ? Colors.grey : const Color(0xFF7C3AED),
                                ),
                                title: Row(
                                  children: [
                                    SelectableText(
                                      v.code,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontWeight: FontWeight.w900,
                                        fontSize: 14,
                                        color: v.isUsed ? Colors.grey : const Color(0xFF7C3AED),
                                      ),
                                    ),
                                    const Spacer(),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: v.isUsed
                                            ? Colors.grey.shade200
                                            : const Color(0xFF16A34A).withValues(alpha: .15),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        v.isUsed ? 'مستخدم' : 'متاح للشحن',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w800,
                                          color: v.isUsed ? Colors.grey : const Color(0xFF16A34A),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                subtitle: Text(
                                  'المدة: ${v.durationLabel} • أُنشئ: ${fmtDate(v.createdAt)}'
                                  '${v.isUsed ? '\nاستُخدم بواسطة: ${v.usedByWs} (${fmtDate(v.usedAt)})' : ''}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: 'نسخ الكود',
                                      icon: const Icon(Icons.copy, size: 16),
                                      onPressed: () => copyText(context, 'كود التفعيل', v.code),
                                    ),
                                    if (!v.isUsed)
                                      IconButton(
                                        tooltip: 'مشاركة الكود (واتساب)',
                                        icon: const Icon(Icons.share, size: 16),
                                        onPressed: () {
                                          final shareMsg =
                                              'كود تفعيل اشتراكك في نظام Nexora:\n${v.code}\nصالح لمدة: ${v.durationLabel}\nاشحن الكود من شاشة تفاصيل الاشتراك بالتطبيق.';
                                          Clipboard.setData(ClipboardData(text: shareMsg));
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('تم نسخ رسالة المشاركة للكود ✓')),
                                          );
                                        },
                                      ),
                                    IconButton(
                                      tooltip: 'حذف',
                                      icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                                      onPressed: () async {
                                        await Rtdb.instance.deleteVoucher(v.code);
                                        _refresh();
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
            );
          },
        ),
      ),
    );
  }
}

// ==================== صندوق وارد الدعم الفني (Support Inbox — Client Support Mode) ====================

class SupportInboxScreen extends StatefulWidget {
  const SupportInboxScreen({super.key});
  @override
  State<SupportInboxScreen> createState() => _SupportInboxScreenState();
}

class _SupportInboxScreenState extends State<SupportInboxScreen> {
  late Future<List<Map<String, dynamic>>> _future =
      Rtdb.instance.getSupportConversations();
  bool _autoReplyingBatch = false;

  @override
  void initState() {
    super.initState();
    adminRefreshTick.addListener(_onTick);
  }

  @override
  void dispose() {
    adminRefreshTick.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (mounted) _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _future = Rtdb.instance.getSupportConversations());
  }

  Future<void> _runAutoSupportForPending(
      List<Map<String, dynamic>> list) async {
    if (_autoReplyingBatch) return;
    final apiKey = DualPersonaAiEngine.instance.apiKey;
    if (apiKey.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'يرجى إدخال مفتاح Gemini API (gemini_api_key) في الضبط لتفعيل الرد التلقائي.'),
          ),
        );
      }
      return;
    }

    final pending = list
        .where((c) =>
            c['lastSender'] == 'client' &&
            c['awaitingOwnerReply'] != true &&
            '${c['lastMessage'] ?? ''}'.trim().isNotEmpty)
        .toList();
    if (pending.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('لا توجد رسائل عملاء معلقة تحتاج إلى رد تلقائي حالياً.')),
        );
      }
      return;
    }

    setState(() => _autoReplyingBatch = true);
    int repliedCount = 0;
    try {
      for (final c in pending) {
        final wsId = '${c['workspaceId']}';
        final lastMsg = '${c['lastMessage']}';
        final session = DualPersonaAiEngine.instance.supportSessionFor(wsId);
        final reply = await session.sendMessage(lastMsg, apiKey: apiKey);
        if (reply.isNotEmpty) {
          await Rtdb.instance.sendSupportReply(
            wsId,
            reply,
            isAutoSupport: true,
          );
          repliedCount++;
        }
      }
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('تم الرد البشري التلقائي على $repliedCount محادثة ✓')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _autoReplyingBatch = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasKey = DualPersonaAiEngine.instance.hasApiKey;
    final autoEnabled = Rtdb.instance.autoSupportEnabled;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (context, snap) {
            final list = snap.data ?? [];
            return Column(
              children: [
                // شريط حالة النمط الثاني: الدعم الفني للمستخدمين (temperature: 0.2)
                Container(
                  margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0284C7)
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.support_agent_rounded,
                                color: Color(0xFF0284C7), size: 20),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'نمط الدعم الفني للمستخدمين (Client Support Mode)',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13),
                                ),
                                Text(
                                  'موظف دعم بشري هادئ ومتفهم (temperature: 0.2) مع قاعدة التصعيد الإلزامية',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.black54),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: autoEnabled,
                            onChanged: (v) async {
                              await Rtdb.instance.saveAutoSupportEnabled(v);
                              if (mounted) setState(() {});
                            },
                          ),
                        ],
                      ),
                      if (!hasKey) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFF59E0B)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.key_off_rounded,
                                  color: Color(0xFFD97706), size: 18),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'مفتاح Gemini API غير مُدخل. يرجى إدخال المفتاح في شاشة الضبط لتفعيل ردود الدعم الذكية.',
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF92400E)),
                                ),
                              ),
                              TextButton(
                                onPressed: () async {
                                  await showDialog<void>(
                                    context: context,
                                    builder: (_) => const _ConfigDialog(),
                                  );
                                  if (mounted) setState(() {});
                                },
                                child: const Text('إدخال المفتاح'),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.tonalIcon(
                                onPressed: _autoReplyingBatch
                                    ? null
                                    : () => _runAutoSupportForPending(list),
                                icon: _autoReplyingBatch
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      )
                                    : const Icon(Icons.auto_fix_high_rounded,
                                        size: 16),
                                label: const Text(
                                  'الرد التلقائي على التذاكر الجديدة',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'تحديث القائمة',
                              onPressed: _refresh,
                              icon: const Icon(Icons.refresh_rounded, size: 20),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: snap.connectionState == ConnectionState.waiting
                      ? const Center(child: CircularProgressIndicator())
                      : list.isEmpty
                          ? const Center(
                              child:
                                  Text('لا توجد محادثات دعم فني واردة بعد'),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.all(12),
                              itemCount: list.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (ctx, i) {
                                final c = list[i];
                                final unread = c['unreadByAdmin'] == true;
                                final awaitingOwner =
                                    c['awaitingOwnerReply'] == true;
                                final wsId = '${c['workspaceId']}';
                                return Card(
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    side: BorderSide(
                                      color: awaitingOwner
                                          ? const Color(0xFFD97706)
                                          : unread
                                              ? const Color(0xFF0284C7)
                                              : const Color(0xFFE2E8F0),
                                      width:
                                          (awaitingOwner || unread) ? 1.5 : 1,
                                    ),
                                  ),
                                  child: ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: awaitingOwner
                                          ? const Color(0xFFFEF3C7)
                                          : unread
                                              ? const Color(0xFF0284C7)
                                              : const Color(0xFFE2E8F0),
                                      child: Icon(
                                        awaitingOwner
                                            ? Icons.priority_high_rounded
                                            : Icons.storefront_outlined,
                                        color: awaitingOwner
                                            ? const Color(0xFFD97706)
                                            : unread
                                                ? Colors.white
                                                : Colors.black54,
                                      ),
                                    ),
                                    title: Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        Text(
                                          '${c['storeName']}',
                                          style: TextStyle(
                                            fontWeight: (unread || awaitingOwner)
                                                ? FontWeight.w900
                                                : FontWeight.w700,
                                          ),
                                        ),
                                        if (awaitingOwner)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFFEF3C7),
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              border: Border.all(
                                                  color:
                                                      const Color(0xFFF59E0B)),
                                            ),
                                            child: const Text(
                                              'بانتظار رد مدير المشروع',
                                              style: TextStyle(
                                                color: Color(0xFF92400E),
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ),
                                        if (unread && !awaitingOwner)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFDC2626),
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                            child: const Text(
                                              'جديد',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 10,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    subtitle: Text(
                                      '${c['clientName'].toString().isNotEmpty ? c['clientName'] : 'عميل'} • ${c['phone'].toString().isNotEmpty ? c['phone'] : 'بلا هاتف'}\n${c['lastMessage']}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          tooltip: 'حذف التذكرة فوراً',
                                          icon: const Icon(
                                            Icons.delete_outline_rounded,
                                            color: Colors.redAccent,
                                            size: 20,
                                          ),
                                          onPressed: () async {
                                            await Rtdb.instance
                                                .deleteSupportConversation(
                                                    wsId);
                                            DualPersonaAiEngine.instance
                                                .clearSupportSession(wsId);
                                            await _refresh();
                                          },
                                        ),
                                        const Icon(Icons.chevron_left),
                                      ],
                                    ),
                                    onTap: () async {
                                      await Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              AdminSupportChatDetailScreen(
                                            workspaceId: wsId,
                                            storeName:
                                                c['storeName'] as String,
                                            clientName:
                                                (c['clientName'] ?? '')
                                                    as String,
                                            phone: c['phone'] as String,
                                            initialAwaitingOwner: awaitingOwner,
                                          ),
                                        ),
                                      );
                                      _refresh();
                                    },
                                  ),
                                );
                              },
                            ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class AdminSupportChatDetailScreen extends StatefulWidget {
  final String workspaceId;
  final String storeName;
  final String clientName;
  final String phone;
  final bool initialAwaitingOwner;

  const AdminSupportChatDetailScreen({
    super.key,
    required this.workspaceId,
    required this.storeName,
    this.clientName = '',
    required this.phone,
    this.initialAwaitingOwner = false,
  });

  @override
  State<AdminSupportChatDetailScreen> createState() =>
      _AdminSupportChatDetailScreenState();
}

class _AdminSupportChatDetailScreenState
    extends State<AdminSupportChatDetailScreen> {
  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  List<SupportMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;
  bool _aiStreaming = false;
  String _streamingPreview = '';
  late bool _awaitingOwner = widget.initialAwaitingOwner;

  @override
  void initState() {
    super.initState();
    Rtdb.instance.markSupportChatRead(widget.workspaceId);
    _fetch(triggerAutoIfNeeded: true);
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _fetch({bool triggerAutoIfNeeded = false}) async {
    final list = await Rtdb.instance.getSupportMessages(widget.workspaceId);
    final hasEscalatedMsg =
        list.isNotEmpty && list.last.isEscalated;
    if (mounted) {
      final failedOptimistic = _messages
          .where((m) => m.hasError && m.id.startsWith('opt_'))
          .toList();
      setState(() {
        _messages = [...list, ...failedOptimistic];
        _loading = false;
        if (hasEscalatedMsg) {
          _awaitingOwner = true;
        }
      });
      _scrollToBottom();
    }

    // إذا كان الرد التلقائي مفعلاً وآخر رسالة من العميل ولم تُصعَّد بعد، يرد موظف الدعم الذكي تلقائياً
    if (triggerAutoIfNeeded &&
        Rtdb.instance.autoSupportEnabled &&
        DualPersonaAiEngine.instance.hasApiKey &&
        !_awaitingOwner &&
        list.isNotEmpty &&
        list.last.sender != 'admin') {
      await _generateAiSupportReply(list.last.text);
    }
  }

  Future<void> _generateAiSupportReply([String? customClientPrompt]) async {
    if (_aiStreaming || _sending) return;
    final apiKey = DualPersonaAiEngine.instance.apiKey;
    if (apiKey.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'يرجى إدخال مفتاح Gemini API (gemini_api_key) في شاشة الضبط لتفعيل خدمة الدعم الذكي.'),
          ),
        );
      }
      return;
    }

    // نحدد آخر رسالة للعميل للرد عليها
    String promptText = (customClientPrompt ?? '').trim();
    if (promptText.isEmpty) {
      for (final m in _messages.reversed) {
        if (m.sender != 'admin' && m.text.trim().isNotEmpty) {
          promptText = m.text.trim();
          break;
        }
      }
    }
    if (promptText.isEmpty) {
      promptText = _textCtrl.text.trim();
    }
    if (promptText.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا توجد رسالة عميل للرد عليها حالياً.')),
        );
      }
      return;
    }

    final session =
        DualPersonaAiEngine.instance.supportSessionFor(widget.workspaceId);
    // تغذية الجلسة بسياق المحادثة السابقة إن كانت فارغة
    if (session.history.isEmpty && _messages.length > 1) {
      final prior = _messages.take(_messages.length - 1).map((m) {
        return AiChatMessage(
          id: m.id,
          role: m.sender == 'admin' ? 'model' : 'user',
          text: m.text,
          timestamp: m.timestamp,
        );
      }).toList();
      session.seedHistory(prior);
    }

    setState(() {
      if (_messages.isNotEmpty && _messages.last.sender != 'admin') {
        _messages[_messages.length - 1] =
            _messages.last.copyWith(hasError: false, errorText: null);
      }
      _aiStreaming = true;
      _streamingPreview = '';
    });

    final buf = StringBuffer();
    try {
      await for (final chunk
          in session.sendMessageStream(promptText, apiKey: apiKey)) {
        buf.write(chunk);
        if (mounted) {
          setState(() {
            _streamingPreview = buf.toString();
          });
          _scrollToBottom();
        }
      }

      final finalReply = buf.toString().trim();
      if (finalReply.isNotEmpty) {
        final escalated = finalReply.contains('يدخل مدير المشروع بنفسه');
        await Rtdb.instance.sendSupportReply(
          widget.workspaceId,
          finalReply,
          isAutoSupport: true,
          escalatedOverride: escalated,
        );
        if (mounted) {
          setState(() {
            _awaitingOwner = escalated;
            _streamingPreview = '';
          });
        }
        await _fetch();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (_messages.isNotEmpty && _messages.last.sender != 'admin') {
            _messages[_messages.length - 1] =
                _messages.last.copyWith(hasError: true, errorText: '$e');
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _aiStreaming = false;
          _streamingPreview = '';
        });
      }
    }
  }

  Future<void> _escalateManually() async {
    if (_sending || _aiStreaming) return;
    setState(() => _sending = true);
    try {
      await Rtdb.instance.sendSupportReply(
        widget.workspaceId,
        kMandatoryEscalationText,
        isAutoSupport: true,
        escalatedOverride: true,
      );
      if (mounted) {
        setState(() => _awaitingOwner = true);
      }
      await _fetch();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _send([SupportMessage? retryMsg]) async {
    if (_sending || _aiStreaming) return;
    final String t = retryMsg != null ? retryMsg.text.trim() : _textCtrl.text.trim();
    if (t.isEmpty) return;

    late final SupportMessage targetMsg;
    if (retryMsg != null) {
      targetMsg = retryMsg.copyWith(hasError: false, errorText: null);
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == retryMsg.id);
        if (idx >= 0) {
          _messages[idx] = targetMsg;
        }
        _sending = true;
      });
    } else {
      final now = DateTime.now().millisecondsSinceEpoch;
      targetMsg = SupportMessage(
        id: 'opt_$now',
        sender: 'admin',
        text: t,
        timestamp: now,
        isAutoSupport: false,
        isEscalated: false,
      );
      // 1. العرض الفوري للرسالة (Optimistic Update) وتفريغ حقل الإدخال فوراً
      setState(() {
        _messages.add(targetMsg);
        _textCtrl.clear();
        _sending = true;
      });
      _scrollToBottom();
    }

    try {
      await Rtdb.instance.sendSupportReply(
        widget.workspaceId,
        t,
        isAutoSupport: false,
        escalatedOverride: false,
      );
      if (mounted) {
        setState(() => _awaitingOwner = false);
      }
      await _fetch();
    } catch (e) {
      // 2. معالجة الفشل دون فقدان البيانات: الاحتفاظ بالرسالة مع مؤشر أحمر وزر إعادة المحاولة
      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m.id == targetMsg.id);
          if (idx >= 0) {
            _messages[idx] = targetMsg.copyWith(
              hasError: true,
              errorText: '$e',
            );
          } else {
            _messages.add(
              targetMsg.copyWith(hasError: true, errorText: '$e'),
            );
          }
        });
        _scrollToBottom();
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    widget.storeName.isNotEmpty
                        ? widget.storeName
                        : widget.workspaceId,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_awaitingOwner) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFF59E0B)),
                    ),
                    child: const Text(
                      'بانتظار رد مدير المشروع',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF92400E),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            Text(
              [
                if (widget.clientName.isNotEmpty) widget.clientName,
                if (widget.phone.isNotEmpty) widget.phone,
              ].join(' • '),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'توليد رد الدعم الذكي (temperature: 0.2)',
            icon: const Icon(Icons.smart_toy_outlined, color: Color(0xFF0284C7)),
            onPressed: (_aiStreaming || _sending)
                ? null
                : () => _generateAiSupportReply(),
          ),
          IconButton(
            tooltip: 'تحويل وتصعيد لمدير المشروع',
            icon: const Icon(Icons.assignment_ind_outlined,
                color: Color(0xFFD97706)),
            onPressed: (_aiStreaming || _sending) ? null : _escalateManually,
          ),
          if (widget.phone.isNotEmpty)
            IconButton(
              tooltip: 'مراسلة عبر واتساب',
              icon: const Icon(Icons.chat_bubble_outline),
              onPressed: () => openWhatsApp(context, widget.phone),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_awaitingOwner)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: const BoxDecoration(
                color: Color(0xFFFEF3C7),
                border: Border(
                  bottom: BorderSide(color: Color(0xFFF59E0B)),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Color(0xFFD97706), size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'بانتظار رد مدير المشروع — تم تحويل هذه الحالة للمراجعة المباشرة',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF92400E),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await Rtdb.instance
                          .setSupportEscalation(widget.workspaceId, false);
                      if (mounted) setState(() => _awaitingOwner = false);
                    },
                    child: const Text('إنهاء التصعيد'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(14),
                    itemCount:
                        _messages.length + (_streamingPreview.isNotEmpty ? 1 : 0),
                    itemBuilder: (ctx, idx) {
                      if (idx == _messages.length) {
                        return Align(
                          alignment: Alignment.centerRight,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.of(context).size.width * 0.78,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0F766E),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'يكتب موظف الدعم الفني الآن...',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _streamingPreview,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      final m = _messages[idx];
                      final isMe = m.sender == 'admin';
                      final isEscalated = m.isEscalated;
                      return Align(
                        alignment:
                            isMe ? Alignment.centerRight : Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: isMe
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onLongPress: () =>
                                  copyText(context, 'نص الرسالة', m.text),
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 10),
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(context).size.width * 0.80,
                                ),
                                decoration: BoxDecoration(
                                  color: isMe
                                      ? (m.isAutoSupport
                                          ? const Color(0xFF0F766E)
                                          : const Color(0xFF0284C7))
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(14),
                                  border: m.hasError
                                      ? Border.all(
                                          color: const Color(0xFFDC2626),
                                          width: 1.5,
                                        )
                                      : (isMe
                                          ? null
                                          : Border.all(
                                              color: const Color(0xFFE2E8F0))),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          isMe
                                              ? (m.isAutoSupport
                                                  ? 'موظف الدعم الفني'
                                                  : 'مدير المشروع')
                                              : (widget.clientName.isNotEmpty
                                                  ? widget.clientName
                                                  : 'العميل'),
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w800,
                                            color: isMe
                                                ? Colors.white70
                                                : const Color(0xFF64748B),
                                          ),
                                        ),
                                        if (isEscalated) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 1.5),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFFEF3C7),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: const Text(
                                              'بانتظار رد مدير المشروع',
                                              style: TextStyle(
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.w900,
                                                color: Color(0xFF92400E),
                                              ),
                                            ),
                                          ),
                                        ],
                                        const SizedBox(width: 6),
                                        InkWell(
                                          onTap: () => copyText(
                                              context, 'نص الرسالة', m.text),
                                          child: Icon(
                                            Icons.copy_rounded,
                                            size: 12,
                                            color: isMe
                                                ? Colors.white60
                                                : Colors.black38,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        InkWell(
                                          onTap: () async {
                                            await Rtdb.instance
                                                .deleteSupportMessage(
                                                    widget.workspaceId, m.id);
                                            await _fetch();
                                          },
                                          child: Icon(
                                            Icons.close_rounded,
                                            size: 13,
                                            color: isMe
                                                ? Colors.white60
                                                : Colors.black38,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      m.text,
                                      style: TextStyle(
                                        color: isMe
                                            ? Colors.white
                                            : const Color(0xFF0B141A),
                                        fontSize: 16.5,
                                        fontWeight: FontWeight.w700,
                                        height: 1.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (m.hasError)
                              Padding(
                                padding: const EdgeInsets.only(
                                    top: 2, bottom: 6, right: 4, left: 4),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.error_outline_rounded,
                                      color: Color(0xFFDC2626),
                                      size: 15,
                                    ),
                                    const SizedBox(width: 4),
                                    const Text(
                                      'تعذر الإرسال',
                                      style: TextStyle(
                                        color: Color(0xFFDC2626),
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    TextButton.icon(
                                      style: TextButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 2),
                                        foregroundColor:
                                            const Color(0xFFDC2626),
                                        backgroundColor:
                                            const Color(0xFFFEE2E2),
                                      ),
                                      onPressed: (_sending || _aiStreaming)
                                          ? null
                                          : () => isMe
                                              ? _send(m)
                                              : _generateAiSupportReply(m.text),
                                      icon: const Icon(Icons.refresh_rounded,
                                          size: 14),
                                      label: const Text(
                                        'إعادة المحاولة',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'اكتب رد مدير المشروع مباشرةً...',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: (_sending || _aiStreaming) ? null : () => _send(),
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== ديوانية الرفيقين (Multi-Agent Chat: Gemini & Grok) ====================

class OwnerCompanionScreen extends StatefulWidget {
  /// مدة التأخير الزمني بين كل رسالة والرد من الطرف الآخر (6 ثوانٍ على الأقل افتراضياً).
  final Duration turnDelay;

  const OwnerCompanionScreen({
    super.key,
    this.turnDelay = kMinDiwaniyaTurnDelay,
  });
  @override
  State<OwnerCompanionScreen> createState() => _OwnerCompanionScreenState();
}

class _OwnerCompanionScreenState extends State<OwnerCompanionScreen> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final List<AiChatMessage> _messages = [];
  bool _streaming = false;
  bool _waitingNextTurn = false;
  String _activeStreamingAgent = 'gemini'; // 'gemini' | 'grok'
  String _liveChunkBuffer = '';
  int _orchestratorToken = 0;

  @override
  void initState() {
    super.initState();
    _messages.addAll(DualPersonaAiEngine.instance.ownerSession.history);
    adminRefreshTick.addListener(_onRefreshTick);
  }

  @override
  void dispose() {
    _orchestratorToken++;
    adminRefreshTick.removeListener(_onRefreshTick);
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onRefreshTick() {
    if (mounted) setState(() {});
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _openSettingsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _ConfigDialog(),
    );
    if (mounted) setState(() {});
  }

  /// زر الطوارئ الأحمر (Stop / Mute All): يقطع فوراً البث الجاري وينهي دورة الحوار ويلزم الصمت التام.
  void _emergencyStopAndMuteAll() {
    _orchestratorToken++;
    DualPersonaAiEngine.instance.muteAllAgents();
    if (mounted) {
      setState(() {
        _streaming = false;
        _waitingNextTurn = false;
        _liveChunkBuffer = '';
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
                '🛑 تم إيقاف البث فوراً وإلزام Gemini وGrok بالصمت التام.'),
            backgroundColor: Color(0xFFDC2626),
          ),
        );
    }
  }

  Future<void> _sendMessage([AiChatMessage? retryMessage]) async {
    final String text =
        retryMessage != null ? retryMessage.text.trim() : _inputCtrl.text.trim();
    if (text.isEmpty) return;

    // أي رسالة جديدة من المطور تقطع فوراً أي دورة سابقة جارية وتبدأ دورة جديدة
    final int myToken = ++_orchestratorToken;
    final engine = DualPersonaAiEngine.instance;
    final session = engine.ownerSession;
    late final AiChatMessage activeUserMsg;

    if (retryMessage != null) {
      // إعادة المحاولة لرسالة موجودة مسبقاً دون الحاجة لكتابتها مجدداً
      activeUserMsg = retryMessage.copyWith(hasError: false, errorText: null);
      session.updateMessageState(activeUserMsg.id,
          hasError: false, errorText: null);
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == activeUserMsg.id);
        if (idx >= 0) {
          _messages[idx] = activeUserMsg;
        } else {
          _messages.add(activeUserMsg);
        }
        _streaming = true;
        _waitingNextTurn = false;
        _liveChunkBuffer = '';
      });
    } else {
      // 1. العرض الفوري للرسالة (Optimistic Update) قبل انتظار رد الـ API
      final now = DateTime.now().millisecondsSinceEpoch;
      activeUserMsg = AiChatMessage(
        id: 'u_$now',
        role: 'user',
        text: text,
        timestamp: now,
      );
      session.addOptimisticMessage(activeUserMsg);
      setState(() {
        _messages.add(activeUserMsg);
        // تفريغ حقل الإدخال النصي فوراً بعد إدراج الرسالة في القائمة
        _inputCtrl.clear();
        _streaming = true;
        _waitingNextTurn = false;
        _liveChunkBuffer = '';
      });
    }
    _scrollToBottom();

    final turnSchedule = engine.buildDiwaniyaTurnSchedule(
      maxTotalReplies: kMaxDiwaniyaAutoReplies,
    );

    if (turnSchedule.isEmpty) {
      final String errMsg = (!engine.hasApiKey && !engine.hasGrokApiKey)
          ? 'يرجى إدخال مفتاح gemini_api_key أو grok_api_key عبر أيقونة الإعدادات (⚙️) لتفعيل الديوانية.'
          : 'الرفيقان في وضع الكتم حالياً. قم بإلغاء كتم Gemini أو Grok من شريط التحكم أعلى المحادثة.';
      session.updateMessageState(activeUserMsg.id,
          hasError: true, errorText: errMsg);
      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m.id == activeUserMsg.id);
          if (idx >= 0) {
            _messages[idx] =
                activeUserMsg.copyWith(hasError: true, errorText: errMsg);
          }
          _streaming = false;
          _waitingNextTurn = false;
          _liveChunkBuffer = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errMsg)),
        );
      }
      return;
    }

    int successfulTurns = 0;
    final Map<String, int> agentReplyCounts = <String, int>{
      'gemini': 0,
      'grok': 0,
    };
    Object? firstTurnError;

    try {
      for (int i = 0; i < turnSchedule.length; i++) {
        if (!mounted || _orchestratorToken != myToken) break;
        final agent = turnSchedule[i];

        // عند السكوت، كل ذكاء اصطناعي لديه رسالتان فقط ويتم التوقف حتى يتكلم صاحب التطبيق
        if ((agentReplyCounts[agent] ?? 0) >= kMaxRepliesPerAgentPerTurn) {
          continue;
        }

        // التحقق الفوري من عدم كتم الطرف أثناء الحوار
        if (agent == 'gemini' && !engine.isGeminiActiveInDiwaniya) continue;
        if (agent == 'grok' && !engine.isGrokActiveInDiwaniya) continue;

        // فاصل زمني إلزامي (6 ثوانٍ على الأقل افتراضياً) بين كل رسالة والرد من الطرف الآخر
        if (widget.turnDelay > Duration.zero) {
          if (mounted) {
            setState(() {
              _waitingNextTurn = true;
              _activeStreamingAgent = agent;
              _liveChunkBuffer = '';
            });
          }
          await Future<void>.delayed(widget.turnDelay);
          if (!mounted || _orchestratorToken != myToken) break;
          if (agent == 'gemini' && !engine.isGeminiActiveInDiwaniya) continue;
          if (agent == 'grok' && !engine.isGrokActiveInDiwaniya) continue;
        }

        if (mounted) {
          setState(() {
            _waitingNextTurn = false;
            _activeStreamingAgent = agent;
            _liveChunkBuffer = '';
          });
        }

        final buf = StringBuffer();
        try {
          final stream = agent == 'gemini'
              ? engine.streamGeminiDiwaniyaReply(_messages)
              : engine.streamGrokDiwaniyaReply(_messages);

          await for (final chunk in stream) {
            if (!mounted || _orchestratorToken != myToken) break;
            buf.write(chunk);
            setState(() {
              _liveChunkBuffer = buf.toString();
            });
            _scrollToBottom();
          }

          if (!mounted || _orchestratorToken != myToken) break;

          final finalReply = buf.toString().trim();
          if (finalReply.isNotEmpty) {
            final replyNow = DateTime.now().millisecondsSinceEpoch;
            final replyMsg = AiChatMessage(
              id: '${agent}_${replyNow}_$i',
              role: agent,
              text: finalReply,
              timestamp: replyNow,
            );
            session.addOptimisticMessage(replyMsg);
            setState(() {
              _messages.add(replyMsg);
              _liveChunkBuffer = '';
            });
            successfulTurns++;
            agentReplyCounts[agent] = (agentReplyCounts[agent] ?? 0) + 1;
            _scrollToBottom();
          }
        } catch (turnErr) {
          firstTurnError ??= turnErr;
        }
      }

      if (!mounted || _orchestratorToken != myToken) return;

      if (successfulTurns == 0) {
        final errStr =
            '${firstTurnError ?? 'تعذر الحصول على رد من خدمة الذكاء الاصطناعي.'}';
        session.updateMessageState(activeUserMsg.id,
            hasError: true, errorText: errStr);
        setState(() {
          final idx = _messages.indexWhere((m) => m.id == activeUserMsg.id);
          if (idx >= 0) {
            _messages[idx] =
                activeUserMsg.copyWith(hasError: true, errorText: errStr);
          } else {
            _messages.add(
              activeUserMsg.copyWith(hasError: true, errorText: errStr),
            );
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errStr), backgroundColor: Colors.red),
        );
        return;
      }

      // إذا اكتملت دورة النقاش الثنائية (3 إلى 4 ردود)، يتوقفان تلقائياً وتوضع عبارة ختامية لطيفة
      if (successfulTurns >= 3) {
        final sysNow = DateTime.now().millisecondsSinceEpoch;
        final closingMsg = AiChatMessage(
          id: 'sys_$sysNow',
          role: 'system',
          text: kDiwaniyaClosingNotice,
          timestamp: sysNow,
        );
        session.addOptimisticMessage(closingMsg);
        setState(() {
          _messages.add(closingMsg);
        });
      }
    } finally {
      if (mounted && _orchestratorToken == myToken) {
        setState(() {
          _streaming = false;
          _waitingNextTurn = false;
          _liveChunkBuffer = '';
        });
        _scrollToBottom();
      }
    }
  }

  void _clearSession() {
    _orchestratorToken++;
    DualPersonaAiEngine.instance.clearOwnerSession();
    setState(() {
      _messages.clear();
      _streaming = false;
      _waitingNextTurn = false;
      _liveChunkBuffer = '';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم تفريغ جلسة ديوانية الرفيقين بالكامل ✓')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final engine = DualPersonaAiEngine.instance;
    final hasGeminiKey = engine.hasApiKey || engine.hasOpenRouterApiKey;
    final hasGrokKey = engine.hasGrokApiKey || engine.hasOpenRouterApiKey;
    final history = _messages;

    return Column(
      children: [
        // 1) الشريط العلوي: عنوان الديوانية + أيقونة الترس (Dialog المفاتيح) + تفريغ الجلسة
        Container(
          margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0284C7).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.groups_3_rounded,
                    color: Color(0xFF0284C7), size: 22),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'رفيق المالك الشخصي (Owner Mode)',
                      style:
                          TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                    ),
                    Text(
                      'ديوانية الرفيقين الثلاثية: المطور • ✨ Gemini • ⚡ Grok',
                      style: TextStyle(fontSize: 11, color: Colors.black54),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'إعدادات مفاتيح الديوانية (gemini_api_key & grok_api_key)',
                icon: const Icon(Icons.settings_rounded,
                    color: Color(0xFF334155)),
                onPressed: _openSettingsDialog,
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: const Color(0xFFDC2626),
                  side: const BorderSide(color: Color(0xFFFCA5A5)),
                ),
                onPressed: _streaming ? null : _clearSession,
                icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                label: const Text('تفريغ الجلسة',
                    style:
                        TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),

        // 2) شريط أدوات التحكم الفوري والإسكات (Agent Controls: Mute Gemini, Mute Grok, Emergency Stop)
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // مفتاح كتم/تفعيل Gemini
              FilterChip(
                selected: !engine.geminiMuted && hasGeminiKey,
                onSelected: hasGeminiKey
                    ? (_) {
                        setState(() {
                          engine.geminiMuted = !engine.geminiMuted;
                        });
                      }
                    : null,
                avatar: Icon(
                  engine.geminiMuted || !hasGeminiKey
                      ? Icons.volume_off_rounded
                      : Icons.auto_awesome_rounded,
                  size: 16,
                  color: engine.geminiMuted || !hasGeminiKey
                      ? Colors.grey
                      : const Color(0xFF4F46E5),
                ),
                label: Text(
                  !hasGeminiKey
                      ? 'Gemini (بدون مفتاح)'
                      : (engine.geminiMuted ? 'كتم Gemini (مكتوم)' : 'كتم Gemini'),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: engine.geminiMuted || !hasGeminiKey
                        ? Colors.black54
                        : const Color(0xFF312E81),
                  ),
                ),
                selectedColor: const Color(0xFFEEF2FF),
                checkmarkColor: const Color(0xFF4F46E5),
              ),

              // مفتاح كتم/تفعيل Grok
              FilterChip(
                selected: !engine.grokMuted && hasGrokKey,
                onSelected: hasGrokKey
                    ? (_) {
                        setState(() {
                          engine.grokMuted = !engine.grokMuted;
                        });
                      }
                    : null,
                avatar: Icon(
                  engine.grokMuted || !hasGrokKey
                      ? Icons.volume_off_rounded
                      : Icons.bolt_rounded,
                  size: 16,
                  color: engine.grokMuted || !hasGrokKey
                      ? Colors.grey
                      : const Color(0xFF7E22CE),
                ),
                label: Text(
                  !hasGrokKey
                      ? 'Grok (بدون مفتاح)'
                      : (engine.grokMuted ? 'كتم Grok (مكتوم)' : 'كتم Grok'),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: engine.grokMuted || !hasGrokKey
                        ? Colors.black54
                        : const Color(0xFF581C87),
                  ),
                ),
                selectedColor: const Color(0xFFFAF5FF),
                checkmarkColor: const Color(0xFF7E22CE),
              ),

              // زر طوارئ أحمر واضح (Stop / Mute All)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDC2626),
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                ),
                onPressed: _emergencyStopAndMuteAll,
                icon: const Icon(Icons.stop_circle_outlined, size: 16),
                label: const Text(
                  'إيقاف / صمت تام',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        ),

        // 3) تنبيه لطيف غير معطل للتطبيق عند غياب أحد المفتاحين أو كليهما
        if (!hasGeminiKey || !hasGrokKey)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFF59E0B)),
            ),
            child: Row(
              children: [
                const Icon(Icons.vpn_key_off_rounded,
                    color: Color(0xFFD97706), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    (!hasGeminiKey && !hasGrokKey)
                        ? 'مفاتيح (gemini_api_key و grok_api_key) غير مضافة بعد — تم تعطيل الطرفين مؤقتاً لحين إدخال المفاتيح.'
                        : (!hasGeminiKey
                            ? 'مفتاح gemini_api_key غير مضاف (تم تعطيل Gemini تلقائياً، وGrok جاهز للرد).'
                            : 'مفتاح grok_api_key غير مضاف (تم تعطيل Grok تلقائياً، وGemini جاهز للرد).'),
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF92400E),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFD97706),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _openSettingsDialog,
                  child: const Text('إدخال المفتاح',
                      style: TextStyle(fontSize: 11.5)),
                ),
              ],
            ),
          ),

        // 4) قائمة الرسائل الواضحة والبارزة بتصميم يحاكي محادثة واتساب (المطور / Gemini / Grok / التوقف التلقائي)
        Expanded(
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xFFEFEAE2),
            ),
            child: (history.isEmpty && !_streaming)
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x14000000),
                              blurRadius: 8,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.nights_stay_rounded,
                                size: 46, color: Colors.teal.shade700),
                            const SizedBox(height: 10),
                            const Text(
                              'ديوانية الرفيقين: سهرتك مع Gemini وGrok! ☕✨⚡',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 16,
                                color: Color(0xFF0B141A),
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'أرسل رسالتك ليرد عليك Gemini بسخريته اللاذعة ويعقب عليه Grok بمرحه العفوي (بفاصل 6 ثوانٍ ورسالتين لكل رفيق ثم ينتظران مداخلتك).',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF334155),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    itemCount: history.length +
                        (_streaming &&
                                (_liveChunkBuffer.isNotEmpty ||
                                    _waitingNextTurn)
                            ? 1
                            : 0),
                    itemBuilder: (ctx, idx) {
                      if (idx == history.length) {
                        final isGrokTurn = _activeStreamingAgent == 'grok';
                        final accentColor = isGrokTurn
                            ? const Color(0xFF7E22CE)
                            : const Color(0xFF4F46E5);
                        final bgColor = isGrokTurn
                            ? const Color(0xFFFAF5FF)
                            : Colors.white;
                        final label = isGrokTurn
                            ? (_waitingNextTurn
                                ? '⏳ ⚡ Grok يستعد للتعقيب (فاصل 6 ثوانٍ)...'
                                : '⚡ Grok يكتب الآن...')
                            : (_waitingNextTurn
                                ? '⏳ ✨ Gemini يستعد للرد (فاصل 6 ثوانٍ)...'
                                : '✨ Gemini يكتب الآن...');
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.of(context).size.width * 0.85,
                            ),
                            decoration: BoxDecoration(
                              color: bgColor,
                              borderRadius: BorderRadius.circular(16),
                              border:
                                  Border.all(color: accentColor, width: 1.5),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x18000000),
                                  blurRadius: 5,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w900,
                                    color: accentColor,
                                  ),
                                ),
                                if (_liveChunkBuffer.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    _liveChunkBuffer,
                                    style: const TextStyle(
                                      fontSize: 17.0,
                                      fontWeight: FontWeight.w700,
                                      height: 1.55,
                                      color: Color(0xFF0B141A),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      }

                      final m = history[idx];

                      // عبارة ختامية لطيفة بانتظار عودة المطور بعد اكتمال رسالتين لكل ذكاء اصطناعي
                      if (m.isSystem) {
                        return Center(
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 10),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 9),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEF3C7),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: const Color(0xFFF59E0B), width: 1.3),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x14000000),
                                  blurRadius: 4,
                                  offset: Offset(0, 1.5),
                                ),
                              ],
                            ),
                            child: Text(
                              m.text,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 13.0,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF92400E),
                              ),
                            ),
                          ),
                        );
                      }

                      final isUser = m.isUser;
                      final isGrok = m.isGrok;
                      // فقاعات واضحة وبارزة بأسلوب واتساب (أخضر فاتح للمطور مع نص داكن بارز، وأبيض ناصع للرفيقين)
                      final Color bubbleBg = isUser
                          ? const Color(0xFFD9FDD3)
                          : (isGrok
                              ? const Color(0xFFFAF5FF)
                              : Colors.white);
                      final Color borderCol = isUser
                          ? const Color(0xFF4ADE80)
                          : (isGrok
                              ? const Color(0xFF9333EA)
                              : const Color(0xFF6366F1));
                      final Color headerColor = isUser
                          ? const Color(0xFF005C4B)
                          : (isGrok
                              ? const Color(0xFF6B21A8)
                              : const Color(0xFF3730A3));
                      final IconData senderIcon = isUser
                          ? Icons.person_rounded
                          : (isGrok
                              ? Icons.bolt_rounded
                              : Icons.auto_awesome_rounded);
                      final String senderLabel = isUser
                          ? '👨‍💻 أنت (المطور المالك)'
                          : (isGrok
                              ? '⚡ Grok • رفيق السهرة'
                              : '✨ Gemini • مهندس الأنظمة');
                      final DateTime msgTime =
                          DateTime.fromMillisecondsSinceEpoch(m.timestamp);
                      final String timeStr =
                          '${msgTime.hour.toString().padLeft(2, '0')}:${msgTime.minute.toString().padLeft(2, '0')}';

                      return Align(
                        alignment: isUser
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: isUser
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onLongPress: () =>
                                  copyText(context, 'نص الرسالة', m.text),
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 6),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 12),
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(context).size.width * 0.85,
                                ),
                                decoration: BoxDecoration(
                                  color: bubbleBg,
                                  borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(16),
                                    topRight: const Radius.circular(16),
                                    bottomLeft:
                                        Radius.circular(isUser ? 16 : 4),
                                    bottomRight:
                                        Radius.circular(isUser ? 4 : 16),
                                  ),
                                  border: m.hasError
                                      ? Border.all(
                                          color: const Color(0xFFDC2626),
                                          width: 1.8,
                                        )
                                      : Border.all(
                                          color: borderCol,
                                          width: 1.2,
                                        ),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Color(0x18000000),
                                      blurRadius: 4,
                                      offset: Offset(0, 1.5),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          senderIcon,
                                          size: 15,
                                          color: headerColor,
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          senderLabel,
                                          style: TextStyle(
                                            fontSize: 12.0,
                                            fontWeight: FontWeight.w900,
                                            color: headerColor,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        InkWell(
                                          onTap: () => copyText(
                                              context, 'نص الرسالة', m.text),
                                          child: const Icon(
                                            Icons.copy_rounded,
                                            size: 14,
                                            color: Colors.black45,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      m.text,
                                      style: const TextStyle(
                                        color: Color(0xFF0B141A),
                                        fontSize: 17.0,
                                        fontWeight: FontWeight.w700,
                                        height: 1.55,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          timeStr,
                                          style: const TextStyle(
                                            fontSize: 11.0,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF475569),
                                          ),
                                        ),
                                        if (isUser) ...[
                                          const SizedBox(width: 4),
                                          Icon(
                                            m.hasError
                                                ? Icons.error_outline_rounded
                                                : Icons.done_all_rounded,
                                            size: 15,
                                            color: m.hasError
                                                ? const Color(0xFFDC2626)
                                                : const Color(0xFF0284C7),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (m.hasError)
                              Padding(
                                padding: const EdgeInsets.only(
                                    top: 2, bottom: 6, right: 4, left: 4),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.error_outline_rounded,
                                      color: Color(0xFFDC2626),
                                      size: 15,
                                    ),
                                    const SizedBox(width: 4),
                                    const Text(
                                      'تعذر الإرسال',
                                      style: TextStyle(
                                        color: Color(0xFFDC2626),
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    TextButton.icon(
                                      style: TextButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 2),
                                        foregroundColor:
                                            const Color(0xFFDC2626),
                                        backgroundColor:
                                            const Color(0xFFFEE2E2),
                                      ),
                                      onPressed: _streaming
                                          ? null
                                          : () => _sendMessage(m),
                                      icon: const Icon(Icons.refresh_rounded,
                                          size: 14),
                                      label: const Text(
                                        'إعادة المحاولة',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),

        // 5) مجال كتابة مرن متعدد الأسطر مع بث حي
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    decoration: const InputDecoration(
                      hintText:
                          'اكتب رسالتك لـ Gemini وGrok في الديوانية...',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7),
                  ),
                  onPressed: () => _sendMessage(),
                  icon: _streaming
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ==================== مركز التحكم السحابي وإعدادات النظام ====================

class SystemControlScreen extends StatefulWidget {
  const SystemControlScreen({super.key});
  @override
  State<SystemControlScreen> createState() => _SystemControlScreenState();
}

class _SystemControlScreenState extends State<SystemControlScreen> {
  final _bcastTitle = TextEditingController();
  final _bcastBody = TextEditingController();
  final _maintMsg = TextEditingController();
  final _minBuildCtrl = TextEditingController(text: '162');
  final _minVerCtrl = TextEditingController(text: '3.81.0');
  late final _geminiKeyCtrl =
      TextEditingController(text: Rtdb.instance.geminiApiKey);
  bool _obscureGeminiKey = true;

  bool _maintActive = false;
  int _retentionDays = 7;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadSystemSettings();
    adminRefreshTick.addListener(_onTick);
  }

  @override
  void dispose() {
    adminRefreshTick.removeListener(_onTick);
    _bcastTitle.dispose();
    _bcastBody.dispose();
    _maintMsg.dispose();
    _minBuildCtrl.dispose();
    _minVerCtrl.dispose();
    _geminiKeyCtrl.dispose();
    super.dispose();
  }

  void _onTick() {
    if (mounted) {
      setState(() {
        _geminiKeyCtrl.text = Rtdb.instance.geminiApiKey;
      });
    }
  }

  Future<void> _loadSystemSettings() async {
    try {
      final maint = await Rtdb.instance.getMaintenanceMode();
      if (maint != null && mounted) {
        setState(() {
          _maintActive = maint['is_active'] == true;
          _maintMsg.text = '${maint['message'] ?? ''}';
        });
      }
    } catch (_) {}

    try {
      final policy = await Rtdb.instance.getForceUpdatePolicy();
      if (policy != null && mounted) {
        setState(() {
          _minBuildCtrl.text = '${policy['min_build'] ?? '162'}';
          _minVerCtrl.text = '${policy['min_version'] ?? '3.81.0'}';
        });
      }
    } catch (_) {}

    try {
      final ret = await Rtdb.instance.getGroupChatRetentionDays();
      if (mounted) setState(() => _retentionDays = ret);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        const AdminSelfUpdateCard(),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.psychology_alt_rounded, color: Color(0xFF0284C7)),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '🤖 إعدادات الذكاء الاصطناعي ثنائي النمط (gemini_api_key)',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'يُحفظ المفتاح محلياً في SharedPreferences تحت الاسم gemini_api_key لتهيئة نمط رفيق المالك (0.9) ونمط الدعم الفني (0.2).',
                  style: TextStyle(fontSize: 11.5, color: Colors.black54),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _geminiKeyCtrl,
                  obscureText: _obscureGeminiKey,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: 'مفتاح Gemini API (gemini_api_key)',
                    hintText: 'AIzaSy...',
                    prefixIcon: const Icon(Icons.vpn_key_outlined),
                    suffixIcon: IconButton(
                      icon: Icon(_obscureGeminiKey
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () => setState(
                          () => _obscureGeminiKey = !_obscureGeminiKey),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: () async {
                    await Rtdb.instance
                        .saveGeminiApiKey(_geminiKeyCtrl.text.trim());
                    adminRefreshTick.value++;
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'تم حفظ مفتاح gemini_api_key محلياً وتفعيل النمطين بنجاح ✓'),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.save_outlined, size: 16),
                  label: const Text('حفظ مفتاح الذكاء الاصطناعي'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.campaign_rounded, color: Color(0xFF7C3AED)),
                    SizedBox(width: 8),
                    Text('📢 إرسال تنبيه جماعي شامل (Broadcast Alert)',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _bcastTitle,
                  decoration: const InputDecoration(labelText: 'عنوان التنبيه'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _bcastBody,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'نص التنبيه لكافة العملاء'),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          final t = _bcastTitle.text.trim();
                          final b = _bcastBody.text.trim();
                          if (t.isEmpty || b.isEmpty) return;
                          setState(() => _busy = true);
                          await Rtdb.instance.sendBroadcastNotification(title: t, body: b);
                          _bcastTitle.clear();
                          _bcastBody.clear();
                          setState(() => _busy = false);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('تم بث التنبيه لجميع العملاء بنجاح ✓')),
                            );
                          }
                        },
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: const Text('بث التنبيه لجميع الأجهزة'),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 10),

        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.engineering_rounded, color: Colors.orange),
                    SizedBox(width: 8),
                    Text('🛑 وضع الصيانة السحابي (Maintenance Mode)',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
                SwitchListTile(
                  title: const Text('تفعيل وضع الصيانة'),
                  subtitle: const Text('تعطيل المزامنة مؤقتاً للجميع أثناء ترقية الخوادم'),
                  value: _maintActive,
                  onChanged: (v) => setState(() => _maintActive = v),
                ),
                TextField(
                  controller: _maintMsg,
                  decoration: const InputDecoration(labelText: 'رسالة الصيانة التوضيحية'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () async {
                    await Rtdb.instance.setMaintenanceMode(
                      active: _maintActive,
                      message: _maintMsg.text.trim(),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('تم تحديث وضع الصيانة بالسحابة ✓')),
                      );
                    }
                  },
                  child: const Text('حفظ إعداد وضع الصيانة'),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 10),

        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.system_update_alt_rounded, color: Colors.blue),
                    SizedBox(width: 8),
                    Text('🚀 فرض التحديث الإجباري (Force Update)',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _minBuildCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'الحد الأدنى لرقم البناء (Build)'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _minVerCtrl,
                        decoration: const InputDecoration(labelText: 'رقم الإصدار (Version)'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () async {
                    final b = int.tryParse(_minBuildCtrl.text.trim()) ?? 162;
                    await Rtdb.instance.setForceUpdateMinVersion(b, _minVerCtrl.text.trim());
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('تم تطبيق سياسة التحديث الإجباري ✓')),
                      );
                    }
                  },
                  child: const Text('حفظ سياسة التحديث الإجباري'),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 10),

        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.auto_delete_rounded, color: Colors.red),
                    SizedBox(width: 8),
                    Text('⏱️ فترة بقاء رسائل المجموعات (Retention & Purge)',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  value: _retentionDays,
                  decoration: const InputDecoration(labelText: 'مهلة صلاحية وبقاء الرسائل'),
                  items: const [
                    DropdownMenuItem(value: 3, child: Text('3 أيام')),
                    DropdownMenuItem(value: 7, child: Text('أسبوع واحد (7 أيام)')),
                    DropdownMenuItem(value: 30, child: Text('شهر واحد (30 يوماً)')),
                  ],
                  onChanged: (v) => setState(() => _retentionDays = v ?? 7),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          await Rtdb.instance.setGroupChatRetentionDays(_retentionDays);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('تم حفظ فترة البقاء ✓')),
                            );
                          }
                        },
                        child: const Text('حفظ السياسة'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: () async {
                          final count = await Rtdb.instance.purgeOldGroupChatMessages(_retentionDays);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('تم تنظيف $count عملية ورسالة قديمة من السحابة ✓')),
                            );
                          }
                        },
                        child: const Text('تنظيف فوري الآن'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
