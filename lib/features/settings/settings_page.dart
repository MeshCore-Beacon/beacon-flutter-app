import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/instance.dart';
import '../../core/preferences.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import '../../core/version_gate.dart';
import '../telemetry/telemetry_page.dart';

/// "Version 0.2.0" for releases, "Beta build 1791597587" for dev/beta builds.
String versionLabel(String? version) {
  if (version == null || version.isEmpty) return '';
  return parseVersion(version) != null
      ? '${tr('Version')} $version'
      : '${tr('Beta build')} $version';
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.preferences,
    this.appVersion = VersionGate.platformVersion,
  });
  final Preferences preferences;
  final Future<String?> Function() appVersion;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preferences,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(tr('Settings'))),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          _heading(context, tr('Servers')),
          for (final server in preferences.servers)
            ListTile(
              selected: server.url == preferences.active?.url,
              leading: Icon(
                server.url == preferences.active?.url
                    ? Icons.check_circle_outline
                    : Icons.dns_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(server.name),
              subtitle: Text(
                server.url,
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11,
                ),
              ),
              onTap: () => preferences.selectServer(server.url),
              trailing: IconButton(
                tooltip: tr('Edit'),
                icon: const Icon(Icons.edit_outlined, size: 19),
                onPressed: () =>
                    showServerEditor(context, preferences, server: server),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.add, size: 20),
            title: Text(tr('Add server')),
            onTap: () => showServerEditor(context, preferences),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.sensors_outlined),
            title: Text(tr('Telemetry sharing')),
            subtitle: Text(tr('Optional companion polling · alpha')),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: preferences.active == null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          TelemetryPage(instance: preferences.active!),
                    ),
                  ),
          ),
          const Divider(),
          _heading(context, tr('Appearance')),
          ListTile(
            key: const ValueKey('theme-picker'),
            leading: const Icon(Icons.palette_outlined, size: 21),
            title: Text(tr('Theme')),
            subtitle: Text(
              BeaconTheme.all
                      .where((e) => e.id == preferences.themeId)
                      .firstOrNull
                      ?.name ??
                  'Neutral Blue',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _pickTheme(context),
          ),
          ListTile(
            key: const ValueKey('language-picker'),
            leading: const Icon(Icons.language, size: 21),
            title: Text(tr('Language')),
            subtitle: Text(languages[preferences.language] ?? 'English'),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _pickLanguage(context),
          ),
          const SizedBox(height: 12),
          const Divider(),
          _heading(context, tr('About')),
          _VersionTile(appVersion: appVersion),
          ListTile(
            title: const Text('GitHub'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => launchUrl(
              Uri.parse(
                'https://github.com/MeshCore-Beacon/beacon-flutter-app',
              ),
              mode: LaunchMode.externalApplication,
            ),
          ),
          ListTile(
            title: Text(tr('Licenses')),
            onTap: () =>
                showLicensePage(context: context, applicationName: 'BEACON'),
          ),
        ],
      ),
    ),
  );
  static const languages = {'en': 'English', 'fr': 'Français', 'sv': 'Svenska'};

  Future<void> _pickTheme(BuildContext context) async {
    final value = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        top: false,
        child: FractionallySizedBox(
          heightFactor: .75,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  tr('Theme'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final theme in BeaconTheme.all)
                      ListTile(
                        selected: preferences.themeId == theme.id,
                        leading: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: theme.color('primary', '#3B82F6'),
                            shape: BoxShape.circle,
                          ),
                        ),
                        title: Text(theme.name),
                        trailing: preferences.themeId == theme.id
                            ? const Icon(Icons.check, size: 20)
                            : null,
                        onTap: () => Navigator.pop(context, theme.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (value != null) await preferences.setTheme(value);
  }

  Future<void> _pickLanguage(BuildContext context) async {
    final value = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                tr('Language'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final entry in languages.entries)
              ListTile(
                selected: preferences.language == entry.key,
                title: Text(entry.value),
                trailing: preferences.language == entry.key
                    ? const Icon(Icons.check, size: 20)
                    : null,
                onTap: () => Navigator.pop(context, entry.key),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (value != null) await preferences.setLanguage(value);
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 11,
        letterSpacing: .8,
        color: BeaconColors.of(context).bright,
      ),
    ),
  );
}

Future<void> showServerEditor(
  BuildContext context,
  Preferences preferences, {
  BeaconInstance? server,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => SafeArea(
      top: false,
      child: ServerEditor(preferences: preferences, server: server),
    ),
  );
}

class ServerEditor extends StatefulWidget {
  const ServerEditor({super.key, required this.preferences, this.server});
  final Preferences preferences;
  final BeaconInstance? server;
  @override
  State<ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends State<ServerEditor> {
  late final name = TextEditingController(text: widget.server?.name ?? '');
  late final url = TextEditingController(text: widget.server?.url ?? '');
  bool busy = false;
  String? error;
  bool canSaveOffline = false;
  @override
  void dispose() {
    name.dispose();
    url.dispose();
    super.dispose();
  }

  Future<void> save({bool offline = false}) async {
    BeaconInstance server;
    try {
      server = BeaconInstance.create(name.text, url.text);
    } on FormatException catch (e) {
      setState(() => error = e.message);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final gate = VersionGateScope.maybeOf(context);
    final api = ApiClient(server.base);
    try {
      // A server that needs a newer app gets no further requests; saving it
      // makes the app show its "Update BEACON to continue" screen.
      final blocked =
          !offline &&
          gate != null &&
          (await gate.check(server, keepCurrent: true)).status ==
              GateStatus.blocked;
      if (!offline && !blocked) {
        final result = await api.get('/iatas');
        if (result is! List) {
          throw const ApiException(
            'This server does not appear to expose the Beacon API.',
          );
        }
      }
      await widget.preferences.saveServer(
        server,
        replacing: widget.server?.url,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          canSaveOffline = true;
        });
      }
    } finally {
      api.close();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      0,
      20,
      MediaQuery.viewInsetsOf(context).bottom + 24,
    ),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr(widget.server == null ? 'Add server' : 'Edit server'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: name,
            decoration: InputDecoration(
              labelText: tr('Name'),
              hintText: 'Beacon development',
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: tr('Server URL'),
              hintText: 'https://beacon-server.com',
            ),
            onSubmitted: (_) => busy ? null : save(),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                tr(error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: busy ? null : () => save(),
            child: Text(busy ? tr('Connecting…') : tr('Save')),
          ),
          if (canSaveOffline)
            TextButton(
              onPressed: busy ? null : () => save(offline: true),
              child: Text(tr('Save offline')),
            ),
          if (widget.server != null)
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      await widget.preferences.removeServer(widget.server!.url);
                      if (context.mounted) Navigator.pop(context);
                    },
              child: Text(
                tr('Remove server'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
  );
}

class _VersionTile extends StatefulWidget {
  const _VersionTile({required this.appVersion});
  final Future<String?> Function() appVersion;
  @override
  State<_VersionTile> createState() => _VersionTileState();
}

class _VersionTileState extends State<_VersionTile> {
  late final Future<String?> _version = widget.appVersion().catchError(
    (_) => null,
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: _version,
    builder: (context, snapshot) {
      final label = versionLabel(snapshot.data);
      return ListTile(
        key: const ValueKey('about-version'),
        title: const Text('BEACON'),
        subtitle: Text(
          [
            if (label.isNotEmpty) label,
            tr('Native MeshCore packet analyzer'),
          ].join('\n'),
        ),
      );
    },
  );
}
