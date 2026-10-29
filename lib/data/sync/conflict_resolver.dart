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

    // 3. الكيان موجود محلياً: الحسم الموحّد والحتمي (P2-2 / M4):
    // (أ) ترجيح توقيت السيرفر الحتمي (Server Time Priority):
    // عند فض النزاعات، يكون server_time هو المرجّح الأول الحصري في حال توفره لدى أيٍّ من الطرفين.
    final inServerMs = incoming.serverTimeMs;
    final locServerMs = localLatest?.serverTimeMs ?? 0;

    if (inServerMs > 0 || locServerMs > 0) {
      if (inServerMs > 0 && locServerMs > 0) {
        if (inServerMs != locServerMs) {
          return inServerMs > locServerMs;
        }
        if (incoming.version != localVersion) {
          return incoming.version > localVersion;
        }
      } else if (inServerMs > 0 && locServerMs == 0) {
        // الطرف الوارد يحمل توقيت سيرفر مؤكد بينما المحلي لم يؤكَّد بعد من السيرفر
        return true;
      } else {
        // الطرف المحلي يحمل توقيت سيرفر مؤكد بينما الوارد لا يحمل توقيت سيرفر
        return false;
      }

      final localDevId = localLatest?.deviceId ?? '';
      if (localDevId.isNotEmpty && localDevId == incoming.deviceId) {
        return true;
      }
      return incoming.deviceId.compareTo(localDevId) <= 0;
    }

    // (ب) غياب توقيت السيرفر عن الطرفين تماماً: المقارنة بالنسخة ثم التوقيت المحلي (deviceTime كخيار أخير)
    if (incoming.version != localVersion) {
      return incoming.version > localVersion;
    }

    final tIn = DateTime.tryParse(incoming.timestamp)?.millisecondsSinceEpoch ??
        (DateTime.tryParse(incoming.deviceTime)?.millisecondsSinceEpoch ?? 0);
    final tLocal = DateTime.tryParse(localLatest?.timestamp ?? '')?.millisecondsSinceEpoch ??
        (DateTime.tryParse(localLatest?.deviceTime ?? '')?.millisecondsSinceEpoch ?? 0);

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
