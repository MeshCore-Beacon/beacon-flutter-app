package meshcorebeacon.app

import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.android.controller.ServiceController
import org.robolectric.shadows.ShadowPowerManager
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class TelemetryServiceTest {
    private lateinit var app: Application
    private lateinit var controller: ServiceController<TelemetryService>
    private val actions = mutableListOf<String>()
    private val notice = mapOf(
        "title" to "Telemetry polling active", "pausedTitle" to "Telemetry polling stopped",
        "summary" to "BLE · Companion connected", "details" to "Accepted: 3 · Pending: 1",
        "pauseLabel" to "Stop polling", "disconnectLabel" to "Disconnect BLE",
        "channelName" to "Background telemetry", "paused" to false,
    )
    private class Reply : MethodChannel.Result {
        var value: Any? = null
        var error: String? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { error = code }
        override fun notImplemented() { error = "notImplemented" }
    }
    @Before fun setup() {
        app = RuntimeEnvironment.getApplication()
        TelemetryService.onAction = { actions.add(it) }
        controller = Robolectric.buildService(TelemetryService::class.java).create()
    }
    @After fun cleanup() {
        TelemetryService.end(app)
        controller.destroy()
        TelemetryService.onAction = null
    }
    private fun start(): Reply {
        val reply = Reply()
        TelemetryService.begin(app, notice, reply)
        controller.get().onStartCommand(Intent(app, TelemetryService::class.java), 0, 1)
        return reply
    }
    private fun notification(): Notification = shadowOf(app.getSystemService(NotificationManager::class.java)).getNotification(4041)

    @Test fun notificationHasStatsAndActionsAndPauseCannotBeUndoneByStaleHeartbeat() {
        assertEquals(true, start().value)
        val banner = notification()
        assertEquals("Telemetry polling active", banner.extras.getCharSequence(Notification.EXTRA_TITLE))
        assertTrue(banner.extras.getCharSequence(Notification.EXTRA_BIG_TEXT).toString().contains("Accepted: 3"))
        assertEquals(Notification.VISIBILITY_PRIVATE, banner.visibility)
        assertEquals(listOf("Stop polling", "Disconnect BLE"), banner.actions.map { it.title })
        val lock = ShadowPowerManager.getLatestWakeLock()
        assertTrue(lock.isHeld)
        val intent = shadowOf(banner.actions[0].actionIntent).savedIntent
        controller.get().onStartCommand(intent, 0, 2)
        assertEquals(listOf("pause"), actions)
        assertEquals("paused", TelemetryService.update(notice))
        assertFalse(lock.isHeld)
        assertEquals("Telemetry polling stopped", notification().extras.getCharSequence(Notification.EXTRA_TITLE))
        assertEquals(1, notification().actions.size)
        assertTrue(TelemetryService.resumePolling())
        assertEquals("active", TelemetryService.update(notice))
    }

    @Test fun disconnectActionAndTaskDestructionReleaseTheService() {
        assertEquals(true, start().value)
        val lock = ShadowPowerManager.getLatestWakeLock()
        val intent = shadowOf(notification().actions[1].actionIntent).savedIntent
        controller.get().onStartCommand(intent, 0, 2)
        assertEquals(listOf("disconnect"), actions)
        assertFalse(lock.isHeld)
        assertEquals("stopped", TelemetryService.update(notice))
    }

    @Test fun lostDartHeartbeatExpiresWakeLockAndRequestsDisconnect() {
        assertEquals(true, start().value)
        val lock = ShadowPowerManager.getLatestWakeLock()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMinutes(3))
        assertEquals("stopped", TelemetryService.update(notice))
        assertFalse(lock.isHeld)
        assertEquals(listOf("disconnect"), actions)
    }

    @Test fun restartedServiceCannotStartCollection() {
        controller.get().onStartCommand(null, 0, 1)
        assertEquals("stopped", TelemetryService.update(notice))
        assertFalse(TelemetryService.resumePolling())
    }

    @Test fun disabledNotificationChannelPreventsCollection() {
        assertEquals(true, start().value)
        val manager = app.getSystemService(NotificationManager::class.java)
        shadowOf(manager).setNotificationsEnabled(false)
        assertEquals("stopped", TelemetryService.update(notice))
        assertEquals(listOf("disconnect"), actions)
    }
}
