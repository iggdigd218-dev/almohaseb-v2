// تسجيل قاعدة جدار حماية ويندوز يتم حصرياً أثناء التثبيت عبر المُثبّت الرسمي (NexoraSetup.exe).
// لا يقوم التطبيق باستدعاء netsh أو رفع صلاحيات UAC أثناء الإقلاع.
import 'package:flutter/foundation.dart';

class WindowsFirewall {
  WindowsFirewall._();

  static const ruleName = 'Nexora Enterprise';

  /// رسالة توجيه للمستخدم إن لزم (محفوظة للتوافق).
  static final ValueNotifier<String?> firewallNotice =
      ValueNotifier<String?>(null);

  /// عملية صامتة آمنة لا تستدعي أوامر نظام ولا تطلب صلاحيات UAC عند الإقلاع.
  static Future<void> ensureRegistered() async {
    firewallNotice.value = null;
  }
}
