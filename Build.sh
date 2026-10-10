#!/bin/bash

# Beacon Mobile Build Script
# Builds Android APK, Android AAB, and iOS IPA with the same epoch timestamp

set -e  # Exit on any error

cd "$(dirname "$0")"

# The Flutter SDK every release is built with. Bump this when Flutter is
# upgraded, together with flutter-version in .github/workflows/ci.yml and
# android.yml, so the store builds and CI never drift onto different SDKs.
REQUIRED_FLUTTER_VERSION="3.47.5"

# CLI flags for scripted use: ./Build.sh [--type dev|prod] [--version X.Y.Z] [--dry-run]
# With no flags the script prompts interactively.
CLI_TYPE=""
CLI_VERSION=""
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --type)    CLI_TYPE="$2"; shift 2 ;;
        --version) CLI_VERSION="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *)
            echo "Error: Unknown argument: $1"
            echo "Usage: ./Build.sh [--type dev|prod] [--version X.Y.Z] [--dry-run]"
            exit 1
            ;;
    esac
done
if [ -n "$CLI_TYPE" ] && [ "$CLI_TYPE" != "dev" ] && [ "$CLI_TYPE" != "prod" ]; then
    echo "Error: --type must be 'dev' or 'prod'"
    exit 1
fi
if [ "$DRY_RUN" = "1" ] && { [ -z "$CLI_TYPE" ] || [ -z "$CLI_VERSION" ]; }; then
    echo "Error: --dry-run requires --type and --version"
    exit 1
fi
# Both flags given -> never prompt; missing secrets are an error instead
NONINTERACTIVE=0
if [ -n "$CLI_TYPE" ] && [ -n "$CLI_VERSION" ]; then
    NONINTERACTIVE=1
fi

# Local release secrets (optional, never committed; lives outside the repo)
RELEASE_ENV="$HOME/.beacon_release.env"
if [ -f "$RELEASE_ENV" ]; then
    # Not exported wholesale: the file also holds store API keys that pod,
    # gradle and pub have no business seeing. Only the signing values Gradle
    # reads (System.getenv) are exported, once they are resolved below.
    source "$RELEASE_ENV"
fi

# Semver comparison: returns 0 (true) if $1 >= $2
version_gte() {
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=0; i<3; i++)); do
        if ((${ver1[i]:-0} > ${ver2[i]:-0})); then return 0; fi
        if ((${ver1[i]:-0} < ${ver2[i]:-0})); then return 1; fi
    done
    return 0
}

