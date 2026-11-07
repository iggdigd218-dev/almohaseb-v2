// منطق معالج الاستعادة متعدد الصفحات — نقي وقابل للاختبار (بلا شبكة أو واجهة).
//
// التقييم يجري في الخلفية بين الصفحات: كل إجابة تُحسِّن درجة الموثوقية،
// ولا يُسمح بحفظ كلمة مرور جديدة إلا بعد اجتياز الحد الأدنى.
import 'dart:math' as math;

/// بيانات المنشأة المستهدفة كما تُقرأ من السحابة (بلا أي بصمة كلمات مرور).
class RecoveryTargetSnapshot {
  const RecoveryTargetSnapshot({
    required this.workspaceId,
    this.storeName = '',
    this.activity = '',
    this.phone = '',
    this.ownerEmail = '',
    this.exists = true,
  });

  final String workspaceId;
  final String storeName;
  final String activity;
  final String phone;
  final String ownerEmail;
  final bool exists;

  static const RecoveryTargetSnapshot missing = RecoveryTargetSnapshot(
    workspaceId: '',
    exists: false,
  );
}

/// إجابات المستخدم في المعالج.
class RecoveryAnswers {
  const RecoveryAnswers({
    this.lastPassword = '',
    this.storeName = '',
    this.activity = '',
    this.contact = '',
  });

  final String lastPassword;
  final String storeName;
  final String activity;
  final String contact;

  RecoveryAnswers copyWith({
    String? lastPassword,
    String? storeName,
    String? activity,
    String? contact,
  }) =>
      RecoveryAnswers(
        lastPassword: lastPassword ?? this.lastPassword,
        storeName: storeName ?? this.storeName,
        activity: activity ?? this.activity,
        contact: contact ?? this.contact,
      );
}

/// نتيجة التقييم.
class RecoveryAssessment {
  const RecoveryAssessment({
    required this.score,
    required this.passed,
    required this.signals,
  });

  final double score;
  final bool passed;
  final List<String> signals;

  static const RecoveryAssessment empty =
      RecoveryAssessment(score: 0, passed: false, signals: <String>[]);
}

/// محرّك التقييم — أوزان صريحة وثابتة (لا صناديق سوداء).
class RecoveryScorer {
  RecoveryScorer._();

  static const double passwordWeight = 55;
  static const double storeNameWeight = 25;
  static const double activityWeight = 12;
  static const double contactWeight = 8;
  static const double passThreshold = 60;

  /// [passwordMatch] بين 0 و1: 1 = تطابق تام مع بصمة حالية/سابقة.
  static RecoveryAssessment assess({
    required RecoveryTargetSnapshot target,
    required RecoveryAnswers answers,
    required double passwordMatch,
  }) {
    final signals = <String>[];
    if (!target.exists || target.workspaceId.isEmpty) {
      return const RecoveryAssessment(
        score: 0,
        passed: false,
        signals: <String>['لم يتم تحديد المنشأة'],
      );
    }

    final p = passwordMatch.clamp(0.0, 1.0);
    final nameSim = similarity(answers.storeName, target.storeName);
    final actSim = similarity(answers.activity, target.activity);
    final contactSim = math.max(
      similarity(answers.contact, target.phone),
      similarity(digitsOnly(answers.contact), digitsOnly(target.phone)),
    );

    var score = p * passwordWeight +
        nameSim * storeNameWeight +
        actSim * activityWeight +
        contactSim * contactWeight;

    // لا اجتياز بلا إشارة قوية واحدة على الأقل:
    //   • كلمة مرور تطابق بصمة معتمدة، أو
    //   • اسم منشأة مطابق تمامًا (يُثبت معرفة داخلية بالمنشأة).
    final strongSignal = p >= 0.99 || nameSim >= 0.85;
    if (strongSignal) {
      score = math.max(score, passThreshold + 2);
    } else {
      score = math.min(score, passThreshold - 1);
    }

    if (p >= 0.99) {
      signals.add('كلمة المرور تطابق بصمة معتمدة سابقة');
    } else if (p > 0) {
      signals.add('كلمة المرور قريبة من بصمة معتمدة');
    }
    if (nameSim >= 0.85) {
      signals.add('اسم المنشأة مطابق');
    } else if (nameSim >= 0.5) {
      signals.add('اسم المنشأة متقارب');
    }
    if (actSim >= 0.7) signals.add('نشاط المنشأة مطابق');
    if (contactSim >= 0.7) signals.add('بيانات التواصل مطابقة');
    if (signals.isEmpty) {
      signals.add('لا توجد إشارة موثوقة كافية');
    }

    final rounded = double.parse(score.toStringAsFixed(1));
    return RecoveryAssessment(
      score: rounded,
      passed: rounded >= passThreshold,
      signals: List<String>.unmodifiable(signals),
    );
  }

  /// تطبيع عربي: إزالة التشكيل وتوحيد الألف/الياء/التاء المربوطة والمسافات.
  static String normalizeArabic(String s) {
    var out = s.trim().toLowerCase();
    out = out.replaceAll(RegExp(r'[\u064B-\u0652\u0670]'), '');
    out = out.replaceAll(RegExp('[أإآٱ]'), 'ا');
    out = out.replaceAll('ى', 'ي');
    out = out.replaceAll('ة', 'ه');
    out = out.replaceAll(RegExp(r'\s+'), ' ');
    return out;
  }

  static String digitsOnly(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

  /// تشابه 0..1 بين نصين (Levenshtein مطبَّع + احتواء).
  static double similarity(String a, String b) {
    final x = normalizeArabic(a);
    final y = normalizeArabic(b);
    if (x.isEmpty || y.isEmpty) return 0;
    if (x == y) return 1;
    if (x.contains(y) || y.contains(x)) {
      final shorter = math.min(x.length, y.length);
      final longer = math.max(x.length, y.length);
      return 0.85 + 0.15 * (shorter / longer);
    }
    final dist = _levenshtein(x, y);
    return (1 - dist / math.max(x.length, y.length)).clamp(0.0, 1.0);
  }

  static int _levenshtein(String a, String b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    var cur = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        cur[j] = math.min(
          math.min(cur[j - 1] + 1, prev[j] + 1),
          prev[j - 1] + cost,
        );
      }
      final tmp = prev;
      prev = cur;
      cur = tmp;
    }
    return prev[b.length];
  }
}
