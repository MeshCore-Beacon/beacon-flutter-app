# Vendored packages

`firebase_core` and `firebase_messaging` are copied from pub.dev and used
through `dependency_overrides` in `pubspec.yaml`. Android uses them for push.
iOS gets push straight from APNs, so the iOS build must carry no Firebase code.

## What changed

Only one thing, in each package's `pubspec.yaml`: the `ios:` entry under
`flutter.plugin.platforms` is removed. Without it Flutter does not register
the plugin on iOS or add its Swift package (and the Firebase iOS SDK) to the
build. The `example/` folders are left out. Everything else, including the
BSD `LICENSE` files, is as published.

| Package | Version |
|---|---|
| firebase_core | 4.15.2 |
| firebase_messaging | 16.7.1 |

`test/core/third_party_test.dart` fails if an `ios:` entry comes back.

## Upgrading

1. Bump the version in `pubspec.yaml` and run `flutter pub get` once without
   the overrides, so the new version lands in the pub cache.
2. Replace the folder here with the new version from
   `~/.pub-cache/hosted/pub.dev/<name>-<version>/`, leaving out `example/`.
3. Remove the `ios:` entry under `flutter.plugin.platforms` again.
4. Restore the overrides, run `flutter pub get` and `flutter test`, and check
   that `ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved` has no
   Firebase or Google packages after an iOS build.
5. Update the versions in the table above.
