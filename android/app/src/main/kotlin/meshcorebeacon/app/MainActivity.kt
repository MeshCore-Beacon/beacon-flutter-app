package meshcorebeacon.app

import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var visible = false
    private var telemetryChannel: MethodChannel? = null

    override fun onStart() {
        super.onStart()
        visible = true
    }

    override fun onStop() {
        visible = false
        super.onStop()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "meshcorebeacon.app/telemetry")
        telemetryChannel = channel
        TelemetryService.onAction = { action -> channel.invokeMethod("action", action) }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (!visible) result.error("not_visible", "Open Beacon before starting collection", null)
                    else TelemetryService.begin(this, call.arguments as? Map<*, *>, result)
                }
                "update" -> result.success(TelemetryService.update(call.arguments as? Map<*, *>))
                "resume" -> {
                    if (!visible || !TelemetryService.resumePolling()) {
                        result.error("not_active", "Open Beacon and reconnect to resume", null)
                    } else result.success(null)
                }
                "stop" -> { TelemetryService.end(this); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // Backgrounding is supported; resurrecting an abandoned engine is not.
        TelemetryService.end(this)
        TelemetryService.onAction = null
        telemetryChannel?.setMethodCallHandler(null)
        telemetryChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 15+ forces edge-to-edge for SDK 35+ targets; opt in on older
        // versions too so every device draws behind the system bars the same way
        WindowCompat.enableEdgeToEdge(window)
    }
}
