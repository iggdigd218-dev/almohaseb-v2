package com.nexora.eradata

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * خدمة أمامية تُبقي التطبيق يقظاً وهو داخل مجموعة مزامنة:
 * تمنع النظام من قتل العملية أو تجميد الشبكة أثناء سكون الهاتف والشاشة
 * مطفأة، فيستمر خادم LAN في استقبال العمليات والرسائل والإشعارات فوراً.
 * إشعار دائم صامت (IMPORTANCE_MIN) يعلم المستخدم أن المزامنة نشطة.
 */
class KeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        clearPersistentNotification(this)
        try {
            @Suppress("DEPRECATION")
            stopForeground(true)
        } catch (_: Exception) {}
        stopSelf()
        return START_NOT_STICKY
    }

    companion object {
        private const val CHANNEL_ID = "nexora_keepalive"
        private const val NOTIF_ID = 777001

        private fun clearPersistentNotification(ctx: Context) {
            try {
                val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.cancel(NOTIF_ID)
                if (Build.VERSION.SDK_INT >= 26) {
                    nm.deleteNotificationChannel(CHANNEL_ID)
                }
            } catch (_: Exception) {}
        }

        fun start(ctx: Context) {
            stop(ctx)
        }

        fun stop(ctx: Context) {
            clearPersistentNotification(ctx)
            try { ctx.stopService(Intent(ctx, KeepAliveService::class.java)) }
            catch (_: Exception) {}
        }
    }
}
