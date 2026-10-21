import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// One foreground service protects the existing isolate and companion connection.
/// It never creates a second collector, restarts after process death, or owns RF.
class TelemetryBackground {
  TelemetryBackground({bool? supported})
    : supported =
          supported ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    if (this.supported) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'action') {
          await onAction?.call(call.arguments as String);
        }
      });
    }
  }

  static const _channel = MethodChannel('meshcorebeacon.app/telemetry');
  final bool supported;
  Future<void> Function(String)? onAction;

  Future<void> start(Map<String, Object> notice) async {
    if (!supported || !await Permission.notification.request().isGranted) {
      throw StateError('Background collection needs notification permission');
    }
    try {
      if (await _channel
              .invokeMethod<bool>('start', notice)
              .timeout(const Duration(seconds: 10)) !=
          true) {
        throw StateError('Background collection could not start');
      }
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<String> update(Map<String, Object> notice) async =>
      await _channel.invokeMethod<String>('update', notice) ?? 'stopped';
  Future<void> resume() => _channel.invokeMethod<void>('resume');
  Future<void> stop() async {
    if (supported) await _channel.invokeMethod<void>('stop');
  }

  void dispose() {
    onAction = null;
    if (supported) _channel.setMethodCallHandler(null);
  }
}
