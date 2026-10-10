#!/usr/bin/env python3

# Beacon Mobile Google Play publishing script
# Publishes the Android App Bundle to Google Play testing tracks and pushes the
# store listing through the Google Play Developer API (androidpublisher v3).
# Python 3 standard library only, plus the openssl CLI for signing the OAuth JWT.
#
# Every change happens inside a Play "edit" (a draft transaction). Nothing goes
# live until the edit is committed, and on any failure the edit is deleted so
# nothing half-applied lingers. Everything is a dry run unless --apply is passed.
#
# ---------------------------------------------------------------------------
# One-time setup
# ---------------------------------------------------------------------------
#   1. The app (meshcorebeacon.app) must already exist in Play Console. The API
#      cannot create an app.
#   2. Google Cloud console: create (or pick) a project and enable the
#      "Google Play Android Developer API" for it.
#   3. IAM & Admin > Service accounts: create a service account (no project
#      roles needed), then Keys > Add key > JSON. Store the key outside the repo:
#          mkdir -p ~/.play && mv <downloaded>.json ~/.play/beacon-service-account.json
#          chmod 600 ~/.play/beacon-service-account.json
#   4. Play Console > Users and permissions > Invite new users: invite the
#      service account's email (client_email in the JSON). Under App
#      permissions add Beacon with:
#          - Release to testing tracks
#          - Manage store presence
#          - View app information (read-only)
#      Permissions can take a while (sometimes up to 24-36h) to reach the API.
#   5. Add to ~/.beacon_release.env (or export in the environment; env wins):
#          PLAY_SERVICE_ACCOUNT_JSON=~/.play/beacon-service-account.json
#          PLAY_PACKAGE_NAME=meshcorebeacon.app      # optional, this is the default
#
# The API cannot fill in anything under Play Console > Policy and programs /
# App content: content rating questionnaire, data safety, target audience,
# app access, ads declaration, privacy policy, news/health declarations, app
# category. Those are Console-only and must be complete before a release can
# leave draft. Until the app's first release is rolled out, Play only accepts
# draft releases (upload with --status draft, then roll out in Console).
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   ./play_store.py status
#       Read-only: tracks, releases, listing languages. Never commits.
#
#   ./play_store.py upload --track internal [--notes-file notes.txt] [--apply]
#       Uploads AAB_PATH from .last_build (or --aab PATH) and puts it on the
#       track. Release name defaults to "versionName (versionCode)" read from the AAB.
#       Tracks: internal, alpha (closed), beta (open), or a custom closed track.
#       --status draft|completed|inProgress (default completed), --fraction F
#       for inProgress. --version-code N assigns an already uploaded build to the
#       track instead of uploading.
#
#   ./play_store.py promote --from internal --to alpha [--apply]
#       Copies the latest release (versionCodes + notes) from one track to another.
#
#   ./play_store.py listing [--dir store/google] [--images DIR] [--apply]
#       Pushes store/google/<lang>/{title,short_description,full_description}.txt,
#       store/google/details.json and the graphics in --images DIR
#       (default ~/Documents/Beacon_Apps/store-screenshots).
#
# Add --no-review to upload/promote/listing if Play refuses the commit asking
# for changesNotSentForReview (changes then go to review from Console).

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REPO_DIR = os.path.dirname(os.path.abspath(__file__))
LAST_BUILD = os.path.join(REPO_DIR, ".last_build")
RELEASE_ENV = os.path.expanduser("~/.beacon_release.env")
DEFAULT_PACKAGE = "meshcorebeacon.app"
DEFAULT_LISTING_DIR = os.path.join(REPO_DIR, "store", "google")
DEFAULT_IMAGES_DIR = os.path.expanduser("~/Documents/Beacon_Apps/store-screenshots")
# PLAY_API_BASE only exists so the flow can be exercised against a stub server
API_BASE = os.environ.get("PLAY_API_BASE", "https://androidpublisher.googleapis.com").rstrip("/")
SCOPE = "https://www.googleapis.com/auth/androidpublisher"
DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token"

MAX_NOTES = 500
TEXT_LIMITS = [
    # (file, API field, max characters)
    ("title.txt", "title", 30),
    ("short_description.txt", "shortDescription", 80),
    ("full_description.txt", "fullDescription", 4000),
]
TRACK_LABELS = {
    "internal": "Internal testing",
    "alpha": "Closed testing (alpha)",
    "beta": "Open testing (beta)",
    "production": "Production",
}
STANDARD_TRACKS = ["internal", "alpha", "beta", "production"]

# Hint context filled in as commands run, used to explain known API errors
HINT = {}


class PlayError(Exception):
    """A fatal, user-facing error. main() prints it and exits 1."""


class ApiError(PlayError):
    def __init__(self, status, message, what):
        self.status = status
        self.api_message = message
        super().__init__(f"{what} failed (HTTP {status}): {message}")


# ---------------------------------------------------------------------------
# Settings and .last_build
# ---------------------------------------------------------------------------

