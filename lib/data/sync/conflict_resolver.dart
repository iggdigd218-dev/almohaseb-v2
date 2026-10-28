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

    // 3. الكيان موجود محلياً: الحسم الذكي وفق أحدث وقت خادم مرجعي `server_time`
    // (Last-Write-Wins) مع الرجوع للطابع المحلي للعمليات القديمة غير المرفوعة بعد.
    // إذا كان وقت الخادم `server_time` متوفراً في الطرفين، يُحسم التعارض حصرياً به.
    final inServerMs = incoming.serverTimeMs;
    final locServerMs = localLatest?.serverTimeMs ?? 0;
    if (inServerMs > 0 && locServerMs > 0) {
      if (inServerMs > locServerMs) {
        return true;
      }
      if (inServerMs < locServerMs) {
        return false;
      }
      // تساوٍ تام في وقت الخادم server_time -> كسر التعادل حتمياً بـ رقم الإصدار ثم device_id
      if (incoming.version > localVersion) {
        return true;
      }
      if (incoming.version < localVersion) {
        return false;
      }
      if (localLatest != null && localLatest.deviceId == incoming.deviceId) {
        return true;
      }
      return incoming.deviceId.compareTo(localLatest?.deviceId ?? '') <= 0;
    }

    // إذا كان رقم الإصدار الوارد أكبر: تطبيق فوراً
    if (incoming.version > localVersion) {
      return true;
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

    // إذا كانت العملية الواردة أحدث زمنياً (Last-Write-Wins): تطبيق واعتماد الأحدث
    if (tIn > tLocal) {
      return true;
    }

    if (incoming.version == localVersion) {
      if (localLatest != null && localLatest.deviceId == incoming.deviceId) {
        return true;
      }
      return incoming.deviceId.compareTo(localLatest?.deviceId ?? '') <= 0;
    }

    return false;
  }
}
