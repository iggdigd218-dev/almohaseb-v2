// معالج الاستعادة الذكي متعدد الصفحات — (يستبدل مسار الحزمة اليدوية R-01/R-06)
//
// الصفحات:
//   1) تحديد الحساب (بريد أو رقم هاتف) والتحقق من وجود المنشأة في الفهارس.
//   2) سؤال «آخر كلمة مرور تتذكرها» → يُقارن ببصمات المنشأة الحالية/السابقة.
//   3) أسئلة الملكية: اسم المنشأة + النشاط/التواصل.
//   4) تسجيل كلمة مرور جديدة (بعد اجتياز التقييم) ثم الدخول بها.
//
// التقييم يجري في الخلفية بين الصفحات عبر `RecoveryScorer` (محلي داخل
// التطبيق، لا يُرسل أي إجابة إلى أي خدمة خارجية).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_error_mapper.dart';
import '../core/sfx.dart';
import '../data/providers.dart';
import '../data/sync/account_workspace.dart';
import '../data/sync/recovery_wizard_logic.dart';
import '../core/cloud_config.dart';

class RecoveryWizardScreen extends ConsumerStatefulWidget {
  const RecoveryWizardScreen({
    super.key,
    this.initialIdentifier = '',
    this.countryDialCode = '+967',
  });

  final String initialIdentifier;
  final String countryDialCode;

  @override
  ConsumerState<RecoveryWizardScreen> createState() =>
      _RecoveryWizardScreenState();
}

class _RecoveryWizardScreenState extends ConsumerState<RecoveryWizardScreen> {
  static const int kSteps = 4;

  final _identifierCtrl = TextEditingController();
  final _lastPasswordCtrl = TextEditingController();
  final _storeNameCtrl = TextEditingController();
  final _activityCtrl = TextEditingController();
  final _newPasswordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();

  int _step = 0;
  bool _busy = false;
  String? _error;
  String _backendUrl = '';

  RecoveryTargetSnapshot _target = RecoveryTargetSnapshot.missing;
  double _passwordMatch = 0;
  RecoveryAssessment _assessment = RecoveryAssessment.empty;
  bool _passwordSaved = false;

  @override
  void initState() {
    super.initState();
    _identifierCtrl.text = widget.initialIdentifier;
  }

