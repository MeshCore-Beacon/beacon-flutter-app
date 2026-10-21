import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/instance.dart';
import '../../core/strings.dart';
import 'background_choice.dart';
import 'ble_companion.dart';
import 'companion.dart';
import 'session.dart';
import 'sharing.dart';

class TelemetryPage extends StatefulWidget {
  const TelemetryPage({
    super.key,
    required this.instance,
    required this.session,
  });
  final BeaconInstance instance;
  final TelemetrySession session;
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
  Future<void>? _stopping;
  bool _busy = false, _consent = false, _environment = false;
  int _generation = 0;
  String _status = '', _search = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(_sessionChanged);
  }

  void _sessionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Permission/pairing dialogs are transient inactive states. Only the app
    // session can keep an enrolled connection alive after an actual background exit.
    if (!widget.session.backgroundActive &&
        (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached)) {
      unawaited(_stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(_sessionChanged);
    if (!widget.session.active) unawaited(_stop());
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
    // Take ownership before yielding; a cancelled attempt must not close a new link.
    final radio = _radio, ble = _ble;
    _radio = null;
    _ble = null;
    await widget.session.disconnect();
    await radio?.close();
    await ble?.close();
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
    if (_busy || widget.session.stopping) return;
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
    if (_busy || widget.session.stopping) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _status = tr('Connecting to companion…');
    });
    Companion? connection;
    var stage = 'transport';
    try {
      connection = bleId == null
          ? await Companion.connect(_host.text, int.tryParse(_port.text) ?? 0)
          : await _ble!.connect(bleId);
      if (!mounted || generation != _generation) {
        await connection.close();
        return;
      }
      _radio = connection;
      stage = 'identity';
      setState(() {
        _status = tr('Connected. Reading companion identity…');
      });
      await connection.identify();
      if (!mounted || generation != _generation) {
        await connection.close();
        return;
      }
      stage = 'contacts';
      if (mounted) {
        setState(() {
          _status = tr('Reading saved repeaters…');
        });
      }
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
    } catch (error) {
      // Stage/type only: device-info frames contain the BLE PIN, so never log frames or exception payloads.
      debugPrint('[telemetry] setup $stage failed (${error.runtimeType})');
      await connection?.close();
      if (mounted && generation == _generation) {
        _radio = null;
        setState(() {
          _status = stage == 'transport'
              ? tr(
                  'Could not connect. Check pairing and that no other app is using this companion.',
                )
              : stage == 'identity'
              ? tr(
                  'Bluetooth or Wi-Fi connected, but the companion did not finish identification. Reconnect and try again.',
                )
              : tr(
                  'Connected, but saved contacts could not be read. Reconnect and check companion firmware compatibility.',
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
    if (!await chooseTelemetryBackground(
          context,
          widget.session.preferences,
          supported: widget.session.background.supported,
        ) ||
        !mounted) {
      return;
    }
    if (_radio == null || _radio!.closed) return;
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
    try {
      await widget.session.start(
        sharing,
        transport: _bleMode ? 'BLE' : 'Wi-Fi',
      );
      // The active session owns passwords now. Do not leave extra copies in UI controllers.
      if (mounted) {
        for (final controller in _passwords.values) {
          controller.clear();
        }
      }
    } catch (e) {
      await sharing.stop();
      if (mounted) {
        setState(() {
          _status = e is IntakeFailure
              ? e.toString()
              : tr(
                  'Collection could not start. Check notification permission and the companion, or choose foreground collection.',
                );
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

  Future<void> _select(CompanionContact contact, bool selected) async {
    if (selected && _selected.length >= 6) return;
    if (selected && widget.session.preferences.telemetryBackground == null) {
      setState(() {
        _busy = true;
      });
      try {
        if (!await chooseTelemetryBackground(
          context,
          widget.session.preferences,
          supported: widget.session.background.supported,
        )) {
          return;
        }
      } finally {
        if (mounted) {
          setState(() {
            _busy = false;
          });
        }
      }
      if (!mounted || _radio == null || _radio!.closed) return;
    }
    setState(() {
      if (selected) {
        _selected.add(contact.key);
      } else {
        _selected.remove(contact.key);
      }
    });
  }

  Widget _panel(String title, List<Widget> children) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11,
              letterSpacing: 1,
              color: colors.primary,
            ),
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  Future<void> _about() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr('About telemetry sharing')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr(
                'Share battery and optional environmental readings from repeaters you select. This server must support telemetry intake. Android offers optional background collection while your companion stays connected.',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              tr(
                'Use an exclusive companion via BLE or a trusted private LAN. MeshCore TCP is unencrypted. Passwords stay in this session and are sent only to the companion; they are never uploaded to Beacon.',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              tr(
                'A shared budget allows at most two repeater attempts per hour. Failed attempts also consume the interval. Busy companions defer polling. No catch-up bursts.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('Close')),
        ),
      ],
    ),
  );

  Future<void> _editAccess(CompanionContact contact) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            MediaQuery.viewInsetsOf(context).bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                contact.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              SelectableText(
                contact.key,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwords[contact.key],
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: tr('Optional repeater password (session only)'),
                ),
              ),
              const SizedBox(height: 12),
              FilterChip(
                label: Text(tr('Require admin permission for this repeater')),
                selected: _admins.contains(contact.key),
                onSelected: (value) => update(() {
                  if (value) {
                    _admins.add(contact.key);
                  } else {
                    _admins.remove(contact.key);
                  }
                }),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr('Done')),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _chooseBackground() async {
    await chooseTelemetryBackground(
      context,
      widget.session.preferences,
      supported: widget.session.background.supported,
      edit: true,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final current = session.sharing;
    final connected =
        _radio != null && !_radio!.closed && _radio!.radioKey != null && !_busy;
    final canConnect =
        !_busy &&
        !session.stopping &&
        _consent &&
        widget.instance.base.scheme == 'https';
    final contacts = _contacts
        .where(
          (contact) =>
              contact.name.toLowerCase().contains(_search) ||
              contact.key.contains(_search),
        )
        .toList();
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Telemetry sharing')),
        actions: [
          IconButton(
            onPressed: _about,
            icon: const Icon(Icons.info_outline),
            tooltip: tr('About telemetry sharing'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _panel(tr('Destination'), [
            Text(
              current?.instance.name ?? widget.instance.name,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            SelectableText(
              current?.instance.url ?? widget.instance.url,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (current == null)
              TextButton.icon(
                onPressed: _busy ? null : _chooseBackground,
                icon: const Icon(Icons.settings_outlined),
                label: Text(
                  session.background.supported &&
                          session.preferences.telemetryBackground == true
                      ? tr('Enabled with ongoing notification')
                      : tr('Only while using Beacon'),
                ),
              ),
          ]),
          if (current != null) ...[
            _panel(
              session.starting
                  ? tr('Preparing telemetry collection')
                  : current.paused
                  ? tr('Telemetry polling stopped')
                  : tr('Telemetry polling active'),
              [
                Text('${session.transport} · ${tr('Companion connected')}'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    for (final entry in <String, int>{
                      tr('Selected repeaters'): current.targets.length,
                      tr('Accepted reports'): current.accepted,
                      tr('Pending'): current.queued,
                      tr('Interval (hours)'): current.hours,
                    }.entries)
                      SizedBox(
                        width: 128,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.key,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            Text(
                              '${entry.value}',
                              style: TextStyle(
                                fontFamily: 'JetBrainsMono',
                                fontSize: 22,
                                color: colors.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    session.status,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (!session.starting)
                      FilledButton.tonalIcon(
                        onPressed: current.paused
                            ? session.resume
                            : session.pause,
                        icon: Icon(
                          current.paused ? Icons.play_arrow : Icons.pause,
                        ),
                        label: Text(
                          current.paused
                              ? tr('Resume polling')
                              : tr('Stop polling'),
                        ),
                      ),
                    OutlinedButton.icon(
                      onPressed: _stop,
                      icon: const Icon(Icons.link_off),
                      label: Text(tr('Stop and disconnect')),
                    ),
                  ],
                ),
                if (session.backgroundActive)
                  FilterChip(
                    label: Text(tr('Show collection stats in notification')),
                    selected: session.preferences.telemetryNotificationStats,
                    onSelected: (value) async {
                      await session.preferences.setTelemetryNotificationStats(
                        value,
                      );
                      await session.tick();
                    },
                  ),
                Text(
                  session.backgroundActive
                      ? tr('Background telemetry')
                      : tr('Foreground telemetry'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ] else ...[
            _panel(tr('Companion'), [
              if (_status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _status,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              if (_busy) ...[
                const LinearProgressIndicator(),
                TextButton(onPressed: _stop, child: Text(tr('Cancel'))),
              ],
              if (connected) ...[
                Row(
                  children: [
                    const Icon(Icons.check_circle_outline, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${_bleMode ? tr('Bluetooth') : tr('Wi-Fi')} · ${tr('Companion connected')}',
                      ),
                    ),
                    IconButton(
                      onPressed: _stop,
                      tooltip: tr('Stop and disconnect'),
                      icon: const Icon(Icons.link_off),
                    ),
                  ],
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    tr('Companion key'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  children: [
                    SelectableText(
                      _radio!.radioKey!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ] else if (!_busy) ...[
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
                  onSelectionChanged: (value) {
                    unawaited(_ble?.close());
                    _ble = null;
                    setState(() {
                      _bleMode = value.single;
                      _devices = [];
                    });
                  },
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilterChip(
                    label: Text(tr('Allow telemetry sharing')),
                    selected: _consent,
                    onSelected: (value) => setState(() {
                      _consent = value;
                    }),
                  ),
                ),
                Text(
                  tr('Selected readings will be public.'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                if (_bleMode) ...[
                  FilledButton.icon(
                    onPressed: canConnect ? _scanBle : null,
                    icon: const Icon(Icons.bluetooth_searching),
                    label: Text(tr('Scan for BLE companions')),
                  ),
                  for (final device in _devices)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.bluetooth, size: 20),
                      title: Text(
                        device.name.isEmpty ? device.id : device.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${device.id} · ${device.rssi} dBm',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: canConnect
                          ? () => _connect(bleId: device.id)
                          : null,
                    ),
                ] else ...[
                  TextField(
                    controller: _host,
                    autocorrect: false,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: tr('Companion LAN address'),
                      hintText: '192.168.1.50',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: tr('TCP port'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: canConnect ? () => _connect() : null,
                    icon: const Icon(Icons.link),
                    label: Text(tr('Connect and read contacts')),
                  ),
                ],
                if (widget.instance.base.scheme != 'https')
                  Text(tr('Select an HTTPS Beacon server to share telemetry.')),
              ],
            ]),
            if (connected) ...[
              _panel('${tr('Selected repeaters')} · ${_selected.length}/6', [
                TextField(
                  onChanged: (value) => setState(() {
                    _search = value.trim().toLowerCase();
                  }),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search),
                    hintText: tr('Search saved repeaters'),
                  ),
                ),
                const SizedBox(height: 8),
                if (_contacts.isEmpty)
                  Text(
                    tr(
                      'No saved repeaters found. Add contacts using your normal companion client first.',
                    ),
                  ),
                SizedBox(
                  height: contacts.length < 5 ? contacts.length * 60.0 : 300,
                  child: ListView.builder(
                    itemCount: contacts.length,
                    itemBuilder: (context, index) {
                      final contact = contacts[index],
                          selected = _selected.contains(contacts[index].key);
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          selected
                              ? Icons.check_circle
                              : Icons.add_circle_outline,
                          color: selected
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                        title: Text(
                          contact.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${contact.key.substring(0, 12)}…',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        onTap: () => _select(contact, !selected),
                        trailing: selected
                            ? IconButton(
                                onPressed: () => _editAccess(contact),
                                icon: Icon(
                                  _passwords[contact.key]!.text.isEmpty
                                      ? Icons.key_outlined
                                      : Icons.key,
                                ),
                                tooltip: tr('Optional repeater access'),
                              )
                            : null,
                      );
                    },
                  ),
                ),
              ]),
              _panel(tr('Polling settings'), [
                TextField(
                  controller: _hours,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: tr('Interval per repeater (1–72 hours)'),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ChoiceChip(
                      label: Text(tr('Battery')),
                      selected: !_environment,
                      onSelected: (_) => setState(() {
                        _environment = false;
                      }),
                    ),
                    ChoiceChip(
                      label: Text(tr('Battery + environment')),
                      selected: _environment,
                      onSelected: (_) => setState(() {
                        _environment = true;
                      }),
                    ),
                  ],
                ),
                if (session.background.supported &&
                    session.preferences.telemetryBackground == true)
                  FilterChip(
                    label: Text(tr('Show collection stats in notification')),
                    selected: session.preferences.telemetryNotificationStats,
                    onSelected: (value) async {
                      await session.preferences.setTelemetryNotificationStats(
                        value,
                      );
                      if (mounted) setState(() {});
                    },
                  ),
              ]),
              FilledButton.icon(
                onPressed: _selected.isNotEmpty ? _start : null,
                icon: const Icon(Icons.play_arrow),
                label: Text(tr('Start sharing')),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
