// تم إلغاء نوافذ طلب الصلاحيات الخاصة بالتطبيق؛ تُطلب الصلاحيات من النظام مباشرة.
import 'package:flutter/material.dart';

class PermissionRationale {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String message;
  final String grantLabel;
  final String denyLabel;

  const PermissionRationale({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.message,
    this.grantLabel = 'السماح',
    this.denyLabel = 'ليس الآن',
  });

  // طلبات الصلاحيات الشائعة.
  static const contacts = PermissionRationale(
    icon: Icons.contacts_rounded,
    iconColor: Color(0xFF4CAF50),
    title: 'السماح بالوصول إلى جهات الاتصال',
    message:
        'نحتاج إلى الوصول إلى جهات اتصال هاتفك لتسهيل اختيار الاسم ورقم الجوال عند '
        'إضافة حساب عميل أو مورّد جديد بضغطة واحدة بدل كتابتها يدوياً.\n\n'
        'لن يتم رفع أي من أسمائك أو أرقامك إلى أي خادم — كل شيء يبقى في جهازك.',
  );

  static const camera = PermissionRationale(
    icon: Icons.photo_camera_rounded,
    iconColor: Color(0xFF2196F3),
    title: 'السماح باستخدام الكاميرا',
    message:
        'نحتاج إلى الكاميرا لمسح الباركود وإضافة صور للفواتير أو للمؤسسة.\n\n'
        'لا يتم تشغيل الكاميرا إلا عندما تضغط أنت على زر المسح أو زر الكاميرا.',
  );

  static const notifications = PermissionRationale(
    icon: Icons.notifications_active_rounded,
    iconColor: Color(0xFFFF9800),
    title: 'تفعيل الإشعارات',
    message:
        'لإشعارك عند وصول نسخ احتياطية، انتهاء مخزون، أو فشل مزامنة الأجهزة، '
        'نحتاج إذن عرض الإشعارات.\n\nيمكنك إلغاء الإذن من إعدادات الهاتف في أي وقت.',
  );

  static const storage = PermissionRationale(
    icon: Icons.sd_storage_rounded,
    iconColor: Color(0xFF9C27B0),
    title: 'الوصول إلى التخزين',
    message: 'نحتاج التخزين لحفظ النسخ الاحتياطية (ملف .sijil) وقراءتها عند '
        'الاستعادة أو مشاركتها.',
  );
}

/// تم إلغاء النافذة المخصصة للتطبيق لطلب الأذونات؛ يتم طلب الأذونات مباشرة من النظام.
Future<bool> showPermissionRationale(
  BuildContext context,
  PermissionRationale rationale,
) async {
  return true;
}
