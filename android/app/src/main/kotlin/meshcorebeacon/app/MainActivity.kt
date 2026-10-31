package meshcorebeacon.app

import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 15+ forces edge-to-edge for SDK 35+ targets; opt in on older
        // versions too so every device draws behind the system bars the same way
        WindowCompat.enableEdgeToEdge(window)
    }
}
