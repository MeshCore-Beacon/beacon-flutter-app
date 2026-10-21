import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/preferences.dart';
import '../../core/strings.dart';
import 'background.dart';
import 'sharing.dart';

class TelemetryScope extends InheritedNotifier<TelemetrySession> {
  const TelemetryScope({
    super.key,
    required TelemetrySession session,
    required super.child,
  }) : super(notifier: session);
  static TelemetrySession of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TelemetryScope>()!.notifier!;
}

/// App-owned, single connection. Navigating away must not destroy an opted-in
/// collector. Platform loss, explicit disconnect and app teardown still close it.
class TelemetrySession extends ChangeNotifier with WidgetsBindingObserver {
  TelemetrySession(this.preferences, {TelemetryBackground? background})
    : background = background ?? TelemetryBackground() {
    this.background.onAction = _action;
    WidgetsBinding.instance.addObserver(this);
  }
  final Preferences preferences;
  final TelemetryBackground background;
  TelemetrySharing? sharing;
  Timer? _timer;
  Future<void>? _stopping;
  bool _disposed = false, _ticking = false, _starting = false;
  bool backgroundActive = false;
  String transport = '';
  String status = '';
  bool get active => sharing != null;
  bool get starting => _starting;
  bool get stopping => _stopping != null;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Map<String, Object> get _notice => {
    'title': _starting
        ? tr('Preparing telemetry collection')
        : tr('Telemetry polling active'),
    'pausedTitle': tr('Telemetry polling stopped'),
    'summary': '$transport · ${tr('Companion connected')}',
    'details': preferences.telemetryNotificationStats && sharing != null
        ? '${tr('Selected repeaters')}: ${sharing!.targets.length} · ${tr('Interval (hours)')}: ${sharing!.hours}\n${tr('Accepted reports')}: ${sharing!.accepted} · ${tr('Pending')}: ${sharing!.queued} · ${tr('Expired saved reports')}: ${sharing!.expired}'
        : '',
    'pauseLabel': tr('Stop polling'),
    'disconnectLabel': transport == 'BLE'
        ? tr('Disconnect BLE')
        : tr('Disconnect Wi-Fi'),
    'channelName': tr('Background telemetry'),
    'paused': sharing?.paused ?? false,
  };

  Future<void> start(TelemetrySharing next, {required String transport}) async {
    if (_disposed || active || _stopping != null) {
      throw StateError('A collector is already active or stopping');
    }
    sharing = next;
    this.transport = transport;
    _starting = true;
    _changed();
    try {
      if (background.supported && preferences.telemetryBackground == true) {
        // Start while visible, before enrollment or any RF. Denial never falls
        // through into silent collection; the user can choose foreground mode.
        await background.start(_notice);
        if (!identical(sharing, next)) {
          await background.stop();
          return;
        }
        backgroundActive = true;
      }
      if (!identical(sharing, next)) return;
      await next.start();
      if (!identical(sharing, next)) return;
      unawaited(
        next.radio.whenClosed.then((_) async {
          if (identical(sharing, next)) await disconnect();
        }),
      );
      _starting = false;
      _timer = Timer.periodic(
        const Duration(seconds: 20),
        (_) => unawaited(tick()),
      );
      await tick();
    } catch (_) {
      await disconnect();
      rethrow;
    } finally {
      _starting = false;
      _changed();
    }
  }

  Future<void> tick() async {
    final current = sharing;
    if (current == null || _ticking || _starting) return;
    _ticking = true;
    try {
      if (backgroundActive) {
        final state = await background.update(_notice);
        if (!identical(sharing, current)) return;
        if (state == 'stopped') {
          await disconnect();
          return;
        }
        if (state == 'paused') current.pause();
      }
      if (!identical(sharing, current)) return;
      if (!current.running || current.radio.closed) {
        await disconnect();
        return;
      }
      // step() serializes radio commands. Do not hold up notification heartbeats
      // while waiting for a repeater or HTTPS; each has its own bounded timeout.
      unawaited(_step(current));
      status = current.paused
          ? tr('Polling stopped; companion remains connected.')
          : current.status;
      _changed();
    } catch (_) {
      await disconnect();
    } finally {
      _ticking = false;
    }
  }

  Future<void> _step(TelemetrySharing current) async {
    try {
      await current.step();
    } catch (_) {
      if (identical(sharing, current)) await disconnect();
    }
    if (!identical(sharing, current)) return;
    if (!current.running || current.radio.closed) {
      await disconnect();
      return;
    }
    status = current.paused
        ? tr('Polling stopped; companion remains connected.')
        : current.status;
    _changed();
  }

  Future<void> _action(String action) async {
    if (action == 'pause') {
      sharing?.pause();
      status = tr('Polling stopped; companion remains connected.');
      _changed();
    } else if (action == 'disconnect') {
      await disconnect();
    }
  }

  Future<void> pause() async {
    await _action('pause');
    if (backgroundActive) {
      try {
        await background.update(_notice);
      } catch (_) {
        await disconnect();
      }
    }
  }

  Future<void> resume() async {
    final current = sharing;
    if (current == null || _starting) return;
    try {
      await current.waitForIdle();
      if (!identical(sharing, current)) return;
      if (backgroundActive) await background.resume();
      if (!identical(sharing, current)) return;
      current.resume();
      await tick();
    } catch (_) {
      await disconnect();
    }
  }

  Future<void> disconnect() => _stopping ??= _disconnect().whenComplete(() {
    _stopping = null;
  });
  Future<void> _disconnect() async {
    _timer?.cancel();
    _timer = null;
    final current = sharing;
    sharing = null;
    final hadService = backgroundActive;
    backgroundActive = false;
    // stop() closes the companion immediately, cancelling an in-flight request.
    try {
      await current?.stop();
    } finally {
      if (hadService) {
        try {
          await background.stop();
        } catch (_) {
          /* Native watchdog also expires. */
        }
      }
      status = tr(
        'Sharing stopped; cooldowns and pending reports are retained.',
      );
      _changed();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached ||
        (!backgroundActive &&
            (state == AppLifecycleState.hidden ||
                state == AppLifecycleState.paused))) {
      unawaited(disconnect());
    } else if (state == AppLifecycleState.resumed && active && !_starting) {
      unawaited(tick());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(disconnect().whenComplete(background.dispose));
    super.dispose();
  }
}
