// ثوابت أسماء الأجهزة الافتراضية — **مصدر حقيقة واحد**.
//
// (توحيد الثوابت) كانت القائمة نفسها مكرّرة نصًّا في `repository.dart`
// و`apply_remote.dart` و`cloud_join.dart` و`profile_dialog.dart`، وأي
// اختلاف حرف واحد يُبطل الحماية صامتًا.
//
// القاعدة: كل ما في هذه القائمة اسم «مكان شاغر» يجوز الكتابة فوقه
// بالاسم الحقيقي القادم من الروستر أو من جهاز المدير.
library;

/// الأسماء الافتراضية التي لا تُعدّ اسمًا مخصّصًا.
const Set<String> kPlaceholderDeviceNames = <String>{
  'المدير',
  'عضو',
  'جهاز',
  'جهاز المحاسب',
  'جهاز مدير الحسابات',
  'جهاز عضو',
  'مستخدم جديد',
  'غير معيّن',
};

/// الاسم الافتراضي المستخدم عند غياب أي اسم.
const String kDefaultMemberDeviceName = 'مستخدم جديد';
const String kDefaultOwnerDeviceName = 'المدير';

/// (3.98.39) لبّ الاسم بعد تجريد الرموز التعبيرية وعلامات الترقيم.
///
/// السبب: النسخ القديمة ولوحة الإدارة تحفظ أسماء مثل «المدير 🫡» أو
/// «المدير  👑» — وهي في الحقيقة اسم مكان شاغر لا هوية مخصّصة. بدون هذا
/// التطبيع كانت تُعدّ «اسمًا مخصّصًا» فتُكتب فوق اسم المالك الذي اختاره
/// بنفسه من أيقونة ✎ في القائمة الجانبية.
String deviceNameCore(String? raw) {
  final name = (raw ?? '').trim();
  if (name.isEmpty) return '';
  // نُبقي الحروف العربية/اللاتينية والأرقام فقط.
  final core = name
      .replaceAll(RegExp(r'[^\u0600-\u06FF\u0750-\u077FA-Za-z0-9]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .join(' ');
  return core.trim();
}

/// هل النص اسم مكان شاغر (فارغ أو ضمن القائمة أو نسخة مزخرفة منها)؟
bool isPlaceholderDeviceName(String? raw) {
  final name = (raw ?? '').trim();
  if (name.isEmpty) return true;
  if (kPlaceholderDeviceNames.contains(name)) return true;
  final core = deviceNameCore(name);
  if (core.isEmpty) return true; // رموز فقط
  return kPlaceholderDeviceNames.contains(core);
}

/// الاسم المعروض للمالك/المدير: الاسم المخصّص أولاً ثم أسماء السجل ثم «المدير».
///
/// (3.98.39 / الملاحظة 1) مصدر الحقيقة بالترتيب:
///   1. `profile.owner_name` (ما كتبه المالك من ✎ أو من ملف التعريف).
///   2. `account.name` القادم من الحساب السحابي.
///   3. اسم جهاز المالك في سجل المجموعة.
///   4. اسم مستخدم المالك (is_me = 1).
/// ثم «المدير» كحد أدنى. الأسماء الافتراضية المزخرفة تُتجاهل.
String resolveOwnerDisplayName({
  String? profileOwnerName,
  String? accountName,
  String? deviceName,
  String? userName,
}) {
  for (final candidate in [profileOwnerName, accountName, deviceName, userName]) {
    if (isCustomDeviceName(candidate)) return candidate!.trim();
  }
  return 'المدير';
}

/// هل النص اسم مخصّص حقيقي (غير مكان شاغر)؟
bool isCustomDeviceName(String? raw) => !isPlaceholderDeviceName(raw);

/// توحيد اسم العضو من سجل الجهاز والمستخدم المرتبط به دون إظهار أسماء افتراضية مثل «جهاز» أو «جهاز عضو».
String resolveMemberUnifiedName({
  String? deviceName,
  String? userName,
  bool isOwner = false,
  String? fallback,
}) {
  final dev = (deviceName ?? '').trim();
  final usr = (userName ?? '').trim();
  if (isCustomDeviceName(dev)) return dev;
  if (isCustomDeviceName(usr)) return usr;
  if (fallback != null) return fallback;
  return isOwner ? 'المدير' : 'مستخدم جديد';
}