def parse_env_file(path):
    """Parse simple KEY=value lines (optional 'export ', quotes, # comments)."""
    values = {}
    if not os.path.isfile(path):
        return values
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export "):].strip()
            key, sep, value = line.partition("=")
            key = key.strip()
            if not sep or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
                continue
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            elif " #" in value:
                value = value.split(" #", 1)[0].rstrip()
            values[key] = value
    return values


_ENV_FILE = None


def setting(name, default=None):
    global _ENV_FILE
    if os.environ.get(name):
        return os.environ[name]
    if _ENV_FILE is None:
        _ENV_FILE = parse_env_file(RELEASE_ENV)
    return _ENV_FILE.get(name) or default


def package_name():
    return setting("PLAY_PACKAGE_NAME", DEFAULT_PACKAGE)


def read_last_build():
    return parse_env_file(LAST_BUILD)


# ---------------------------------------------------------------------------
# Credentials and OAuth
# ---------------------------------------------------------------------------

SETUP_HINT = (
    "Set PLAY_SERVICE_ACCOUNT_JSON (env or ~/.beacon_release.env) to the service\n"
    "account JSON key, e.g. ~/.play/beacon-service-account.json (chmod 600).\n"
    "See the header of play_store.py for the one-time Play Console setup."
)


def load_credentials(required=True):
    path = setting("PLAY_SERVICE_ACCOUNT_JSON")
    if not path:
        if required:
            raise PlayError("PLAY_SERVICE_ACCOUNT_JSON is not set.\n" + SETUP_HINT)
        return None
    path = os.path.expanduser(path)
    if not os.path.isfile(path):
        raise PlayError(f"Service account key not found: {path}\n" + SETUP_HINT)
    if os.stat(path).st_mode & 0o077:
        print(f"Warning: {path} is readable by other users; run: chmod 600 {path}")
    try:
        with open(path, encoding="utf-8") as f:
            creds = json.load(f)
    except (OSError, ValueError) as e:
        raise PlayError(f"Could not read service account key {path}: {e}")
    if not isinstance(creds, dict) or creds.get("type") != "service_account":
        raise PlayError(f"{path} is not a service account JSON key (type != service_account).")
    for field in ("client_email", "private_key"):
        if not creds.get(field):
            raise PlayError(f"{path} has no {field}; download a fresh JSON key.")
    return creds


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def rs256_sign(private_key_pem, data):
    """Sign with openssl, keeping the key in a 0600 temp file only while signing."""
    tmpdir = tempfile.mkdtemp(prefix="play_store_")
    key_path = os.path.join(tmpdir, "key.pem")
    try:
        fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(private_key_pem)
        try:
            result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                                    input=data, capture_output=True)
        except FileNotFoundError:
            raise PlayError("openssl is required but not installed.")
        if result.returncode != 0 or not result.stdout:
            raise PlayError("openssl could not sign the token request; is private_key in "
                            "the service account JSON intact?")
        return result.stdout
    finally:
        if os.path.exists(key_path):
            os.remove(key_path)
        shutil.rmtree(tmpdir, ignore_errors=True)


