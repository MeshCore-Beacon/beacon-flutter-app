import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import 'core/api.dart';
import 'core/instance.dart';
import 'core/json.dart';
import 'core/live.dart';
import 'core/preferences.dart';
import 'core/region_selection.dart';
import 'core/runtime_config.dart';
import 'core/strings.dart';
import 'core/theme.dart';
import 'core/version_gate.dart';
import 'features/analytics/analytics_screen.dart';
import 'features/directory/directory.dart';
import 'features/map/map_screen.dart';
import 'features/packets/packet_detail.dart';
import 'features/packets/packet_screen.dart';
import 'features/settings/settings_page.dart';
import 'features/telemetry/session.dart';

class BeaconApp extends StatefulWidget {
  const BeaconApp({
    super.key,
    required this.preferences,
    this.connectLive = true,
    this.apiFactory,
    this.versionGate,
  });
  final Preferences preferences;
  final bool connectLive;
  final ApiClient Function(Uri)? apiFactory;

  /// Minimum-app-version checks. Defaults to one that reads `/api/v1/info`
  /// through [apiFactory].
  final VersionGate? versionGate;
  @override
  State<BeaconApp> createState() => _BeaconAppState();
}

class _BeaconAppState extends State<BeaconApp> with WidgetsBindingObserver {
  late final telemetry = TelemetrySession(widget.preferences);
  final navigator = GlobalKey<NavigatorState>();
  late final VersionGate gate =
      widget.versionGate ??
      VersionGate(fetchInfo: VersionGate.apiFetcher(widget.apiFactory));
  String? active;
  GateStatus? shown;
  @override
  void initState() {
    super.initState();
    active = widget.preferences.active?.url;
    widget.preferences.addListener(changed);
    final server = widget.preferences.active;
    if (server != null) gate.check(server);
    gate.addListener(gateChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  void changed() {
    if (language != widget.preferences.language) {
      language = widget.preferences.language;
      // tr() reads a global, so const widgets would keep the old text.
      void rebuild(Element element) {
        element.markNeedsBuild();
        element.visitChildren(rebuild);
      }

      if (mounted) (context as Element).visitChildren(rebuild);
    }
    if (active != widget.preferences.active?.url) {
      unawaited(telemetry.disconnect());
      active = widget.preferences.active?.url;
      final server = widget.preferences.active;
      // A result the server editor produced moments ago is still current.
      if (server != null) {
        gate.check(server, reuseWithin: const Duration(seconds: 3));
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        navigator.currentState?.popUntil((r) => r.isFirst);
      });
    }
    setState(() {});
  }

  void gateChanged() {
    final url = widget.preferences.active?.url;
    final status = url == null ? null : gate.resultFor(url).status;
    if (status == GateStatus.blocked && shown == GateStatus.allowed) {
      // Leave any detail screens of a server that just became blocked.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        navigator.currentState?.popUntil((r) => r.isFirst);
      });
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final server = widget.preferences.active;
    if (state == AppLifecycleState.resumed && server != null) {
      gate.check(server, keepCurrent: true);
    }
  }

  @override
  void dispose() {
    telemetry.dispose();
    WidgetsBinding.instance.removeObserver(this);
    widget.preferences.removeListener(changed);
    gate.removeListener(gateChanged);
    if (widget.versionGate == null) gate.dispose();
    super.dispose();
  }