  @override
  void dispose() {
    for (final c in [
      _identifierCtrl,
      _lastPasswordCtrl,
      _storeNameCtrl,
      _activityCtrl,
      _newPasswordCtrl,
      _confirmPasswordCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<String> _resolveBackend() async {
    if (_backendUrl.isNotEmpty) return _backendUrl;
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      _backendUrl = effectiveBackendUrl(st['cloudBackendUrl']);
    } catch (_) {}
    return _backendUrl;
  }


  bool _identifierValid(String v) {
    final s = v.trim();
    if (s.contains('@')) return s.contains('.');
    return s.replaceAll(RegExp(r'[^0-9]'), '').length >= 7;
  }

  // ── الصفحة 1: تحديد الحساب ──
  Future<void> _submitIdentifier() async {
    final raw = _identifierCtrl.text.trim();
    if (!_identifierValid(raw)) {
      setState(() => _error =
          'أدخل بريدًا إلكترونيًا صحيحًا أو رقم هاتف مسجل (7 أرقام على الأقل)');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final url = await _resolveBackend();
      if (url.isEmpty) {
        setState(() {
          _busy = false;
          _error = 'لا يوجد اتصال سحابي مُهيّأ — يلزم الاتصال للتحقق من الحساب.';
        });
        return;
      }
      final target = await AccountWorkspace.resolveRecoveryTarget(
        backendUrl: url,
        identifier: raw,
        countryDialCode: widget.countryDialCode,
      );
      if (!mounted) return;
      if (!target.exists) {
        setState(() {
          _busy = false;
          _error = 'لم نجد منشأة مرتبطة بهذا المعرّف. تحقق من البريد/الرقم '
              'أو تواصل مع الدعم.';
        });
        Sfx.error();
        return;
      }
      Sfx.success();
      setState(() {
        _busy = false;
        _target = target;
        _step = 1;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppErrorMapper.toUserFriendlyMessage(e);
      });
    }
  }

  // ── الصفحة 2: آخر كلمة مرور ──
  Future<void> _submitPasswordRecall() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final url = await _resolveBackend();
      _passwordMatch = await AccountWorkspace.passwordRecallScore(
        backendUrl: url,
        workspaceId: _target.workspaceId,
        candidate: _lastPasswordCtrl.text,
      );
      // تقييم مبدئي في الخلفية بين الصفحات.
      _assessment = RecoveryScorer.assess(
        target: _target,
        answers: RecoveryAnswers(lastPassword: _lastPasswordCtrl.text),
        passwordMatch: _passwordMatch,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = 2;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppErrorMapper.toUserFriendlyMessage(e);
      });
    }
  }

  // ── الصفحة 3: أسئلة الملكية ──
  Future<void> _submitOwnershipAnswers() async {
    final answers = RecoveryAnswers(
      lastPassword: _lastPasswordCtrl.text,
      storeName: _storeNameCtrl.text,
      activity: _activityCtrl.text,
      contact: _target.phone,
    );
    final assessment = RecoveryScorer.assess(
      target: _target,
      answers: answers,
      passwordMatch: _passwordMatch,
    );
    setState(() => _busy = true);
    // إعطاء إحساس بالتقييم الخلفي دون تعطيل الواجهة.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    setState(() {
      _assessment = assessment;
      _busy = false;
      _step = 3;
    });
    if (assessment.passed) {
      Sfx.success();
    } else {
      Sfx.error();
    }
  }

  // ── الصفحة 4: كلمة مرور جديدة ──
  Future<void> _saveNewPassword() async {
    final pass = _newPasswordCtrl.text.trim();
    final confirm = _confirmPasswordCtrl.text.trim();
    if (pass.length < 6) {
      setState(() => _error = 'كلمة المرور يجب أن تكون 6 أحرف على الأقل');
      return;
    }
    if (pass != confirm) {
      setState(() => _error = 'كلمتا المرور غير متطابقتين');
      return;
    }
    if (!_assessment.passed) {
      setState(() => _error = 'لم يجتز التحقق — استخدم الدعم الفني.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final url = await _resolveBackend();
      final ok = await AccountWorkspace.applyRecoveredPassword(
        backendUrl: url,
        workspaceId: _target.workspaceId,
        newPassword: pass,
        confidenceScore: _assessment.score,
        phone: _target.phone,
        email: _target.ownerEmail,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _passwordSaved = ok;
        _error = ok ? null : 'تعذّر حفظ كلمة المرور — تحقق من الاتصال وأعد المحاولة.';
      });
      if (ok) {
        Sfx.success();
      } else {
        Sfx.error();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppErrorMapper.toUserFriendlyMessage(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('استعادة الحساب'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_step > 0 && !_busy) {
              setState(() {
                _step -= 1;
                _error = null;
              });
            } else {
              Navigator.of(context).maybePop();
            }
          },
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _progress(theme),
                const SizedBox(height: 18),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: _stepBody(theme),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error, height: 1.5),
                  ),
                ],
                if (_assessment.score > 0) ...[
                  const SizedBox(height: 14),
                  _scoreCard(theme),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _progress(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'الخطوة ${_step + 1} من $kSteps',
          style: theme.textTheme.labelMedium,
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: (_step + 1) / kSteps, minHeight: 6),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool password = false,
    TextInputType? type,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: controller,
        obscureText: password,
        keyboardType: type,
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _stepBody(ThemeData theme) {
    switch (_step) {
      case 0:
        return Column(
          key: const ValueKey('step0'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('١) تحديد الحساب', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('أدخل البريد الإلكتروني أو رقم الهاتف المسجل للمنشأة.'),
            const SizedBox(height: 16),
            _field(
              controller: _identifierCtrl,
              label: 'البريد الإلكتروني أو رقم الهاتف',
              hint: 'name@example.com أو 77xxxxxxx',
            ),
            FilledButton(
              onPressed: _busy ? null : _submitIdentifier,
              child: Text(_busy ? 'جارٍ التحقق…' : 'تحقق من الحساب'),
            ),
          ],
        );

      case 1:
        return Column(
          key: const ValueKey('step1'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('٢) التحقق الأول', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('المنشأة: ${_target.storeName.isEmpty ? _target.workspaceId : _target.storeName}',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            const Text(
              'ما هي آخر كلمة مرور تتذكرها لهذا الحساب؟ '
              '(أو أقرب كلمة كنت تستخدمها)',
            ),
            const SizedBox(height: 16),
            _field(
              controller: _lastPasswordCtrl,
              label: 'آخر كلمة مرور تتذكرها',
              password: true,
            ),
            Row(
              children: [
                TextButton(
                  onPressed: _busy ? null : () => setState(() {
                        _passwordMatch = 0;
                        _step = 2;
                      }),
                  child: const Text('لا أتذكرها'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _busy ? null : _submitPasswordRecall,
                  child: Text(_busy ? 'جارٍ التقييم…' : 'التالي'),
                ),
              ],
            ),
          ],
        );

      case 2:
        return Column(
          key: const ValueKey('step2'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('٣) التحقق الثاني — أسئلة الملكية',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('أجب عن أسئلة المنشأة بدقة، تُقارن ببياناتك السحابية.'),
            const SizedBox(height: 16),
            _field(
              controller: _storeNameCtrl,
              label: 'ما اسم منشأتك المسجل في التطبيق؟',
            ),
            _field(
              controller: _activityCtrl,
              label: 'ما نشاط المنشأة أو عنوانها المسجل؟',
            ),
            FilledButton(
              onPressed: _busy ? null : _submitOwnershipAnswers,
              child: Text(_busy ? 'جارٍ التقييم الذكي…' : 'تحقق'),
            ),
          ],
        );

      default:
        return Column(
          key: const ValueKey('step3'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _assessment.passed ? '٤) كلمة مرور جديدة' : 'تعذّر التحقق',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (!_assessment.passed)
              const Text(
                'لم تتطابق الإجابات بما يكفي لاستعادة الحساب. '
                'يمكنك المحاولة مرة أخرى بدقة أكبر، أو التواصل مع الدعم الفني.',
              ),
            if (_assessment.passed && !_passwordSaved) ...[
              _field(
                controller: _newPasswordCtrl,
                label: 'كلمة المرور الجديدة',
                password: true,
              ),
              _field(
                controller: _confirmPasswordCtrl,
                label: 'تأكيد كلمة المرور',
                password: true,
              ),
              FilledButton(
                onPressed: _busy ? null : _saveNewPassword,
                child: Text(_busy ? 'جارٍ الحفظ…' : 'حفظ وتفعيل الدخول'),
              ),
            ],
            if (_passwordSaved) ...[
              Icon(Icons.check_circle,
                  size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 10),
              const Text(
                'تم تعيين كلمة المرور الجديدة بنجاح. '
                'يمكنك الآن تسجيل الدخول بها من شاشة الدخول.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).maybePop(true),
                child: const Text('الانتقال إلى تسجيل الدخول'),
              ),
            ],
            if (!_assessment.passed)
              OutlinedButton(
                onPressed: () => setState(() {
                  _step = 1;
                  _error = null;
                }),
                child: const Text('إعادة المحاولة'),
              ),
          ],
        );
    }
  }

  Widget _scoreCard(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _assessment.passed
                      ? Icons.verified_user
                      : Icons.shield_outlined,
                  size: 18,
                  color: _assessment.passed
                      ? Colors.green
                      : theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Text(
                  'درجة الموثوقية: ${_assessment.score.toStringAsFixed(0)}/100',
                  style: theme.textTheme.labelLarge,
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final s in _assessment.signals)
              Text('• $s', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