# Validate a --version value; exits instead of re-prompting (scripted use)
require_valid_version() {
    if ! [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Error: Version must be in X.Y.Z format (e.g. 1.0.0)"
        exit 1
    fi
    if ! version_gte "$1" "$LAST_VERSION"; then
        echo "Error: Version must be >= $LAST_VERSION"
        exit 1
    fi
}

# Prompt until a valid X.Y.Z >= LAST_VERSION is entered
prompt_version() {
    local label="$1"
    while true; do
        read -p "$label [$LAST_VERSION]: " VERSION_NUMBER
        VERSION_NUMBER=${VERSION_NUMBER:-$LAST_VERSION}
        if ! [[ "$VERSION_NUMBER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "Error: Version must be in X.Y.Z format (e.g. 1.0.0)"
            continue
        fi
        if ! version_gte "$VERSION_NUMBER" "$LAST_VERSION"; then
            echo "Error: Version must be >= $LAST_VERSION"
            continue
        fi
        break
    done
}

if [ "$DRY_RUN" = "1" ]; then
    # Nothing is built, so the signing secrets are not needed
    SIGNING_STATUS="not checked (dry run)"
elif [ "$NONINTERACTIVE" = "1" ]; then
    # Scripted run - secrets must already be set (env or $RELEASE_ENV), never prompt
    MISSING=""
    [ -z "$SIGNING_STORE_FILE" ] && MISSING="$MISSING SIGNING_STORE_FILE"
    [ -z "$SIGNING_KEY_ALIAS" ] && MISSING="$MISSING SIGNING_KEY_ALIAS"
    [ -z "$SIGNING_STORE_PASSWORD" ] && MISSING="$MISSING SIGNING_STORE_PASSWORD"
    if [ -n "$MISSING" ]; then
        echo "Error: Missing required secrets:$MISSING"
        echo "Set them in $RELEASE_ENV or the environment."
        exit 1
    fi
else
    # Android signing - prompt for anything not set
    if [ -z "$SIGNING_STORE_FILE" ]; then
        read -p "Path to Android keystore (.jks): " SIGNING_STORE_FILE
    fi
    if [ -z "$SIGNING_KEY_ALIAS" ]; then
        read -p "Keystore key alias: " SIGNING_KEY_ALIAS
    fi
    if [ -z "$SIGNING_STORE_PASSWORD" ]; then
        echo "Enter keystore password:"
        read -s SIGNING_STORE_PASSWORD
    fi
    if [ -z "$SIGNING_KEY_PASSWORD" ]; then
        echo "Enter key password (or press Enter if same as keystore):"
        read -s SIGNING_KEY_PASSWORD
    fi
fi
if [ "$DRY_RUN" != "1" ]; then
    if [ -z "$SIGNING_KEY_PASSWORD" ]; then
        SIGNING_KEY_PASSWORD="$SIGNING_STORE_PASSWORD"
    fi
    if [ ! -f "$SIGNING_STORE_FILE" ]; then
        echo "Error: Keystore not found: $SIGNING_STORE_FILE"
        exit 1
    fi
    export SIGNING_STORE_FILE SIGNING_KEY_ALIAS SIGNING_STORE_PASSWORD SIGNING_KEY_PASSWORD
fi

# The app version lives in pubspec.yaml (the X.Y.Z part; the +N build number is
# always replaced by the epoch at build time)
PUBSPEC="pubspec.yaml"
LAST_VERSION=$(sed -n 's/^version: *\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' "$PUBSPEC" | head -1)
if [ -z "$LAST_VERSION" ]; then
    echo "Error: Could not read version from $PUBSPEC"
    exit 1
fi
echo ""
echo "Current version: $LAST_VERSION"

# Generate single epoch for all builds (used as build-number regardless of release type)
EPOCH=$(date +%s)

# Release type - from --type flag, or prompt
if [ -n "$CLI_TYPE" ]; then
    if [ "$CLI_TYPE" = "prod" ]; then
        RELEASE_TYPE=2
    else
        RELEASE_TYPE=1
    fi
else
    echo ""
    echo "Release type?"
    echo "  1) Dev  (APP-<epoch>)"
    echo "  2) Production  (APP-x.y.z)"
    echo ""
    read -p "Select [1]: " RELEASE_TYPE
    RELEASE_TYPE=${RELEASE_TYPE:-1}
fi

if [ -n "$CLI_VERSION" ]; then
    VERSION_NUMBER="$CLI_VERSION"
    require_valid_version "$VERSION_NUMBER"
elif [ "$RELEASE_TYPE" = "2" ]; then
    prompt_version "Enter version"
else
    prompt_version "Enter target version"
fi

if [ "$RELEASE_TYPE" = "2" ]; then
    APP_VERSION="APP-$VERSION_NUMBER"
    FILE_TAG="$VERSION_NUMBER"
else
    APP_VERSION="APP-$EPOCH"
    FILE_TAG="$EPOCH"
fi

# Output directories
ANDROID_DIR="$HOME/Documents/Beacon_Apps/Android"
IOS_DIR="$HOME/Documents/Beacon_Apps/IOS"

# The Flutter SDK on PATH builds everything
FLUTTER_BIN="$(command -v flutter || true)"
if [ -z "$FLUTTER_BIN" ]; then
    echo "Error: flutter not found on PATH"
    exit 1
fi
FLUTTER_VERSION_LINE="$(flutter --version 2>/dev/null | head -1)"
FLUTTER_FRAMEWORK_VERSION="$(flutter --version --machine 2>/dev/null | sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p' | head -1)"
if [ "$FLUTTER_FRAMEWORK_VERSION" != "$REQUIRED_FLUTTER_VERSION" ]; then
    echo "Error: Flutter $REQUIRED_FLUTTER_VERSION is required, but the flutter on PATH"
    echo "($FLUTTER_BIN) is ${FLUTTER_FRAMEWORK_VERSION:-unknown}."
    echo "Install or switch to $REQUIRED_FLUTTER_VERSION, or bump REQUIRED_FLUTTER_VERSION"
    echo "at the top of Build.sh (and ci.yml, android.yml) if you are upgrading on purpose."
    exit 1
fi

# Code generation only runs once the project depends on build_runner
USES_BUILD_RUNNER=0
if grep -q '^ *build_runner:' "$PUBSPEC"; then
    USES_BUILD_RUNNER=1
fi

# Dry run: everything is resolved and validated - print the plan and stop
if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "============================================"
    echo "DRY RUN - nothing will be built"
    echo "Release type: $([ "$RELEASE_TYPE" = "2" ] && echo Production || echo Dev)"
    echo "Version: $APP_VERSION"
    echo "Build name: $VERSION_NUMBER"
    echo "Build number: $EPOCH"
    echo "Signing: $SIGNING_STATUS"
    echo "Flutter SDK: $FLUTTER_VERSION_LINE ($FLUTTER_BIN)"
    echo ""
    echo "Would run first:"
    echo "  flutter pub get"
    if [ "$USES_BUILD_RUNNER" = "1" ]; then
        echo "  dart run build_runner build --delete-conflicting-outputs"
    fi
    echo "  (fails the build if pubspec.lock gets rewritten)"
    echo ""
    echo "Would produce:"
    echo "  APK: $ANDROID_DIR/Beacon-$FILE_TAG.apk"
    echo "  AAB: $ANDROID_DIR/Beacon-$FILE_TAG.aab"
    echo "  IPA: $IOS_DIR/Beacon-$FILE_TAG.ipa"
    echo ""
    if [ "$VERSION_NUMBER" != "$LAST_VERSION" ]; then
        echo "Would set pubspec.yaml version: $LAST_VERSION -> $VERSION_NUMBER"
    fi
    echo "pubspec.yaml and .last_build not modified"
    echo "============================================"
    exit 0
fi

# Record the new version in pubspec.yaml (keeps the +N suffix untouched)
if [ "$VERSION_NUMBER" != "$LAST_VERSION" ]; then
    sed -i '' "s/^version: *$LAST_VERSION/version: $VERSION_NUMBER/" "$PUBSPEC"
    echo "pubspec.yaml version: $LAST_VERSION -> $VERSION_NUMBER"
fi

echo ""
echo "============================================"
echo "Beacon Mobile Build Script"
echo "Version: $APP_VERSION"
echo "Build number: $EPOCH"
echo "Flutter SDK: $FLUTTER_VERSION_LINE ($FLUTTER_BIN)"
echo "============================================"
echo ""

# Resolve dependencies (and regenerate code, if any). A rewritten
# pubspec.lock means the SDK on PATH is not the one the lock was resolved with.
echo "[0/3] Resolving dependencies..."
LOCK_BEFORE="$(shasum pubspec.lock 2>/dev/null || true)"
flutter pub get
if [ "$USES_BUILD_RUNNER" = "1" ]; then
    if ! dart run build_runner build --delete-conflicting-outputs; then
        echo "Error: build_runner failed, not building"
        exit 1
    fi
fi
LOCK_AFTER="$(shasum pubspec.lock 2>/dev/null || true)"
if [ "$LOCK_BEFORE" != "$LOCK_AFTER" ]; then
    echo "Error: pubspec.lock was rewritten. The Flutter SDK on PATH"
    echo "($FLUTTER_VERSION_LINE) is likely not the one the lock was resolved"
    echo "with, or a dependency changed without committing the lock."
    echo "Restore pubspec.lock (or commit the new one) and re-run."
    exit 1
fi
echo "✓ Dependencies are up to date"
echo ""

# Ensure output directories exist
mkdir -p "$ANDROID_DIR"
mkdir -p "$IOS_DIR"

# Build Android APK
echo "[1/3] Building Android APK..."
flutter build apk --release --build-name="$VERSION_NUMBER" --build-number="$EPOCH" --dart-define="APP_VERSION=$APP_VERSION"
cp build/app/outputs/flutter-apk/app-release.apk "$ANDROID_DIR/Beacon-$FILE_TAG.apk"
echo "✓ Built: Beacon-$FILE_TAG.apk"
echo ""

# Build Android AAB
echo "[2/3] Building Android AAB..."
flutter build appbundle --release --build-name="$VERSION_NUMBER" --build-number="$EPOCH" --dart-define="APP_VERSION=$APP_VERSION"
cp build/app/outputs/bundle/release/app-release.aab "$ANDROID_DIR/Beacon-$FILE_TAG.aab"
echo "✓ Built: Beacon-$FILE_TAG.aab"
echo ""

# Build iOS IPA
echo "[3/3] Building iOS IPA..."
if [ -f ios/Podfile ]; then
    (cd ios && pod install)
fi
rm -rf build/ios/ipa
flutter build ipa --release --build-name="$VERSION_NUMBER" --build-number="$EPOCH" --dart-define="APP_VERSION=$APP_VERSION" --export-options-plist=ios/ExportOptions.plist
IPA_SRC=$(ls build/ios/ipa/*.ipa | head -1)
cp "$IPA_SRC" "$IOS_DIR/Beacon-$FILE_TAG.ipa"
echo "✓ Built: Beacon-$FILE_TAG.ipa"
echo ""

echo "============================================"
echo "Build Complete!"
echo "Version: $APP_VERSION"
echo "Build number: $EPOCH"
echo ""
echo "Outputs:"
echo "  APK: $ANDROID_DIR/Beacon-$FILE_TAG.apk"
echo "  AAB: $ANDROID_DIR/Beacon-$FILE_TAG.aab"
echo "  IPA: $IOS_DIR/Beacon-$FILE_TAG.ipa"
echo "============================================"

# Record build metadata for the release flow (gitignored; only written on full success)
{
    echo "RELEASE_TYPE=$([ "$RELEASE_TYPE" = "2" ] && echo prod || echo dev)"
    echo "VERSION_NUMBER=$VERSION_NUMBER"
    echo "EPOCH=$EPOCH"
    echo "APP_VERSION=$APP_VERSION"
    echo "FILE_TAG=$FILE_TAG"
    echo "APK_PATH=$ANDROID_DIR/Beacon-$FILE_TAG.apk"
    echo "AAB_PATH=$ANDROID_DIR/Beacon-$FILE_TAG.aab"
    echo "IPA_PATH=$IOS_DIR/Beacon-$FILE_TAG.ipa"
    echo "ARCHIVE_PATH=$(pwd)/build/ios/archive/Runner.xcarchive"
    echo "GIT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > .last_build
