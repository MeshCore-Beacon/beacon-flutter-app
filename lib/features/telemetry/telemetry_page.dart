import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/instance.dart';
import '../../core/strings.dart';
import 'ble_companion.dart';
import 'companion.dart';
import 'sharing.dart';

class TelemetryPage extends StatefulWidget {
  const TelemetryPage({super.key, required this.instance});
  final BeaconInstance instance;
  @override
  State<TelemetryPage> createState() => _TelemetryPageState();
}

class _TelemetryPageState extends State<TelemetryPage>
    with WidgetsBindingObserver {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '5000');
  final _hours = TextEditingController(text: '6');
  final _passwords = <String, TextEditingController>{};
  final _selected = <String>{}, _admins = <String>{};
  List<CompanionContact> _contacts = [];
  Companion? _radio;
  BleCompanion? _ble;
  List<BlePeer> _devices = [];
  bool _bleMode = true;
  TelemetrySharing? _sharing;
  Timer? _timer;
  Future<void>? _stopping;
  bool _busy = false, _consent = false, _environment = false;
  int _generation = 0;
  String _status = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_stop());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stop());
    _host.dispose();
    _port.dispose();
    _hours.dispose();
    for (final controller in _passwords.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _stop() => _stopping ??= _disconnect().whenComplete(() {
    _stopping = null;
  });

  Future<void> _disconnect() async {
    _generation++;
    _busy = true;
    _timer?.cancel();
    _timer = null;
    // Take ownership before yielding; a cancelled attempt must not close a new link.
    final radio = _radio, ble = _ble, sharing = _sharing;
    _radio = null;
    _ble = null;
    _sharing = null;
    await radio?.close();
    await ble?.close();
    await sharing?.stop();
    if (mounted) {
      for (final controller in _passwords.values) {
        controller.clear();
      }
      setState(() {
        _busy = false;
        _status = tr(
          'Sharing stopped; cooldowns and pending reports are retained.',
        );
      });
    }
  }

  Future<void> _scanBle() async {
    if (_busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _devices = [];
      _status = tr('Scanning for BLE companions…');
    });
    final ble = BleCompanion();
    _ble = ble;
    try {
      final devices = await ble.scan();
      if (mounted && generation == _generation) {
        setState(() {
          _devices = devices;
          _status = devices.isEmpty
              ? tr(
                  'No BLE companions found. Check power, Bluetooth permissions and that the radio is disconnected from other apps.',
                )
              : tr('Choose your companion.');
        });
      }
    } catch (_) {
      await ble.close();
      if (mounted && generation == _generation) {
        setState(() {
          _status = tr(
            'BLE is unavailable. Check Bluetooth and app permissions.',
          );
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _connect({String? bleId}) async {
    if (_busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _status = tr('Connecting to companion…');
    });
    Companion? connection;
    try {
      connection = bleId == null
          ? await Companion.connect(_host.text, int.tryParse(_port.text) ?? 0)
          : await _ble!.connect(bleId);
      if (!mounted || generation != _generation) {
        await connection.close();
        return;
      }
      _radio = connection;
      await connection.identify();
      final contacts = await connection.contacts();
      if (!mounted || generation != _generation) {
        await connection.close();
        return;
      }
      setState(() {
        _contacts = contacts.where((c) => c.type == 2).toList();
        _selected.clear();
        _admins.clear();
        for (final c in _contacts) {
          _passwords.putIfAbsent(c.key, TextEditingController.new);
        }
        _status = tr(
          'Select up to six saved repeaters. No RF request has been sent.',
        );
      });
    } catch (_) {
      await connection?.close();
      if (mounted && generation == _generation) {
        _radio = null;
        setState(() {
          _status = tr(
            'Could not read the companion. Check its connection and that no other client is using it.',
          );
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _start() async {
    if (_busy) return;
    final hours = int.tryParse(_hours.text);
    if (hours == null || hours < 1 || hours > 72) {
      setState(() {
        _status = tr('Enter an interval from 1 to 72 hours.');
      });
      return;
    }
    setState(() {
      _busy = true;
      _status = tr('Checking telemetry intake…');
    });
    final sharing = TelemetrySharing(
      widget.instance,
      _radio!,
      [
        for (final contact in _contacts.where((c) => _selected.contains(c.key)))
          PollTarget(
            contact,
            password: _passwords[contact.key]!.text,
            requireAdmin: _admins.contains(contact.key),
          ),
      ],
      hours,
      environment: _environment,
    );
    _sharing = sharing;
    try {
      await sharing.start();
      if (!mounted || !identical(_sharing, sharing)) {
        await sharing.stop();
        return;
      }
      _timer = Timer.periodic(
        const Duration(seconds: 20),
        (_) => unawaited(_tick()),
      );
      await _tick();
    } catch (e) {
      await sharing.stop();
      if (mounted) {
        setState(() {
          _status = e is IntakeFailure
              ? e.toString()
              : tr('Enrollment failed. No repeater was polled.');
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _tick() async {
    final sharing = _sharing;
    if (sharing == null) return;
    await sharing.step();
    if (mounted && identical(_sharing, sharing)) {
      setState(() {
        _status = sharing.status;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = _radio != null && !_radio!.closed;
    final sharing = _sharing?.running ?? false;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Telemetry sharing'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            tr('Companion telemetry · alpha'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            '${tr('Destination')}: ${widget.instance.name}\n${widget.instance.url}',
          ),
          const SizedBox(height: 12),
          Text(
            tr(
              'Share battery and optional environmental readings from repeaters you select. This server must support telemetry intake. Keep this screen open; sharing stops when you leave or background the app.',
            ),
          ),
          const SizedBox(height: 12),
          Text(
            tr(
              'Use an exclusive companion via BLE or a trusted private LAN. MeshCore TCP is unencrypted. Passwords stay in this session and are sent only to the companion; they are never uploaded to Beacon.',
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _consent,
            onChanged: connected || _busy
                ? null
                : (value) => setState(() {
                    _consent = value ?? false;
                  }),
            title: Text(
              tr(
                'I can use this companion exclusively and agree to share selected readings publicly.',
              ),
            ),
          ),
          if (!connected) ...[
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: true,
                  label: Text(tr('Bluetooth')),
                  icon: const Icon(Icons.bluetooth),
                ),
                ButtonSegment(
                  value: false,
                  label: Text(tr('Wi-Fi')),
                  icon: const Icon(Icons.wifi),
                ),
              ],
              selected: {_bleMode},
              onSelectionChanged: _busy
                  ? null
                  : (value) {
                      unawaited(_ble?.close());
                      _ble = null;
                      setState(() {
                        _bleMode = value.single;
                        _devices = [];
                      });
                    },
            ),
            if (_bleMode) ...[
              const SizedBox(height: 12),
              FilledButton(
                onPressed:
                    !_busy && _consent && widget.instance.base.scheme == 'https'
                    ? _scanBle
                    : null,
                child: Text(tr('Scan for BLE companions')),
              ),
              for (final device in _devices)
                ListTile(
                  leading: const Icon(Icons.bluetooth),
                  title: Text(device.name.isEmpty ? device.id : device.name),
                  subtitle: Text('${device.id} · ${device.rssi} dBm'),
                  onTap: _busy ? null : () => _connect(bleId: device.id),
                ),
            ] else ...[
              TextField(
                controller: _host,
                enabled: !_busy,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: tr('Companion LAN address'),
                  hintText: '192.168.1.50',
                ),
              ),
              TextField(
                controller: _port,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: tr('TCP port')),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed:
                    !_busy && _consent && widget.instance.base.scheme == 'https'
                    ? () => _connect()
                    : null,
                child: Text(tr('Connect and read contacts')),
              ),
            ],
            if (widget.instance.base.scheme != 'https')
              Text(tr('Select an HTTPS Beacon server to share telemetry.')),
          ],
          if (connected) ...[
            const SizedBox(height: 12),
            SelectableText(
              '${tr('Companion key')}: ${_radio!.radioKey}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            TextField(
              controller: _hours,
              enabled: !sharing && !_busy,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: tr('Interval per repeater (1–72 hours)'),
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _environment,
              onChanged: sharing || _busy
                  ? null
                  : (value) => setState(() {
                      _environment = value ?? false;
                    }),
              title: Text(
                tr('Include environmental sensors (including channel 2)'),
              ),
            ),
            Text(
              tr(
                'A shared budget allows at most two repeater attempts per hour. Failed attempts also consume the interval. Busy companions defer polling. No catch-up bursts.',
              ),
            ),
            if (_contacts.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  tr(
                    'No saved repeaters found. Add contacts using your normal companion client first.',
                  ),
                ),
              ),
            for (final contact in _contacts) ...[
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(contact.name),
                subtitle: Text(
                  '${contact.key.substring(0, 12)}… · ${contact.hops == null ? tr('Flood discovery') : '${contact.hops} ${tr('hops')}'}',
                ),
                value: _selected.contains(contact.key),
                onChanged: sharing || _busy
                    ? null
                    : (value) => setState(() {
                        if (value == true && _selected.length < 6) {
                          _selected.add(contact.key);
                        }
                        if (value == false) {
                          _selected.remove(contact.key);
                        }
                      }),
              ),
              if (_selected.contains(contact.key))
                Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 12),
                  child: Column(
                    children: [
                      TextField(
                        controller: _passwords[contact.key],
                        enabled: !sharing && !_busy,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: tr(
                            'Optional repeater password (session only)',
                          ),
                        ),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _admins.contains(contact.key),
                        onChanged: sharing || _busy
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  _admins.add(contact.key);
                                } else {
                                  _admins.remove(contact.key);
                                }
                              }),
                        title: Text(
                          tr('Require admin permission for this repeater'),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            FilledButton(
              onPressed: !sharing && !_busy && _selected.isNotEmpty
                  ? _start
                  : null,
              child: Text(tr('Start sharing')),
            ),
          ],
          if (connected || sharing || _busy)
            OutlinedButton(
              onPressed: _stop,
              child: Text(tr('Stop and disconnect')),
            ),
          const SizedBox(height: 16),
          Semantics(liveRegion: true, child: Text(_status)),
          if (_sharing != null && !_busy)
            Text(
              '${tr('Accepted reports')}: ${_sharing!.accepted} · ${tr('Pending')}: ${_sharing!.queued}',
            ),
        ],
      ),
    );
  }
}