  Widget home() {
    final server = widget.preferences.active;
    if (server == null) {
      shown = null;
      return WelcomeScreen(preferences: widget.preferences);
    }
    final result = gate.resultFor(server.url);
    shown = result.status;
    return switch (result.status) {
      GateStatus.checking => ServerCheckScreen(
        key: ValueKey('checking:${server.url}'),
        server: server,
      ),
      GateStatus.blocked => UpdateRequiredScreen(
        key: ValueKey('blocked:${server.url}'),
        preferences: widget.preferences,
        server: server,
        result: result,
      ),
      GateStatus.allowed => BeaconHome(
        key: ValueKey(active),
        preferences: widget.preferences,
        connectLive: widget.connectLive,
        apiFactory: widget.apiFactory,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    language = widget.preferences.language;
    return TelemetryScope(
      session: telemetry,
      child: VersionGateScope(
        gate: gate,
        child: MaterialApp(
          navigatorKey: navigator,
          debugShowCheckedModeBanner: false,
          title: 'BEACON',
          theme: BeaconTheme.resolve(widget.preferences.themeId),
          locale: Locale(language),
          supportedLocales: [
            for (final code in supportedLanguages) Locale(code),
          ],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: home(),
        ),
      ),
    );
  }
}

Future<void> showServerSwitcher(
  BuildContext context,
  Preferences preferences,
) async {
  final manage = await showModalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    builder: (context) => SafeArea(
      top: false,
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              tr('Servers'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          for (final s in preferences.servers)
            ListTile(
              selected: s.url == preferences.active?.url,
              leading: const Icon(Icons.dns_outlined, size: 18),
              title: Text(s.name),
              subtitle: Text(s.base.host),
              trailing: s.url == preferences.active?.url
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () async {
                Navigator.pop(context);
                await preferences.selectServer(s.url);
              },
            ),
          ListTile(
            leading: const Icon(Icons.settings_outlined, size: 20),
            title: Text(tr('Manage servers')),
            onTap: () => Navigator.pop(context, true),
          ),
        ],
      ),
    ),
  );
  if (manage == true && context.mounted) {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SettingsPage(preferences: preferences)),
    );
  }
}

/// Shown briefly while the active server's minimum app version is checked,
/// so its screens never flash before a block.
class ServerCheckScreen extends StatelessWidget {
  const ServerCheckScreen({super.key, required this.server});
  final BeaconInstance server;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SvgPicture.asset(
            'assets/logo-icon.svg',
            width: 56,
            colorFilter: ColorFilter.mode(
              Theme.of(context).colorScheme.primary,
              BlendMode.srcIn,
            ),
          ),
          const SizedBox(height: 24),
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 16),
          Text(server.name, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
  );
}

