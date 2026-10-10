# Contributing to Beacon Mobile

Thank you for your interest in contributing. Beacon is a focused project and we
want contributions to be high quality and sustainable. Please read this guide
before opening a PR.

---

## Workflow

Branches, the pull request flow, commit message format and the release process are the same
for every Beacon repo and live in
[beacon-docs/CONTRIBUTING.md](https://github.com/MeshCore-Beacon/beacon-docs/blob/main/CONTRIBUTING.md).
In short: open or comment on an issue first, branch from `dev`, keep each PR to one change,
write conventional commit messages, and open the PR against `dev`. Running the app against a
local beacon-server is described there too.

Before opening a PR here:

```
dart format --set-exit-if-changed .   # formatting; must be clean
flutter analyze                       # no errors or warnings
flutter test                          # all tests pass
```

---

## Getting set up

```bash
flutter pub get
flutter run
```

beacon-flutter-app is a client of [beacon-server](https://github.com/MeshCore-Beacon/beacon-server),
which is the source of truth for every API, packet, and WebSocket shape.
Dart models must mirror the
[API contract](https://github.com/MeshCore-Beacon/beacon-docs/blob/main/docs/api-contract.md);
read it before guessing a payload shape.

---

## Code style

- Follow the [Effective Dart](https://dart.dev/effective-dart) guidelines and
  the analyzer rules in `analysis_options.yaml`
- Follow the existing patterns in each feature before introducing new ones
- Reuse existing widgets and theme tokens rather than adding new ones
- Keep widgets small and single-purpose
- Comments state the non-obvious *why* in one terse line; a wrong comment is
  worse than none

---

## Tests

- **Practice TDD for bugfixes and features**: write the failing test first,
  watch it fail, then implement.
- Tests live in `test/` and mirror `lib/`.
- Run `flutter test` before opening a PR. All tests must pass.
- If you are fixing a bug, add a test that would have caught it.

---

## Mobile-specific patterns

- **Don't fight the OS.** Close the WebSocket when the app is backgrounded;
  on return, reopen, resubscribe and refresh the active screen over REST. See
  [Mobile-specific concerns](https://github.com/MeshCore-Beacon/beacon-docs/blob/main/docs/api-contract.md#mobile-specific-concerns).
- **Test on both platforms** when a change touches platform code, permissions,
  or lifecycle handling.

---

## Releases

The flow is in
[Releases and versioning](https://github.com/MeshCore-Beacon/beacon-docs/blob/main/docs/releases.md#cutting-a-release).
The mobile-specific step is bumping `version` in `pubspec.yaml`.

Store builds are made locally by a maintainer, not in CI:

- `./Build.sh` builds the signed APK, AAB and IPA with one shared build number
  (the Unix epoch). `--type dev|prod --version X.Y.Z` skips the prompts and
  `--dry-run` only validates. Signing secrets come from `~/.beacon_release.env`.
- `./upload_ios.sh` uploads that build to App Store Connect (TestFlight).
- `./set_whats_new.sh` sets the TestFlight "What to Test" text on the build.

---

## Recognition

If you'd like to be listed as a contributor, add yourself to
[CONTRIBUTORS.md](CONTRIBUTORS.md) in your PR.
