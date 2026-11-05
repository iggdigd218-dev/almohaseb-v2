package com.nexora.eradata

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * بعد إعادة تشغيل الهاتف: إن كان الجهاز داخل مجموعة مزامنة (علامة يكتبها
 * فلاتر في SharedPreferences عند تفعيل اليقظة) نعيد تشغيل خدمة اليقظة
 * تلقائياً حتى يستقبل الجهاز عمليات المجموعة دون فتح التطبيق.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        context.getSharedPreferences("nexora_keepalive", Context.MODE_PRIVATE)
            .edit().putBoolean("enabled", false).apply()
        KeepAliveService.stop(context)
    }
}
