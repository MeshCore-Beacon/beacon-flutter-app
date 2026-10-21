# Shoulders

Beacon Mobile stands on the shoulders of giants. Thank you to the following open source
projects that make this possible. Add new dependencies here in the PR that introduces them.

## Core

- [Flutter](https://flutter.dev): UI toolkit for iOS and Android
- [Dart](https://dart.dev): the language
- [flutter_localizations](https://api.flutter.dev/flutter/flutter_localizations/): built-in
  Material and Cupertino strings in French and Swedish
- [http](https://pub.dev/packages/http): REST requests
- [shared_preferences](https://pub.dev/packages/shared_preferences): saved servers and settings
- [url_launcher](https://pub.dev/packages/url_launcher): opening links and store pages
- [package_info_plus](https://pub.dev/packages/package_info_plus): app version for the
  server compatibility check
- [cryptography](https://pub.dev/packages/cryptography) (Apache-2.0): Ed25519 telemetry enrollment and report signatures
- [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) (BSD-3-Clause): client identity, persistent polling limits and pending reports in platform secure storage
- [flutter_blue_plus](https://pub.dev/packages/flutter_blue_plus/versions/1.36.8) (BSD-3-Clause): foreground BLE companion discovery and connection, pinned to MeshMapper’s version
- [permission_handler](https://pub.dev/packages/permission_handler) (MIT): explicit Bluetooth permission requests
- [device_info_plus](https://pub.dev/packages/device_info_plus) (BSD-3-Clause): select the correct Android Bluetooth permissions by OS API level; no device information is uploaded

## Map and charts

- [MapLibre Native](https://maplibre.org) via
  [maplibre_gl](https://pub.dev/packages/maplibre_gl): the map
- [OpenFreeMap](https://openfreemap.org): basemap styles and tiles
- [Tilezen Joerd](https://github.com/tilezen/joerd): terrain tiles for hillshade
- [fl_chart](https://pub.dev/packages/fl_chart): analytics charts
- [flutter_svg](https://pub.dev/packages/flutter_svg): logo and marker artwork

## Fonts

- [Inter](https://rsms.me/inter/) and [JetBrains Mono](https://www.jetbrains.com/lp/mono/),
  bundled under the SIL Open Font License (see `assets/fonts/`)

## The network

- [MeshCore](https://github.com/meshcore-dev/MeshCore): the mesh this app observes

- [MeshMapper](https://github.com/MeshMapper/MeshMapper_Flutter_App) (MIT): companion connection sequence and GATT-busy retry policy; notice in [meshmapper-MIT.txt](docs/licenses/meshmapper-MIT.txt)
