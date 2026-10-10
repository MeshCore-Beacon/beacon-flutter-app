# Native development build

This is a native Flutter port of the mobile Beacon-Web interface, using the
Beacon server API without backend changes or a WebView.

## Included workflows

- Packets: live feed, paused-scroll buffer, paginated history, payload/route/scope/
  observer filters, hash and complete-hop path search, inline observations,
  packet analyzer, raw frame fields, copy actions, and observation path map.
- Channels: keyed and public channel groups, channel history, sender colors and
  live message updates.
- Nodes and observers: filters, paging, details, advertisement history, neighbors,
  telemetry/activity charts, map links and comparison links.
- Routes and traces: regional lists, time windows, endpoint/path details and
  evidence navigation.
- Map: MapLibre Native, Beacon marker shapes, native clusters, node selection,
  neighbors, borders, live packet flow, packet paths, three basemaps and hillshade.
- Analytics: Mesh, Traffic, RF / Signal, Paths & hashes, Scopes, Talkers, Clock
  drift, Compare observers, and Neighbor graph. Charts have legends, tap values
  and accessible data tables; the graph supports selection, pan and zoom.
- Settings: persistent saved servers, add/edit/remove, server URL validation,
  immediate instance switching, source themes, English/French/Swedish labels.
- Lifecycle: foreground-only WebSocket with reconnect/backoff, region resubscribe
  and REST refresh after resume. Instance changes discard stale responses.

## Build and install

Toolchain used in CI/releases: Flutter 3.47.5 / Dart 3.13.4, Xcode 26.5 and Android SDK 36.

```sh
flutter pub get
flutter build apk --release --split-per-abi
flutter build ios --simulator --debug
```

For an ARM64 Android device, install the local development APK:

```sh
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Release-mode APKs use the repository's existing signing configuration, falling
back to the local debug key when release credentials are absent. They are dev
distributions, not Play Store releases. Do not replace a differently signed
production app without backing up its local settings.

Install the simulator app on a booted iPhone simulator:

```sh
xcrun simctl install booted build/ios/iphonesimulator/Runner.app
xcrun simctl launch booted meshcorebeacon.app
```

A simulator app cannot be installed on a physical iPhone. Signed device,
TestFlight and Play builds come from `./Build.sh`; maintainers: see the
Releases section of [CONTRIBUTING.md](../CONTRIBUTING.md).

The app declares `ITSAppUsesNonExemptEncryption=false`: it uses HTTPS/WSS
transport and displays packet decryption results returned by the server.
Review that declaration if client-side cryptography is added.

## Validation

Validation environment: iPhone 17 Pro simulator (iOS 26.5) and Pixel 7 ARM64
emulator (Android API 36), using a live Beacon server.

- All unit/widget tests pass.
- Formatting is clean; static analysis reports no issues.
- Both platforms pass main navigation, packet expansion/analyzer, settings and
  language switching, all nine analytics sections, and native map rendering with
  dark/light style switching. Live detail-screen tests cover nodes, observers,
  channels, routes and traces.
- Map checks verify actual native rendered feature counts, including native
  clustering, glyph loading and platform pixel-density handling.

```sh
dart format --set-exit-if-changed .
flutter analyze
flutter test
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/dev_smoke_test.dart -d DEVICE_ID
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/map_native_test.dart -d DEVICE_ID \
  --dart-define=BEACON_SERVER=https://your-beacon-server
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/analytics_native_test.dart -d DEVICE_ID
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/details_native_test.dart -d DEVICE_ID
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/investigation_native_test.dart -d DEVICE_ID
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/packet_resume_native_test.dart -d DEVICE_ID
```

The native tests that read live data take the server from
`--dart-define=BEACON_SERVER=<url>`; add it to every `flutter drive` command
above except the smoke test, as shown for the map test. They require network
access, perform reads only and use isolated test preferences. Screenshot
evidence is saved in `build/dev-evidence/`. Native map tests assert rendered
features, rather than accepting an empty basemap as a pass.

Unit/widget regressions cover URL validation, preferences, stale-instance
responses, HTTP errors and throttling, the real WebSocket handshake, empty
regions, paging/deduplication, retained history during live traffic, messages
arriving during fetches, filter semantics, analyzer observation selection,
foreground refresh, map feature conversion, and analytics transforms.

## Known development differences

- Native back navigation replaces drawer closing; the web minimized-drawer dock
  is not implemented.

- Native MapLibre supports hillshade through this Flutter binding, but the
  binding does not expose native 3D terrain. The app does not offer a nonworking
  terrain toggle. Co-located clusters open a selection list instead of the web
  spider layout, and live flow does not reproduce individual node glow/dimming.
- Neighbor graph layout uses a Flutter force layout; positions and physics can
  differ from the web graph. Underlying nodes, links and drill-down data use the
  same API.
- Charts preserve the source data, categories and sections, with Flutter-native
  touch tooltips and data tables. Their rendering is not a pixel-identical copy
  of the web chart library.
- Source translation catalogs are bundled. Native-only controls have fallback
  English when a translation is unavailable.
- This dev build is not a certification of every visual pixel, physical-device
  behavior or every server configuration. Physical iPhone/Android hardware,
  accessibility audits, and store distribution remain release checks.

## Artwork and fonts

Theme tokens, catalogs, logo and marker artwork come from Beacon-Web under the
project's AGPL license. Launcher PNGs are rasterizations of the Beacon logo on
the native dark background. Inter and JetBrains Mono are bundled under their
OFL licenses in `assets/fonts/`; notices are also available through Settings.
MapLibre attribution controls remain visible and basemap data/provider notices
are supplied by the selected map style.