def build_jwt(creds, now=None):
    now = int(now if now is not None else time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    if creds.get("private_key_id"):
        header["kid"] = creds["private_key_id"]
    payload = {
        "iss": creds["client_email"],
        "scope": SCOPE,
        "aud": creds.get("token_uri") or DEFAULT_TOKEN_URI,
        "iat": now,
        "exp": now + 3600,
    }
    signing_input = (b64url(json.dumps(header, separators=(",", ":")).encode()) + "."
                     + b64url(json.dumps(payload, separators=(",", ":")).encode()))
    signature = rs256_sign(creds["private_key"], signing_input.encode("ascii"))
    return signing_input + "." + b64url(signature)


def fetch_access_token(creds):
    token_uri = creds.get("token_uri") or DEFAULT_TOKEN_URI
    body = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": build_jwt(creds),
    }).encode()
    req = urllib.request.Request(token_uri, data=body, method="POST",
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            err = json.loads(raw)
            msg = err.get("error_description") or err.get("error") or raw
            if err.get("error") and err.get("error_description"):
                msg = f"{err['error']}: {err['error_description']}"
        except ValueError:
            msg = raw.strip()[:500]
        raise PlayError(f"Google OAuth token exchange failed (HTTP {e.code}): {msg}\n"
                        "Check that the service account key is current (not deleted or "
                        "rotated in Google Cloud) and the system clock is correct.")
    except urllib.error.URLError as e:
        raise PlayError(f"Could not reach {token_uri}: {e.reason}")
    if not data.get("access_token"):
        raise PlayError("Google OAuth token exchange returned no access_token.")
    return data["access_token"]


# ---------------------------------------------------------------------------
# API client and edits
# ---------------------------------------------------------------------------

class PlayApi:
    def __init__(self, creds, package):
        self.package = package
        self.client_email = creds["client_email"]
        self.token = fetch_access_token(creds)

    def call(self, method, path, body=None, *, upload_path=None, upload_bytes=None,
             content_type=None, query=None, timeout=120, what=None):
        upload = upload_path is not None or upload_bytes is not None
        prefix = "/upload/androidpublisher/v3" if upload else "/androidpublisher/v3"
        url = f"{API_BASE}{prefix}/applications/{urllib.parse.quote(self.package)}{path}"
        params = dict(query or {})
        if upload:
            params["uploadType"] = "media"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        headers = {"Authorization": f"Bearer {self.token}"}
        data = None
        fileobj = None
        if upload_path is not None:
            fileobj = open(upload_path, "rb")
            data = fileobj
            headers["Content-Type"] = content_type or "application/octet-stream"
            headers["Content-Length"] = str(os.path.getsize(upload_path))
        elif upload_bytes is not None:
            data = upload_bytes
            headers["Content-Type"] = content_type or "application/octet-stream"
        elif body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        elif method in ("POST", "PUT", "PATCH"):
            data = b""
        what = what or f"{method} {path}"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", "replace")
            message = raw.strip()[:1000] or e.reason
            try:
                err = json.loads(raw).get("error", {})
                if isinstance(err, dict) and err.get("message"):
                    message = err["message"]
            except (ValueError, AttributeError):
                pass
            raise ApiError(e.code, message, what)
        except urllib.error.URLError as e:
            raise PlayError(f"{what} failed: could not reach {API_BASE}: {e.reason}")
        except TimeoutError:
            raise PlayError(f"{what} timed out after {timeout}s.")
        finally:
            if fileobj:
                fileobj.close()
        if not raw:
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError:
            return {}


class Edit:
    """An androidpublisher edit. Deleted on exit unless committed."""

    def __init__(self, api):
        self.api = api
        self.id = None

    def __enter__(self):
        resp = self.api.call("POST", "/edits", {}, what="Opening an edit (edits.insert)")
        self.id = resp.get("id")
        if not self.id:
            raise PlayError("edits.insert returned no edit id.")
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.id:
            try:
                self.api.call("DELETE", f"/edits/{self.id}", what="edits.delete")
            except PlayError as e:
                print(f"Warning: could not delete edit {self.id}: {e}")
                print("It expires on its own; nothing in it was committed.")
            self.id = None
        return False

    def call(self, method, path, body=None, **kw):
        return self.api.call(method, f"/edits/{self.id}{path}", body, **kw)

    def commit(self, no_review=False):
        query = {"changesNotSentForReview": "true"} if no_review else None
        self.api.call("POST", f"/edits/{self.id}:commit", query=query,
                      what="Committing the edit (edits.commit)")
        self.id = None  # committed edits no longer exist; nothing to delete


def explain_api_error(err):
    """Extra guidance for known Play API errors."""
    msg = err.api_message or ""
    low = msg.lower()
    pkg = package_name()
    track = HINT.get("track", "<track>")
    if "only releases with status draft may be created on draft app" in low:
        return (
            "This app has never been published, so Play only accepts draft releases.\n"
            f"  1. Re-run with --status draft, e.g.\n"
            f"       ./play_store.py upload --track {track} --status draft --apply\n"
            "  2. Finish the app setup in Play Console (Dashboard > Set up your app:\n"
            "     app access, ads, content rating, target audience, data safety,\n"
            "     privacy policy, category and store listing).\n"
            "  3. Open the draft release in Play Console > Testing and roll it out.\n"
            "After that first rollout, non-draft uploads from this script work.")
    if re.search(r"version code.*(already been used|has already been)", low):
        vc = HINT.get("version_code", "N")
        return (
            f"versionCode {vc} was already uploaded to Play; a versionCode can only be\n"
            "uploaded once. To put that existing build on a track without uploading:\n"
            f"  ./play_store.py upload --track {track} --version-code {vc} --apply\n"
            "Or build again (./Build.sh) to get a new versionCode.")
    if "changesnotsentforreview" in low:
        return ("Play wants these changes committed without sending them for review.\n"
                "Re-run with --no-review, then send the changes for review in Play Console\n"
                "(Publishing overview).")
    if err.status == 404 and "package" in low:
        return (f"Play cannot find package {pkg} for this service account. The app must\n"
                "already exist in Play Console, and the service account must be invited\n"
                "with access to it (Users and permissions).")
    if err.status in (401, 403):
        return ("The service account lacks permission. In Play Console > Users and\n"
                "permissions, give it Release to testing tracks, Manage store presence and\n"
                "View app information for this app. New grants can take hours to apply.\n"
                "Also confirm the Google Play Android Developer API is enabled in the\n"
                "service account's Google Cloud project.")
    return None


# ---------------------------------------------------------------------------
# Local file inspection: AAB manifest, PNG headers
# ---------------------------------------------------------------------------

def _varint(buf, i):
    shift = result = 0
    while True:
        if i >= len(buf):
            raise ValueError("truncated varint")
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def _pb_fields(buf):
    i = 0
    while i < len(buf):
        key, i = _varint(buf, i)
        field, wire = key >> 3, key & 7
        if wire == 0:
            value, i = _varint(buf, i)
        elif wire == 1:
            value, i = buf[i:i + 8], i + 8
        elif wire == 2:
            n, i = _varint(buf, i)
            value, i = buf[i:i + n], i + n
        elif wire == 5:
            value, i = buf[i:i + 4], i + 4
        else:
            raise ValueError(f"unsupported wire type {wire}")
        yield field, wire, value


def read_aab_manifest(aab_path):
    """Read package, versionCode and versionName from an AAB's proto manifest.

    base/manifest/AndroidManifest.xml is an aapt2 XmlNode protobuf:
    XmlNode.element(1) > XmlElement.attribute(4) > XmlAttribute{name(2), value(3),
    compiled_item(6) > Item.prim(7) > Primitive.int_decimal_value(6)}.
    """
    with zipfile.ZipFile(aab_path) as z:
        data = z.read("base/manifest/AndroidManifest.xml")
    element = next((v for f, w, v in _pb_fields(data) if f == 1 and w == 2), None)
    if element is None:
        raise ValueError("no root element in manifest")
    attrs = {}
    for f, w, v in _pb_fields(element):
        if f != 4 or w != 2:
            continue
        name = value = None
        prim_int = None
        for af, aw, av in _pb_fields(v):
            if af == 2 and aw == 2:
                name = av.decode("utf-8", "replace")
            elif af == 3 and aw == 2:
                value = av.decode("utf-8", "replace")
            elif af == 6 and aw == 2:
                for itf, itw, itv in _pb_fields(av):
                    if itf == 7 and itw == 2:
                        for pf, pw, pv in _pb_fields(itv):
                            if pf in (6, 7) and pw == 0:
                                prim_int = pv
        if name:
            attrs[name] = value if value else (str(prim_int) if prim_int is not None else None)
    version_code = attrs.get("versionCode")
    return {
        "package": attrs.get("package"),
        "versionCode": int(version_code) if version_code and version_code.isdigit() else None,
        "versionName": attrs.get("versionName"),
    }


def png_info(path):
    """Return (width, height, color_type) from a PNG's IHDR chunk."""
    with open(path, "rb") as f:
        head = f.read(26)
    if len(head) < 26 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise ValueError("not a PNG file")
    width = int.from_bytes(head[16:20], "big")
    height = int.from_bytes(head[20:24], "big")
    return width, height, head[25]


def sha1_file(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def human_size(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024.0


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def track_label(name):
    return TRACK_LABELS.get(name, "Closed testing (custom track)")


def sort_tracks(tracks):
    order = {t: i for i, t in enumerate(STANDARD_TRACKS)}
    return sorted(tracks, key=lambda t: (order.get(t.get("track"), 99), t.get("track", "")))


def release_max_code(release):
    codes = [int(c) for c in release.get("versionCodes", []) if str(c).isdigit()]
    return max(codes) if codes else -1


def describe_release(r, indent="    "):
    lines = [f"{indent}{r.get('name') or '(unnamed)'}: status={r.get('status', '?')}"
             f" versionCodes={','.join(r.get('versionCodes', [])) or '-'}"
             + (f" userFraction={r['userFraction']}" if "userFraction" in r else "")]
    for note in r.get("releaseNotes", []):
        text = note.get("text", "").replace("\n", " / ")
        if len(text) > 100:
            text = text[:97] + "..."
        lines.append(f"{indent}  notes[{note.get('language')}]: {text}")
    return "\n".join(lines)


def list_tracks(edit):
    return edit.call("GET", "/tracks", what="Listing tracks (edits.tracks.list)").get("tracks", [])


def validate_status(args):
    if args.fraction is not None:
        if args.status != "inProgress":
            raise PlayError("--fraction only applies with --status inProgress (a staged rollout).")
        if not 0 < args.fraction < 1:
            raise PlayError("--fraction must be between 0 and 1 (exclusive), e.g. 0.2.")
    elif args.status == "inProgress":
        raise PlayError("--status inProgress needs --fraction F (e.g. --fraction 0.2).")


def build_release(name, version_codes, notes, status, fraction):
    release = {"versionCodes": [str(c) for c in version_codes], "status": status}
    if name:
        release["name"] = name
    if notes:
        release["releaseNotes"] = notes
    if fraction is not None:
        release["userFraction"] = fraction
    return release


def no_credentials_notice():
    print("")
    print("Dry run: PLAY_SERVICE_ACCOUNT_JSON is not set, so the current Play state was")
    print("not checked and nothing was sent. Local inputs above are valid.")
    print("--apply needs credentials:")
    print("  " + SETUP_HINT.replace("\n", "\n  "))


# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

def cmd_status(args):
    pkg = package_name()
    creds = load_credentials(required=True)
    api = PlayApi(creds, pkg)
    print(f"Package: {pkg}")
    print(f"Service account: {api.client_email}")
    with Edit(api) as edit:
        print("")
        print("Tracks:")
        tracks = sort_tracks(list_tracks(edit))
        if not tracks:
            print("  (none)")
        for t in tracks:
            print(f"  {t.get('track')} - {track_label(t.get('track'))}")
            releases = t.get("releases", [])
            if not releases:
                print("    (no releases)")
            for r in releases:
                print(describe_release(r))

        bundles = edit.call("GET", "/bundles", what="Listing bundles (edits.bundles.list)").get("bundles", [])
        codes = sorted((b.get("versionCode") for b in bundles if b.get("versionCode")), reverse=True)
        print("")
        print(f"Uploaded bundles: {len(codes)}" + (f" (latest versionCodes: {', '.join(map(str, codes[:5]))})" if codes else ""))

        details = edit.call("GET", "/details", what="Reading app details (edits.details.get)")
        print("")
        print("App details:")
        for key in ("defaultLanguage", "contactEmail", "contactWebsite", "contactPhone"):
            if details.get(key):
                print(f"  {key}: {details[key]}")

        listings = edit.call("GET", "/listings", what="Listing store listings (edits.listings.list)").get("listings", [])
        print("")
        print("Store listing languages:")
        if not listings:
            print("  (none)")
        for lst in sorted(listings, key=lambda x: x.get("language", "")):
            print(f"  {lst.get('language')}: {lst.get('title', '')!r}")
    print("")
    print("(Read-only: the edit was discarded, nothing committed.)")


# ---------------------------------------------------------------------------
# upload
# ---------------------------------------------------------------------------

def read_notes(path, lang):
    if not path:
        return None
    if path == "-":
        text = sys.stdin.read()
    else:
        if not os.path.isfile(path):
            raise PlayError(f"Notes file not found: {path}")
        with open(path, encoding="utf-8") as f:
            text = f.read()
    text = text.strip()
    if not text:
        raise PlayError(f"Notes file {path} is empty.")
    if len(text) > MAX_NOTES:
        raise PlayError(f"Release notes are {len(text)} characters; Play allows {MAX_NOTES} "
                        f"per language ({lang}). Shorten {path}.")
    return [{"language": lang, "text": text}]


def cmd_upload(args):
    pkg = package_name()
    validate_status(args)
    last = read_last_build()
    HINT["track"] = args.track
    notes = read_notes(args.notes_file, args.lang)

    release_name = args.release_name

    aab = None
    version_code = args.version_code
    if version_code is None:
        aab = args.aab or last.get("AAB_PATH")
        if not aab:
            raise PlayError("No AAB given and .last_build has no AAB_PATH. Run ./Build.sh or pass --aab PATH.")
        aab = os.path.abspath(os.path.expanduser(aab))
        if not os.path.isfile(aab):
            raise PlayError(f"AAB not found: {aab}\nRun ./Build.sh or pass --aab PATH.")
        try:
            info = read_aab_manifest(aab)
        except (zipfile.BadZipFile, KeyError, ValueError) as e:
            raise PlayError(f"{aab} is not a readable Android App Bundle: {e}")
        if info["package"] and info["package"] != pkg:
            raise PlayError(f"{aab} is package {info['package']}, but PLAY_PACKAGE_NAME is {pkg}.")
        version_code = info["versionCode"]
        if version_code is None:
            if last.get("EPOCH") and os.path.abspath(last.get("AAB_PATH", "")) == aab:
                version_code = int(last["EPOCH"])
                print(f"Note: versionCode not readable from the manifest; using EPOCH {version_code} from .last_build.")
            else:
                print("Warning: versionCode not readable from the bundle manifest; Play will report it after upload.")
    HINT["version_code"] = version_code if version_code is not None else "N"

    # Name the release after the bundle actually being uploaded; .last_build
    # only describes the newest local build, which may not be this one
    if not release_name and aab and info.get("versionName") and version_code is not None:
        release_name = f"{info['versionName']} ({version_code})"

    print(f"Package:       {pkg}")
    print(f"Track:         {args.track} - {track_label(args.track)}")
    if aab:
        print(f"Bundle:        {aab} ({human_size(os.path.getsize(aab))})")
        print(f"versionCode:   {version_code if version_code is not None else '(unknown until upload)'}"
              + (f"  versionName: {info['versionName']}" if info.get("versionName") else ""))
    else:
        print(f"Bundle:        (no upload) assigning existing versionCode {version_code}")
    print(f"Release name:  {release_name or '(Play default)'}")
    print(f"Status:        {args.status}" + (f" (userFraction {args.fraction})" if args.fraction is not None else ""))
    if notes:
        print(f"Release notes [{args.lang}] ({len(notes[0]['text'])}/{MAX_NOTES} chars):")
        for line in notes[0]["text"].splitlines():
            print(f"  | {line}")
    else:
        print("Release notes: (none)")

    creds = load_credentials(required=args.apply)
    if creds is None:
        no_credentials_notice()
        return
    api = PlayApi(creds, pkg)
    with Edit(api) as edit:
        tracks = {t.get("track"): t for t in list_tracks(edit)}
        current = tracks.get(args.track)
        print("")
        if current is None:
            print(f"Warning: track '{args.track}' does not exist yet for this app. Custom closed "
                  "tracks must be created in Play Console first.")
        else:
            print(f"Current {args.track} releases:")
            for r in current.get("releases", []):
                print(describe_release(r))
            if not current.get("releases"):
                print("    (none)")

        if not args.apply:
            print("")
            print("Dry run: nothing uploaded or changed. Re-run with --apply to publish.")
            return

        if aab:
            print("")
            print(f"Uploading {os.path.basename(aab)} (this can take a few minutes)...")
            resp = edit.call("POST", "/bundles", upload_path=aab,
                             content_type="application/octet-stream", timeout=1800,
                             what="Uploading the bundle (edits.bundles.upload)")
            uploaded = resp.get("versionCode")
            if uploaded is None:
                raise PlayError("Bundle upload returned no versionCode.")
            if version_code is not None and int(uploaded) != int(version_code):
                print(f"Warning: Play reports versionCode {uploaded}, expected {version_code}.")
            version_code = uploaded
            print(f"Uploaded versionCode {version_code} (sha1 {resp.get('sha1', '?')}).")

        release = build_release(release_name, [version_code], notes, args.status, args.fraction)
        edit.call("PUT", f"/tracks/{urllib.parse.quote(args.track)}",
                  {"track": args.track, "releases": [release]},
                  what=f"Updating track {args.track} (edits.tracks.update)")
        edit.commit(no_review=args.no_review)
    print("")
    print(f"Committed: versionCode {version_code} is on {args.track} with status {args.status}.")
    if args.status == "draft":
        print("The release is a draft; roll it out from Play Console > Testing.")


# ---------------------------------------------------------------------------
# promote
# ---------------------------------------------------------------------------

def cmd_promote(args):
    pkg = package_name()
    validate_status(args)
    HINT["track"] = args.to_track
    if args.from_track == args.to_track:
        raise PlayError("--from and --to must be different tracks.")
    creds = load_credentials(required=True)
    api = PlayApi(creds, pkg)
    with Edit(api) as edit:
        tracks = {t.get("track"): t for t in list_tracks(edit)}
        src = tracks.get(args.from_track)
        releases = [r for r in (src or {}).get("releases", []) if r.get("versionCodes")]
        if not releases:
            raise PlayError(f"Track '{args.from_track}' has no release with a build to promote.")
        latest = max(releases, key=release_max_code)
        HINT["version_code"] = release_max_code(latest)
        release = build_release(latest.get("name"), latest["versionCodes"],
                                latest.get("releaseNotes"), args.status, args.fraction)

        print(f"Package: {pkg}")
        print(f"From {args.from_track} ({track_label(args.from_track)}), latest release:")
        print(describe_release(latest))
        dest = tracks.get(args.to_track)
        print(f"To {args.to_track} ({track_label(args.to_track)}), currently:")
        if dest is None:
            print(f"    Warning: track '{args.to_track}' does not exist yet for this app.")
        for r in (dest or {}).get("releases", []) or []:
            print(describe_release(r))
        if dest is not None and not dest.get("releases"):
            print("    (no releases)")
        print("New release:")
        print(describe_release(release))

        if not args.apply:
            print("")
            print("Dry run: nothing changed. Re-run with --apply to promote.")
            return
        edit.call("PUT", f"/tracks/{urllib.parse.quote(args.to_track)}",
                  {"track": args.to_track, "releases": [release]},
                  what=f"Updating track {args.to_track} (edits.tracks.update)")
        edit.commit(no_review=args.no_review)
    print("")
    print(f"Committed: versionCodes {','.join(release['versionCodes'])} promoted to {args.to_track}.")


# ---------------------------------------------------------------------------
# listing
# ---------------------------------------------------------------------------

# (local name, [API image types], (exact width, height) or None, min count, max count, max bytes)
IMAGE_SETS = [
    ("play-icon-512.png", ["icon"], (512, 512), 1, 1, 1024 * 1024),
    ("play-feature-graphic.png", ["featureGraphic"], (1024, 500), 1, 1, 15 * 1024 * 1024),
    ("android-phone", ["phoneScreenshots"], None, 2, 8, 8 * 1024 * 1024),
    ("android-tablet", ["tenInchScreenshots", "sevenInchScreenshots"], None, 1, 8, 8 * 1024 * 1024),
]


def validate_image(path, exact, max_bytes, errors, kind):
    try:
        w, h, color_type = png_info(path)
    except (OSError, ValueError) as e:
        errors.append(f"{path}: {e}")
        return None
    size = os.path.getsize(path)
    if size > max_bytes:
        errors.append(f"{path}: {human_size(size)} exceeds the {human_size(max_bytes)} limit")
    if exact:
        if (w, h) != exact:
            errors.append(f"{path}: {w}x{h}, must be exactly {exact[0]}x{exact[1]}")
        if kind == "featureGraphic" and color_type in (4, 6):
            errors.append(f"{path}: has an alpha channel; the feature graphic must be a 24-bit PNG (no alpha) or JPEG")
    else:
        if min(w, h) < 320 or max(w, h) > 3840:
            errors.append(f"{path}: {w}x{h}, each side must be 320-3840 px")
        elif max(w, h) > 2 * min(w, h):
            errors.append(f"{path}: {w}x{h}, the long side may be at most twice the short side")
    return (w, h)


def collect_images(images_dir, errors):
    """Return [(label, [types], [paths], [dims])] for the image sets present locally."""
    plan = []
    for name, types, exact, min_n, max_n, max_bytes in IMAGE_SETS:
        path = os.path.join(images_dir, name)
        if exact:
            if not os.path.isfile(path):
                print(f"Note: {path} not found; {types[0]} left unchanged.")
                continue
            files = [path]
        else:
            if not os.path.isdir(path):
                print(f"Note: {path}/ not found; {', '.join(types)} left unchanged.")
                continue
            files = sorted(os.path.join(path, f) for f in os.listdir(path) if f.lower().endswith(".png"))
            if not (min_n <= len(files) <= max_n):
                errors.append(f"{path}/: {len(files)} PNG files, Play needs {min_n}-{max_n}")
                continue
        dims = [validate_image(f, exact, max_bytes, errors, types[0]) for f in files]
        plan.append((name, types, files, dims))
    return plan


def load_listing_text(base_dir, errors):
    """Return {lang: {field: text}} from <base_dir>/<lang>/*.txt."""
    langs = sorted(d for d in os.listdir(base_dir)
                   if os.path.isdir(os.path.join(base_dir, d)) and re.match(r"^[a-z]{2,3}(-[A-Za-z0-9]+)*$", d))
    if not langs:
        errors.append(f"{base_dir}: no language directories (expected e.g. {base_dir}/en-US/)")
    listings = {}
    for lang in langs:
        fields = {}
        for fname, field, limit in TEXT_LIMITS:
            path = os.path.join(base_dir, lang, fname)
            if not os.path.isfile(path):
                errors.append(f"{path}: missing (max {limit} chars)")
                continue
            with open(path, encoding="utf-8") as f:
                text = f.read().strip()
            if not text:
                errors.append(f"{path}: empty")
            elif len(text) > limit:
                errors.append(f"{path}: {len(text)} chars, Play allows {limit}")
            elif field != "fullDescription" and "\n" in text:
                errors.append(f"{path}: must be a single line")
            fields[field] = text
        listings[lang] = fields
    return listings


def load_details(base_dir, errors):
    path = os.path.join(base_dir, "details.json")
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            details = json.load(f)
    except (OSError, ValueError) as e:
        errors.append(f"{path}: {e}")
        return None
    allowed = {"contactEmail", "contactWebsite", "defaultLanguage", "contactPhone"}
    if not isinstance(details, dict):
        errors.append(f"{path}: must be a JSON object")
        return None
    unknown = set(details) - allowed
    if unknown:
        errors.append(f"{path}: unknown keys {sorted(unknown)} (allowed: {sorted(allowed)})")
    if details.get("contactEmail") and not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", details["contactEmail"]):
        errors.append(f"{path}: contactEmail does not look like an email address")
    if details.get("contactWebsite") and not re.match(r"^https?://", details["contactWebsite"]):
        errors.append(f"{path}: contactWebsite must start with http:// or https://")
    return {k: v for k, v in details.items() if k in allowed and v}


def cmd_listing(args):
    pkg = package_name()
    base_dir = os.path.abspath(os.path.expanduser(args.dir))
    if not os.path.isdir(base_dir):
        raise PlayError(f"Listing directory not found: {base_dir}")
    errors = []
    listings = load_listing_text(base_dir, errors)
    details = load_details(base_dir, errors)
    image_lang = args.images_lang or (details or {}).get("defaultLanguage") or "en-US"

    image_plan = []
    if not args.no_images:
        images_dir = os.path.abspath(os.path.expanduser(args.images or DEFAULT_IMAGES_DIR))
        if os.path.isdir(images_dir):
            image_plan = collect_images(images_dir, errors)
        elif args.images:
            errors.append(f"Images directory not found: {images_dir}")
        else:
            print(f"Note: images directory {images_dir} not found; graphics left unchanged "
                  "(pass --images DIR, or --no-images to silence this).")

    if errors:
        print("Error: the store listing inputs are not valid:")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)

    print(f"Package: {pkg}")
    print(f"Listing text from {base_dir}:")
    for lang, fields in listings.items():
        print(f"  {lang}:")
        for fname, field, limit in TEXT_LIMITS:
            text = fields[field]
            shown = text if field != "fullDescription" else (text[:70].replace("\n", " ") + ("..." if len(text) > 70 else ""))
            print(f"    {field} ({len(text)}/{limit}): {shown}")
    if details:
        print("App details (details.json):")
        for k, v in details.items():
            print(f"    {k}: {v}")
    if image_plan:
        print(f"Graphics for listing language {image_lang}:")
        for name, types, files, dims in image_plan:
            print(f"  {', '.join(types)}:")
            for f, d in zip(files, dims):
                print(f"    {os.path.basename(f)} {d[0]}x{d[1]}")

    creds = load_credentials(required=args.apply)
    if creds is None:
        no_credentials_notice()
        return
    api = PlayApi(creds, pkg)
    with Edit(api) as edit:
        changes = []
        current = {l.get("language"): l for l in edit.call(
            "GET", "/listings", what="Listing store listings (edits.listings.list)").get("listings", [])}
        for lang, fields in listings.items():
            cur = current.get(lang, {})
            diff = [f for f in fields if cur.get(f, "") != fields[f]]
            if diff:
                changes.append(("listing", lang, fields, f"listing {lang}: update {', '.join(diff)}"
                                + (" (new language)" if lang not in current else "")))
        if details:
            cur = edit.call("GET", "/details", what="Reading app details (edits.details.get)")
            diff = {k: v for k, v in details.items() if cur.get(k) != v}
            if diff:
                changes.append(("details", None, diff, f"details: update {', '.join(diff)}"))
        for name, types, files, dims in image_plan:
            local = [sha1_file(f) for f in files]
            for image_type in types:
                try:
                    remote = edit.call("GET", f"/listings/{image_lang}/{image_type}",
                                       what=f"Listing {image_type} (edits.images.list)").get("images", [])
                except ApiError as e:
                    if e.status != 404:
                        raise
                    remote = []
                if [r.get("sha1") for r in remote] != local:
                    changes.append(("images", image_type, files,
                                    f"{image_type} [{image_lang}]: replace {len(remote)} remote with {len(files)} local"))

        print("")
        if not changes:
            print("Play already matches the local listing; nothing to change.")
            return
        print("Changes:")
        for c in changes:
            print(f"  - {c[3]}")
        if not args.apply:
            print("")
            print("Dry run: nothing changed. Re-run with --apply to push the listing.")
            return

        for kind, key, payload, desc in changes:
            if kind == "listing":
                body = dict(payload, language=key)
                edit.call("PATCH", f"/listings/{key}", body, what=f"Updating listing {key} (edits.listings.patch)")
            elif kind == "details":
                edit.call("PATCH", "/details", payload, what="Updating app details (edits.details.patch)")
            else:
                edit.call("DELETE", f"/listings/{image_lang}/{key}",
                          what=f"Clearing {key} (edits.images.deleteall)")
                for f in payload:
                    edit.call("POST", f"/listings/{image_lang}/{key}", upload_path=f,
                              content_type="image/png", timeout=300,
                              what=f"Uploading {os.path.basename(f)} as {key} (edits.images.upload)")
            print(f"  done: {desc}")
        edit.commit(no_review=args.no_review)
    print("")
    print("Committed the store listing changes.")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        prog="play_store.py",
        description="Publish Beacon to Google Play testing tracks and push the store listing. "
                    "Dry run unless --apply is passed.")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status", help="Show tracks, releases and listing languages (read-only).")

    def add_common(p):
        p.add_argument("--apply", action="store_true", help="Actually make the change (default: dry run).")
        p.add_argument("--no-review", action="store_true",
                       help="Commit with changesNotSentForReview=true (send for review from Console).")

    def add_status(p, default="completed"):
        p.add_argument("--status", choices=["draft", "completed", "inProgress"], default=default,
                       help=f"Release status (default {default}). Use draft until the app's first rollout.")
        p.add_argument("--fraction", type=float, help="userFraction for --status inProgress (0-1).")

    up = sub.add_parser("upload", help="Upload an AAB and put it on a track.")
    up.add_argument("--track", required=True, help="internal, alpha (closed), beta (open) or a custom closed track.")
    up.add_argument("--aab", help="AAB path (default: AAB_PATH from .last_build).")
    up.add_argument("--version-code", type=int,
                    help="Assign this already uploaded versionCode to the track instead of uploading.")
    up.add_argument("--notes-file", help=f"Release notes file ('-' for stdin), max {MAX_NOTES} chars.")
    up.add_argument("--lang", default="en-US", help="Release notes language (default en-US).")
    up.add_argument("--release-name", help="Release name (default: versionName (versionCode) read from the AAB).")
    add_status(up)
    add_common(up)

    pr = sub.add_parser("promote", help="Copy the latest release from one track to another.")
    pr.add_argument("--from", dest="from_track", required=True, help="Source track, e.g. internal.")
    pr.add_argument("--to", dest="to_track", required=True, help="Destination track, e.g. alpha or beta.")
    add_status(pr)
    add_common(pr)

    li = sub.add_parser("listing", help="Push store listing text, details and graphics.")
    li.add_argument("--dir", default=DEFAULT_LISTING_DIR, help="Listing text directory (default store/google).")
    li.add_argument("--images", help=f"Graphics directory (default {DEFAULT_IMAGES_DIR}).")
    li.add_argument("--images-lang", help="Listing language the graphics belong to "
                                          "(default: details.json defaultLanguage, else en-US).")
    li.add_argument("--no-images", action="store_true", help="Leave graphics untouched.")
    add_common(li)

    args = parser.parse_args()
    try:
        {"status": cmd_status, "upload": cmd_upload, "promote": cmd_promote,
         "listing": cmd_listing}[args.command](args)
    except ApiError as e:
        print(f"Error: {e}")
        hint = explain_api_error(e)
        if hint:
            print("")
            print(hint)
        print("")
        print("Nothing was committed (the edit was discarded).")
        sys.exit(1)
    except PlayError as e:
        print(f"Error: {e}")
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nInterrupted; nothing was committed.")
        sys.exit(130)


if __name__ == "__main__":
    main()
