package meshcorebeacon.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

/** Protects the existing Flutter isolate/connection, without a second RF owner.
 * No automatic restart, reconnect, or boot receiver. A bounded heartbeat lease
 * prevents an orphan notification/wake lock if Dart stops responding.
 */
class TelemetryService : Service() {
    companion object {
        private const val CHANNEL = "beacon.telemetry"
        private const val ID = 4041
        private const val PAUSE = "meshcorebeacon.app.telemetry.PAUSE"
        private const val DISCONNECT = "meshcorebeacon.app.telemetry.DISCONNECT"
        private const val LEASE_MS = 120_000L
        private var current: TelemetryService? = null
        private var pending: MethodChannel.Result? = null
        private var initial: Map<*, *>? = null
        var onAction: ((String) -> Unit)? = null

        fun begin(context: Context, notice: Map<*, *>?, result: MethodChannel.Result) {
            if (notice == null || current != null || pending != null || onAction == null) {
                result.error("busy", "Telemetry service unavailable or already active", null)
                return
            }
            pending = result
            initial = notice
            try {
                ContextCompat.startForegroundService(context, Intent(context, TelemetryService::class.java))
            } catch (_: Exception) {
                pending = null
                initial = null
                result.error("service_start", "Android did not allow background collection", null)
            }
        }

        fun update(notice: Map<*, *>?): String {
            val service = current ?: return "stopped"
            if (notice == null || !service.notificationsEnabled()) {
                service.finish()
                return "stopped"
            }
            service.notice = notice
            // A stale heartbeat must never undo a notification Stop action.
            if (notice["paused"] == true) service.polling = false
            service.heartbeat = SystemClock.uptimeMillis()
            return try {
                service.updateWakeLock()
                service.manager.notify(ID, service.notification())
                if (service.polling) "active" else "paused"
            } catch (_: Exception) {
                service.finish()
                "stopped"
            }
        }

        fun resumePolling(): Boolean {
            val service = current ?: return false
            if (!service.notificationsEnabled()) return false
            service.polling = true
            service.heartbeat = SystemClock.uptimeMillis()
            return try {
                service.updateWakeLock()
                service.manager.notify(ID, service.notification())
                true
            } catch (_: Exception) { service.finish(); false }
        }

        fun end(context: Context) {
            pending?.error("cancelled", "Collection was stopped", null)
            pending = null
            initial = null
            current?.finish()
            context.stopService(Intent(context, TelemetryService::class.java))
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var manager: NotificationManager
    private lateinit var wakeLock: PowerManager.WakeLock
    private var notice: Map<*, *> = emptyMap<String, Any>()
    private var polling = true
    private var heartbeat = 0L
    private var ended = false
    private val watchdog = object : Runnable {
        override fun run() {
            if (ended) return
            if (SystemClock.uptimeMillis() - heartbeat > LEASE_MS || !notificationsEnabled()) finish()
            else handler.postDelayed(this, 30_000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        manager = getSystemService(NotificationManager::class.java)
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "meshcorebeacon.app:telemetry")
            .apply { setReferenceCounted(false) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == PAUSE && current === this) {
            polling = false
            updateWakeLock()
            manager.notify(ID, notification())
            onAction?.invoke("pause")
            return START_NOT_STICKY
        }
        if (intent?.action == DISCONNECT) { finish(); return START_NOT_STICKY }
        val reply = pending
        val saved = initial
        pending = null
        initial = null
        // Never recreate a collector from a restarted service or stale intent.
        if (reply == null || saved == null || onAction == null || ended) {
            reply?.error("cancelled", "Collection was stopped", null)
            finish()
            return START_NOT_STICKY
        }
        notice = saved
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                manager.createNotificationChannel(NotificationChannel(
                    CHANNEL, text("channelName"), NotificationManager.IMPORTANCE_LOW,
                ).apply { setShowBadge(false) })
            }
            check(notificationsEnabled())
            ServiceCompat.startForeground(this, ID, notification(),
                if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0)
            current = this
            heartbeat = SystemClock.uptimeMillis()
            updateWakeLock()
            handler.postDelayed(watchdog, 30_000L)
            reply.success(true)
        } catch (_: Exception) {
            reply.error("service_start", "Enable telemetry notifications or use foreground collection", null)
            finish()
        }
        return START_NOT_STICKY
    }

    private fun notificationsEnabled(): Boolean =
        NotificationManagerCompat.from(this).areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE)

    private fun text(key: String): String = (notice[key] as? String)?.take(600) ?: "Beacon"

    private fun action(action: String, request: Int): PendingIntent = PendingIntent.getService(
        this, request, Intent(this, TelemetryService::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, ID,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val summary = text("summary")
        val details = notice["details"] as? String ?: ""
        val builder = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_telemetry)
            .setContentTitle(text(if (polling) "title" else "pausedTitle"))
            .setContentText(summary)
            .setContentIntent(open)
            .setOngoing(true).setSilent(true).setOnlyAlertOnce(true).setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        if (details.isNotBlank()) builder.setStyle(NotificationCompat.BigTextStyle().bigText("$summary\n${details.take(600)}"))
        if (polling) builder.addAction(0, text("pauseLabel"), action(PAUSE, ID + 1))
        builder.addAction(0, text("disconnectLabel"), action(DISCONNECT, ID + 2))
        return builder.build()
    }

    private fun updateWakeLock() {
        // No lock survives a lost collector heartbeat. Pausing releases it now.
        if (wakeLock.isHeld) wakeLock.release()
        if (polling) wakeLock.acquire(LEASE_MS + 30_000L)
    }

    private fun finish() {
        if (ended) return
        ended = true
        polling = false
        if (current === this) current = null
        handler.removeCallbacks(watchdog)
        if (wakeLock.isHeld) wakeLock.release()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
        onAction?.invoke("disconnect")
    }

    override fun onDestroy() { finish(); super.onDestroy() }
    override fun onBind(intent: Intent?): IBinder? = null
}
