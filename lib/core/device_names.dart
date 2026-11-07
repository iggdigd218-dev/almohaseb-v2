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
  'جهاز المحاسب',
  'جهاز مدير الحسابات',
  'جهاز عضو',
};

/// الاسم الافتراضي المستخدم عند غياب أي اسم.
const String kDefaultMemberDeviceName = 'جهاز عضو';
const String kDefaultOwnerDeviceName = 'جهاز مدير الحسابات';

/// هل النص اسم مكان شاغر (فارغ أو ضمن القائمة)؟
bool isPlaceholderDeviceName(String? raw) {
  final name = (raw ?? '').trim();
  if (name.isEmpty) return true;
  return kPlaceholderDeviceNames.contains(name);
}

/// هل النص اسم مخصّص حقيقي (غير مكان شاغر)؟
bool isCustomDeviceName(String? raw) => !isPlaceholderDeviceName(raw);
