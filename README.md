# BEACON Mobile

Native iOS and Android client for Beacon, the real-time MeshCore packet
analyzer. Built with Flutter, it reads the same REST API and WebSocket feed as
[beacon-web](https://github.com/MeshCore-Beacon/beacon-web), served by
[beacon-server](https://github.com/MeshCore-Beacon/beacon-server).

The app has no built-in server: add the URL of a Beacon server on first
launch, such as your own self-hosted one. Manage saved servers, theme and
language in Settings; the server button in the header switches between them.

The app includes Packets, Channels, Map, Nodes, Observers, Routes, Traces, and
all nine Analytics sections. It uses native Flutter widgets and MapLibre Native.
See [development validation](docs/development.md) for test coverage, install
commands, and remaining differences from Beacon-Web.

An optional [telemetry-sharing alpha](docs/telemetry-sharing.md) supports BLE and
Wi-Fi/TCP companions with a compatible Beacon intake. It is foreground-only and
keeps the headless Collector as an alternate client.

## Local Development

Install the [Flutter SDK](https://docs.flutter.dev/get-started/install), then:

```bash
flutter pub get
flutter run          # on a connected device or running emulator/simulator
```

Running a beacon-server to point the app at is covered in the
[shared contributor guide](https://github.com/MeshCore-Beacon/beacon-docs/blob/main/CONTRIBUTING.md#running-the-full-stack-locally).

### Commands

| Command | Description |
|---|---|
| `flutter run` | Run the app on a device or emulator |
| `flutter analyze` | Static analysis and lint |
| `dart format .` | Format the code |
| `flutter test` | Run tests |
| `flutter build apk` / `flutter build ios` | Build a release for Android / iOS |
| `./Build.sh` | Maintainers: signed APK, AAB and IPA in one go (see [Releases](CONTRIBUTING.md#releases)) |

## Architecture

- **Same contract as web**: every REST, packet and WebSocket shape comes from
  the [API contract](https://github.com/MeshCore-Beacon/beacon-docs/blob/main/docs/api-contract.md).
- **Foreground-only WebSocket**: iOS suspension and Android battery saver kill
  background sockets, so the app closes the WebSocket when backgrounded, then
  reopens, resubscribes and backfills over REST on return. See
  [Mobile-specific concerns](https://github.com/MeshCore-Beacon/beacon-docs/blob/main/docs/api-contract.md#mobile-specific-concerns).

## Documentation

- [API contract](https://github.com/MeshCore-Beacon/beacon-docs/blob/main/docs/api-contract.md): every REST, packet and WebSocket shape this app consumes
- [High level design](https://github.com/MeshCore-Beacon/beacon-docs/blob/main/docs/high-level-design.md)
- [Contributing](CONTRIBUTING.md), and the [shared workflow](https://github.com/MeshCore-Beacon/beacon-docs/blob/main/CONTRIBUTING.md) for branches, commits and releases

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). All contributors are welcome; please
also read the [Code of Conduct](CODE_OF_CONDUCT.md). To report a security issue,
see [SECURITY.md](SECURITY.md).

## License

Licensed under the GNU Affero General Public License v3.0 or later
(AGPL-3.0-or-later). See [LICENSE](LICENSE) for the full text and
[CONTRIBUTORS.md](CONTRIBUTORS.md) for acknowledgements.
