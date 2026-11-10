import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/preferences.dart';
import 'atlas.dart';
import 'atlas_widgets.dart';

/// Where an Atlas file is read from and saved to.
abstract class AtlasFiles {
  /// The picked file's text; null when the user backed out, empty when it is too large.
  Future<String?> pick();

  /// False when the user backed out.
  Future<bool> save(String name, String text);
}

class DeviceAtlasFiles implements AtlasFiles {
  const DeviceAtlasFiles();
  @override
  Future<String?> pick() async {
    // Android file providers often report .json as a generic type and grey it
    // out under a json filter; the file is validated either way.
    final android = defaultTargetPlatform == TargetPlatform.android;
    final file = await FilePicker.pickFile(
      type: android ? FileType.any : FileType.custom,
      allowedExtensions: android ? null : const ['json'],
    );
    if (file == null) return null;
    if ((file.lengthSync() ?? 0) > atlasFileMaxBytes) return '';
    final bytes = await file.readAsBytes();
    return bytes.length > atlasFileMaxBytes
        ? ''
        : utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<bool> save(String name, String text) async =>
      await FilePicker.saveFile(
        fileName: name,
        bytes: utf8.encode(text),
        mimeType: 'application/json',
      ) !=
      null;
}

/// Export and Import for the active server's Atlas, shown in Settings.
class AtlasSettings extends StatelessWidget {
  const AtlasSettings({
    super.key,
    required this.preferences,
    this.files = const DeviceAtlasFiles(),
  });
  final Preferences preferences;
  final AtlasFiles files;

  void _say(BuildContext context, String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _export(BuildContext context, SavedAtlas saved) async {
    try {
      final done = await files.save(atlasFileName(), atlasFile(saved));
      if (done && context.mounted) _say(context, at('exported'));
    } catch (_) {
      if (context.mounted) _say(context, at('exportFailed'));
    }
  }

  Future<void> _import(BuildContext context, String url) async {
    String? text;
    try {
      text = await files.pick();
    } catch (_) {
      text = '';
    }
    if (text == null || !context.mounted) return;
    final result = readAtlasFile(text);
    if (result == null || result.atlas.pins.isEmpty) {
      return _say(context, at('importInvalid'));
    }
    // Import replaces the whole Atlas, so a non-empty one asks first.
    final current = parseAtlas(preferences.atlasFor(url)).pins.length;
    if (current > 0) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(at('importTitle')),
          content: Text(
            at(
              'importConfirm',
              count: current,
              args: {'incoming': result.atlas.pins.length},
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(at('importCancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(at('importReplace')),
            ),
          ],
        ),
      );
      if (replace != true || !context.mounted) return;
    }
    await preferences.saveAtlas(url, result.atlas.encode());
    if (!context.mounted) return;
    _say(
      context,
      [
        at('imported', count: result.atlas.pins.length),
        if (result.skipped > 0) at('importSkipped', count: result.skipped),
      ].join(' '),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preferences.atlasRevision,
    builder: (context, _) {
      final server = preferences.active;
      if (server == null) return const SizedBox();
      final saved = parseAtlas(preferences.atlasFor(server.url));
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              at('settingsFor', args: {'name': server.name}),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          ListTile(
            key: const ValueKey('atlas-export'),
            enabled: saved.pins.isNotEmpty,
            leading: const Icon(Icons.file_upload_outlined, size: 21),
            title: Text(at('export')),
            subtitle: Text(at('exportHelp')),
            onTap: () => _export(context, saved),
          ),
          ListTile(
            key: const ValueKey('atlas-import'),
            leading: const Icon(Icons.file_download_outlined, size: 21),
            title: Text(at('import')),
            subtitle: Text(at('importHelp')),
            onTap: () => _import(context, server.url),
          ),
        ],
      );
    },
  );
}