/// Replaces every screen of a server that requires a newer app version.
class UpdateRequiredScreen extends StatelessWidget {
  const UpdateRequiredScreen({
    super.key,
    required this.preferences,
    required this.server,
    required this.result,
  });
  final Preferences preferences;
  final BeaconInstance server;
  final GateResult result;
  UpdateTarget get update =>
      StoreLinks.resolve(defaultTargetPlatform, result.installerStore);
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      actions: [
        IconButton(
          tooltip: tr('Settings'),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SettingsPage(preferences: preferences),
            ),
          ),
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    ),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.system_update_outlined,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 20),
              Text(
                tr('Update BEACON to continue'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                tr(
                  'This server needs a newer version of the app. Update BEACON if you want to continue connecting to this server:',
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              SelectableText(
                server.url,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                tr('Your version: {{current}} · Needed: {{version}}')
                    .replaceAll('{{current}}', result.currentVersion ?? '')
                    .replaceAll('{{version}}', result.minAppVersion ?? ''),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: () =>
                    launchUrl(update.uri, mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(tr(update.label)),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => showServerSwitcher(context, preferences),
                icon: const Icon(Icons.dns_outlined, size: 18),
                label: Text(tr('Use another server')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.preferences});
  final Preferences preferences;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      actions: [
        IconButton(
          tooltip: tr('Settings'),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SettingsPage(preferences: preferences),
            ),
          ),
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    ),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SvgPicture.asset(
                'assets/logo-icon.svg',
                width: 80,
                colorFilter: ColorFilter.mode(
                  Theme.of(context).colorScheme.primary,
                  BlendMode.srcIn,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'BEACON',
                style: TextStyle(
                  fontSize: 30,
                  letterSpacing: 5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                tr('Connect to your mesh'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                tr(
                  'Add a Beacon server to explore live packets, channels, nodes and mesh analytics.',
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: () => showServerEditor(context, preferences),
                icon: const Icon(Icons.add, size: 18),
                label: Text(tr('Add server')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class BeaconHome extends StatefulWidget {
  const BeaconHome({
    super.key,
    required this.preferences,
    this.connectLive = true,
    this.apiFactory,
  });
  final Preferences preferences;
  final bool connectLive;
  final ApiClient Function(Uri)? apiFactory;
  @override
  State<BeaconHome> createState() => _BeaconHomeState();
}

class _BeaconHomeState extends State<BeaconHome> with WidgetsBindingObserver {
  late final ApiClient api;
  late LiveConnection live;
  StreamSubscription<Json>? liveEvents;
  late Map<String, dynamic> region;
  late RegionSelection selection;
  String tab = 'Packets';
  int revision = 0;
  RuntimeConfig config = const RuntimeConfig();
  @override
  void initState() {
    super.initState();
    final instance = widget.preferences.active!;
    api = widget.apiFactory?.call(instance.base) ?? ApiClient(instance.base);
    region = widget.preferences.regionFor(instance.url);
    selection = RegionSelection.restore(
      widget.preferences.regionSelectionFor(instance.url),
      region,
    );
    live = LiveConnection(instance.wsUri, region);
    liveEvents = live.events.listen(api.handleLiveEvent);
    if (widget.connectLive) live.start();
    WidgetsBinding.instance.addObserver(this);
    if (widget.connectLive) loadConfig();
  }

  Future<void> loadConfig() async {
    final loaded = await RuntimeConfig.load(api.base);
    if (mounted) {
      setState(() {
        config = loaded;
        if (!config.tabs.contains(tab)) tab = config.tabs.first;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    liveEvents?.cancel();
    live.dispose();
    api.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      resume();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      live.stop();
    }
  }

  /// Reconnects only once the server still accepts this app version, so a
  /// server that started requiring an update gets no WebSocket traffic.
  Future<void> resume() async {
    final gate = VersionGateScope.maybeOf(context);
    if (gate != null) {
      final result = await gate.check(
        widget.preferences.active!,
        keepCurrent: true,
      );
      if (!mounted || result.status == GateStatus.blocked) return;
    }
    if (widget.connectLive) live.start();
  }

  void open(String kind, String id) {
    if (id.isEmpty) return;
    final screen = kind == 'analytics'
        ? Scaffold(
            appBar: AppBar(title: Text(tr('Analytics'))),
            body: AnalyticsScreen(
              api: api,
              region: region,
              onOpen: open,
              initialTab: 'Compare Observers',
              observerId: id.startsWith('compare:') ? id.substring(8) : null,
            ),
          )
        : kind == 'packet'
        ? PacketDetailScreen(
            api: api,
            hash: id.split(':').first,
            initialObservationId: id.contains(':')
                ? id.substring(id.indexOf(':') + 1)
                : null,
            onOpen: open,
          )
        : kind == 'map'
        ? Scaffold(
            appBar: AppBar(title: Text(tr('Map'))),
            body: MapScreen(
              api: api,
              region: region,
              onOpen: open,
              selectedNodeId: id,
              events: live.events,
            ),
          )
        : EntityDetailScreen(
            kind: kind,
            id: id,
            api: api,
            region: region,
            onOpen: open,
            events: live.events,
          );
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> switcher() => showServerSwitcher(context, widget.preferences);

  void settings() => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => SettingsPage(preferences: widget.preferences),
    ),
  );
  Future<void> chooseRegion() async {
    final picked = await showModalBottomSheet<(RegionSelection, Json)>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SafeArea(
        top: false,
        child: RegionSheet(api: api, initial: selection),
      ),
    );
    if (!mounted || picked == null) return;
    await liveEvents?.cancel();
    live.dispose();
    selection = picked.$1;
    region = picked.$2;
    live = LiveConnection(widget.preferences.active!.wsUri, region);
    liveEvents = live.events.listen(api.handleLiveEvent);
    if (widget.connectLive) live.start();
    await widget.preferences.saveRegion(
      widget.preferences.active!.url,
      region,
      selection: selection.toJson(),
    );
    if (mounted) setState(() => revision++);
  }

  void more() => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (context) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final name in [
            'Observers',
            'Routes',
            'Traces',
            'Analytics',
          ].where(config.tabs.contains))
            ListTile(
              selected: tab == name,
              leading: Icon(switch (name) {
                'Observers' => Icons.sensors,
                'Routes' => Icons.route_outlined,
                'Traces' => Icons.timeline,
                _ => Icons.bar_chart_outlined,
              }),
              trailing: const Icon(Icons.chevron_right, size: 18),
              title: Text(
                tr(name),
                style: TextStyle(
                  color: tab == name
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                setState(() => tab = name);
              },
            ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final section = tab == 'Packets'
        ? PacketScreen(
            api: api,
            region: region,
            onOpen: open,
            events: live.events,
          )
        : tab == 'Map'
        ? MapScreen(api: api, region: region, onOpen: open, events: live.events)
        : tab == 'Analytics'
        ? AnalyticsScreen(api: api, region: region, onOpen: open)
        : DirectoryScreen(
            kind: tab.toLowerCase(),
            api: api,
            region: region,
            onOpen: open,
            events: live.events,
          );
    // The header and tab bar paint behind the status bar and home indicator
    // and pad their own content; only the section in between is inset.
    final insets = MediaQuery.paddingOf(context);
    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(
              12 + insets.left,
              insets.top,
              12 + insets.right,
              0,
            ),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: SizedBox(
              height: 51,
              child: Row(
                children: [
                  SvgPicture.asset(
                    'assets/logo-icon.svg',
                    width: 25,
                    colorFilter: ColorFilter.mode(primary, BlendMode.srcIn),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'BEACON',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.8,
                    ),
                  ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: ListenableBuilder(
                        listenable: live,
                        builder: (_, _) => FeedScope(
                          status: live.status,
                          label: selection.label,
                          onTap: chooseRegion,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    tooltip:
                        '${tr('Servers')}: ${widget.preferences.active!.name}',
                    onPressed: switcher,
                    icon: const Icon(Icons.dns_outlined, size: 19),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 40,
                    ),
                    padding: const EdgeInsets.all(5),
                  ),
                  IconButton(
                    tooltip: tr('Settings'),
                    onPressed: settings,
                    icon: const Icon(Icons.settings_outlined, size: 19),
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 40,
                    ),
                    padding: const EdgeInsets.all(5),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              removeBottom: true,
              removeLeft: true,
              removeRight: true,
              child: Padding(
                padding: EdgeInsets.only(
                  left: insets.left,
                  right: insets.right,
                ),
                child: KeyedSubtree(
                  key: ValueKey('$tab/$revision'),
                  child: section,
                ),
              ),
            ),
          ),
          Container(
            padding: EdgeInsets.only(
              left: insets.left,
              right: insets.right,
              bottom: insets.bottom,
            ),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                top: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              children: [
                for (final entry
                    in const {
                      'Packets': Icons.layers_outlined,
                      'Channels': Icons.chat_bubble_outline,
                      'Map': Icons.location_on_outlined,
                      'Nodes': Icons.hub_outlined,
                      'More': Icons.more_horiz,
                    }.entries.where(
                      (entry) => entry.key == 'More'
                          ? config.tabs.any(
                              (name) => ![
                                'Packets',
                                'Channels',
                                'Map',
                                'Nodes',
                              ].contains(name),
                            )
                          : config.tabs.contains(entry.key),
                    ))
                  Expanded(
                    child: Semantics(
                      selected: tab == entry.key,
                      button: true,
                      child: InkWell(
                        onTap: entry.key == 'More'
                            ? more
                            : () => setState(() => tab = entry.key),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                entry.value,
                                size: 21,
                                color:
                                    tab == entry.key ||
                                        (entry.key == 'More' &&
                                            ![
                                              'Packets',
                                              'Channels',
                                              'Map',
                                              'Nodes',
                                            ].contains(tab))
                                    ? primary
                                    : Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.color,
                              ),
                              const SizedBox(height: 3),
                              Text(
                                tr(entry.key),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: tab == entry.key
                                      ? primary
                                      : Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.color,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What the feed covers and whether it is live: one tap target in the header
/// that opens the region picker.
class FeedScope extends StatelessWidget {
  const FeedScope({
    super.key,
    required this.status,
    required this.label,
    required this.onTap,
  });
  final String status, label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = BeaconColors.of(context);
    final color = switch (status) {
      'live' => palette.success,
      'connecting' => palette.warning,
      _ => palette.muted,
    };
    final state = tr(switch (status) {
      'live' => 'LIVE',
      'connecting' => 'Connecting',
      _ => 'OFFLINE',
    });
    final hint = '$state\n${tr('Region')}: $label';
    return Tooltip(
      message: hint,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: hint,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                    boxShadow: [
                      if (status == 'live')
                        BoxShadow(
                          color: color.withValues(alpha: .35),
                          spreadRadius: 3,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                    ),
                  ),
                ),
                Icon(Icons.expand_more, size: 16, color: palette.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RegionSheet extends StatefulWidget {
  const RegionSheet({super.key, required this.api, required this.initial});
  final ApiClient api;
  final RegionSelection initial;
  @override
  State<RegionSheet> createState() => _RegionSheetState();
}

/// Grouped multi-select matching beacon-web's region picker: All, then
/// regions (each a single choice that stands for its member areas), then
/// individual areas.
class _RegionSheetState extends State<RegionSheet> {
  List<Json> regions = [], airports = [];
  final members = <String, List<String>>{};
  late final Set<String> pickedRegions = {...widget.initial.regions};
  late final Set<String> pickedAreas = {...widget.initial.areas};
  String query = '';
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final responses = await Future.wait([
        widget.api.getCached('/regions'),
        widget.api.getCached('/iatas'),
      ]);
      final list = rows(responses[0]);
      // Member codes for every region, so rows can match on a code; one that
      // fails just doesn't match by code.
      await Future.wait(
        list.map((r) async {
          try {
            final data = object(
              await widget.api.getCached(
                '/regions/${Uri.encodeComponent(textOf(r['id']))}',
              ),
            );
            members[textOf(
              r['slug'],
            )] = (data['iatas'] is List ? data['iatas'] as List : const [])
                .map((e) => e is Map ? textOf(e['iata']) : '$e')
                .toList();
          } catch (_) {}
        }),
      );
      if (mounted) {
        setState(() {
          regions = list;
          airports = rows(responses[1]);
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void done() {
    final picked = RegionSelection(
      regions: {...pickedRegions},
      areas: {...pickedAreas},
    );
    Navigator.pop(context, (picked, picked.toParams(members)));
  }

  Widget heading(String text, {bool divided = false}) => Container(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    decoration: divided
        ? BoxDecoration(
            border: Border(
              top: BorderSide(color: BeaconColors.of(context).borderSubtle),
            ),
          )
        : null,
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 10,
        letterSpacing: .8,
        color: BeaconColors.of(context).muted,
      ),
    ),
  );

  /// [title] gets the row's text colour: picked rows read brighter, as on the
  /// web, rather than in the tile's accent.
  Widget choice({
    required bool checked,
    required VoidCallback onTap,
    required Widget Function(Color color) title,
    Widget? subtitle,
  }) {
    final palette = BeaconColors.of(context);
    return CheckboxListTile(
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      visualDensity: VisualDensity.compact,
      value: checked,
      selected: checked,
      tileColor: Colors.transparent,
      selectedTileColor: palette.primary.withValues(alpha: .10),
      onChanged: (_) => onTap(),
      title: title(checked ? palette.bright : palette.normal),
      subtitle: subtitle,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = BeaconColors.of(context);
    final q = query.trim().toLowerCase();
    // A region matches on its name or on member codes; a code match shows
    // which codes, so the row doesn't look like a stray result.
    final shownRegions = [
      for (final r in regions)
        if (q.isEmpty || textOf(r['name']).toLowerCase().contains(q))
          (r, const <String>[])
        else if ((members[textOf(r['slug'])] ?? const <String>[])
                .where((code) => code.toLowerCase().contains(q))
                .toList()
            case final matched when matched.isNotEmpty)
          (r, matched),
    ];
    final shownAreas = airports
        .where(
          (a) =>
              q.isEmpty ||
              textOf(a['iata']).toLowerCase().contains(q) ||
              textOf(a['displayName']).toLowerCase().contains(q),
        )
        .toList();
    final allLabel = trKey('region.allRegions');
    final showAll = q.isEmpty || allLabel.toLowerCase().contains(q);
    final isAll = pickedRegions.isEmpty && pickedAreas.isEmpty;
    final code = TextStyle(
      fontFamily: 'JetBrainsMono',
      fontWeight: FontWeight.w600,
      color: palette.primary,
    );
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: [
                Text(
                  tr('Region'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                TextButton(
                  onPressed: loading ? null : done,
                  child: Text(tr('Done')),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              decoration: InputDecoration(
                hintText: tr('Search region or area code…'),
                prefixIcon: const Icon(Icons.search, size: 18),
              ),
              onChanged: (v) => setState(() => query = v),
            ),
          ),
          const SizedBox(height: 6),
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            TextButton(
              onPressed: load,
              child: Text('${tr('$error')} · ${tr('Retry')}'),
            ),
          Expanded(
            child: ListView(
              children: [
                if (showAll)
                  ListTile(
                    dense: true,
                    selected: isAll,
                    selectedTileColor: palette.primary.withValues(alpha: .10),
                    // Lines ALL up with the checkbox rows below.
                    leading: const SizedBox(width: 24),
                    title: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: '${tr('ALL')}   ', style: code),
                          TextSpan(
                            text: allLabel,
                            style: TextStyle(color: palette.muted),
                          ),
                        ],
                      ),
                    ),
                    onTap: () => setState(() {
                      pickedRegions.clear();
                      pickedAreas.clear();
                    }),
                  ),
                if (shownRegions.isNotEmpty) ...[
                  heading(trKey('region.group')),
                  for (final (r, matched) in shownRegions)
                    choice(
                      checked: pickedRegions.contains(textOf(r['slug'])),
                      onTap: () => setState(() {
                        final slug = textOf(r['slug']);
                        if (!pickedRegions.remove(slug)) {
                          pickedRegions.add(slug);
                        }
                      }),
                      title: (color) => Text(
                        textOf(r['name']),
                        style: TextStyle(color: color),
                      ),
                      subtitle: matched.isEmpty
                          ? null
                          : Text(
                              matched.join(', '),
                              style: const TextStyle(
                                fontFamily: 'JetBrainsMono',
                              ),
                            ),
                    ),
                ],
                if (shownAreas.isNotEmpty) ...[
                  heading(
                    trKey('region.areaGroup'),
                    divided: showAll || shownRegions.isNotEmpty,
                  ),
                  for (final a in shownAreas)
                    choice(
                      checked: pickedAreas.contains(textOf(a['iata'])),
                      onTap: () => setState(() {
                        final iata = textOf(a['iata']);
                        if (!pickedAreas.remove(iata)) pickedAreas.add(iata);
                      }),
                      title: (color) => Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: '${a['iata']}   ', style: code),
                            TextSpan(
                              text: textOf(a['displayName'], textOf(a['iata'])),
                              style: TextStyle(color: color),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
                if (!loading &&
                    !showAll &&
                    shownRegions.isEmpty &&
                    shownAreas.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      trKey('region.noMatches'),
                      style: TextStyle(color: palette.muted),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
