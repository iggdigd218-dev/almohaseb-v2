import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme.dart';

/// (3.98.34) إشعار دوري غير مزعج لإكمال بيانات الحساب الناقصة (هاتف/بريد
/// الاسترداد). يُظهر حواراً عربياً مختصراً بحد أقصى مرة كل يومين على الجهاز،
/// معتمداً على طابع زمني محلي محفوظ في SharedPreferences — فلا يظهر في كل
/// فتح للتطبيق، ويُحترم زر «لاحقاً».
class ProfileCompletionNudge {
  ProfileCompletionNudge._();

  /// مفتاح آخر ظهور محلياً (millisecondsSinceEpoch بالتوقيت المحلي للجهاز).
  static const prefsKey = 'profileNudge.lastShownAt';

  /// أقل مدة بين إشعارين: يومان (الطلب: كل 2–3 أيام كحد أقصى).
  static const interval = Duration(days: 2);

  /// يعيد `true` إذا عرض الحوار فعلاً (للاستخدام في الاختبارات).
  static Future<bool> maybeShow(
    BuildContext context, {
    required String phone,
    required String email,
    required VoidCallback onOpenSettings,
    DateTime? now,
  }) async {
    final hasPhone = phone.trim().isNotEmpty;
    final hasEmail = email.trim().isNotEmpty;
    // البيانات مكتملة ← لا إشعار إطلاقاً (ولا كتابة طابع زمني).
    if (hasPhone && hasEmail) return false;

    final prefs = await SharedPreferences.getInstance();
    final stamp = prefs.getInt(prefsKey) ?? 0;
    final current = now ?? DateTime.now();
    if (stamp > 0) {
      final last = DateTime.fromMillisecondsSinceEpoch(stamp);
      if (current.difference(last) < interval) return false;
    }
    // يُسجَّل الطابع فور العرض حتى لو أُغلقت النافذة بالسحب أو بزر الرجوع.
    await prefs.setInt(prefsKey, current.millisecondsSinceEpoch);

    if (!context.mounted) return false;

    final missing = !hasPhone && !hasEmail
        ? 'رقم الهاتف وبريد الاسترداد'
        : (!hasPhone ? 'رقم الهاتف' : 'بريد الاسترداد');

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          Icons.verified_user_outlined,
          color: AppColors.primaryOf(ctx),
          size: 26,
        ),
        title: const Text(
          'أكمل بيانات حسابك',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
        ),
        content: Text(
          'ينقصنا $missing. إضافته تحمي وصولك إلى حسابك عند تغيير الجهاز.',
          style: const TextStyle(fontSize: 12.5, height: 1.55),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('لاحقاً'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('إكمال الآن'),
          ),
        ],
      ),
    );
    if (go == true && context.mounted) onOpenSettings();
    return true;
  }
}
