// كاشف/حلّال التعارضات الذكي — مبدأ Last-Write-Wins (اعتماد الأحدث وحذف القديم).
// يضمن استمرار المزامنة بدون توقف وحسم أي تفاوت بين الأجهزة تلقائياً وحتمياً.
import 'operation.dart';

class ConflictResolver {
  /// يقرر هل تُطبَّق العملية الواردة على الكيان المحلي (`true` = تطبيق، `false` = تجاهل)
  /// وفق مبدأ الحسم الذكي Last-Write-Wins (اعتماد الأحدث وحذف القديم).
  bool decide({
    required SyncOperation incoming,
    required bool exists,
    required int localVersion,
    required SyncOperation? localLatest,
  }) {
    // 1. Idempotency: نفس العملية برقمها مسجلة محلياً -> تجاهل مكرر
    if (localLatest != null && localLatest.id == incoming.id) {
      return false;
    }

    // 2. الكيان غير موجود محلياً
    if (!exists) {
      if (incoming.opType == OpKind.create) {
        return true;
      }
      if (incoming.opType == OpKind.delete_) {
        // حذف لكيان غير موجود أصلاً -> تجاهل آمن دون توقف
        return false;
      }
      // عملية تعديل لكيان غير موجود: إن توفرت بيانات كافية ننشئه محلياً (اعتماد الأحدث)
      return incoming.payload.isNotEmpty;
    }

    // 3. الكيان موجود محلياً: الحسم الموحّد والحتمي (M4):
    // الترتيب القياسي الموحّد لكسر التعادل في جميع الحالات:
    // (أ) مقارنة رقم الإصدار (Version) إن اختلف وكان أحدهما متقدماً.
    // (ب) مقارنة الطابع الزمني المرجعي (server_time إن توفر في الطرفين، وإلا الطابع المحلي).
    // (ج) كسر التعادل الحتمي عبر مقارنة معرف الجهاز lexicographically (`deviceId.compareTo`).
    final inServerMs = incoming.serverTimeMs;
    final locServerMs = localLatest?.serverTimeMs ?? 0;

    if (inServerMs > 0 && locServerMs > 0) {
      if (incoming.version != localVersion) {
        if (inServerMs != locServerMs) {
          return inServerMs > locServerMs;
        }
        return incoming.version > localVersion;
      }
      if (inServerMs != locServerMs) {
        return inServerMs > locServerMs;
      }
      final localDevId = localLatest?.deviceId ?? '';
      if (localDevId.isNotEmpty && localDevId == incoming.deviceId) {
        return true;
      }
      return incoming.deviceId.compareTo(localDevId) <= 0;
    }

    // مسار عدم اكتمال server_time في أحد الطرفين: نفس الترتيب القياسي الموحّد
    if (incoming.version != localVersion) {
      return incoming.version > localVersion;
    }

    final tIn = inServerMs > 0
        ? inServerMs
        : (DateTime.tryParse(incoming.timestamp)?.millisecondsSinceEpoch ??
            (DateTime.tryParse(incoming.deviceTime)?.millisecondsSinceEpoch ??
                0));
    final tLocal = locServerMs > 0
        ? locServerMs
        : (DateTime.tryParse(localLatest?.timestamp ?? '')
                ?.millisecondsSinceEpoch ??
            (DateTime.tryParse(localLatest?.deviceTime ?? '')
                    ?.millisecondsSinceEpoch ??
                0));

    if (tIn != tLocal) {
      return tIn > tLocal;
    }

    final localDevId = localLatest?.deviceId ?? '';
    if (localDevId.isNotEmpty && localDevId == incoming.deviceId) {
      return true;
    }
    return incoming.deviceId.compareTo(localDevId) <= 0;
  }
}
