#!/usr/bin/env python3
"""Beacon Mobile App Store Connect store manager.

Manages App Store listing metadata, screenshots and the public TestFlight beta
for BEACON Mobile (bundle id meshcorebeacon.app) through the App Store Connect
API. Metadata comes from store/apple/ in this repo:

  store/apple/en-CA/*.txt        listing text (name, subtitle, description, ...)
  store/apple/review_notes.txt   notes for beta review and App Review
  store/apple/app.json           categories, content rights, copyright,
                                 age rating, public beta group settings

A missing (or empty) file means "leave that field unchanged". The App Review
contact is personal data and stays out of the public repo: it comes from
ASC_REVIEW_FIRST_NAME, ASC_REVIEW_LAST_NAME, ASC_REVIEW_EMAIL and
ASC_REVIEW_PHONE in the environment or ~/.beacon_release.env. So does the
server reviewers add: {REVIEW_SERVER_URL} in review_notes.txt is replaced with
ASC_REVIEW_SERVER_URL.

Auth: the same credentials upload_ios.sh and set_whats_new.sh use. ASC_KEY_ID
and ASC_ISSUER_ID in the environment or ~/.beacon_release.env (environment
wins), with the .p8 at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
unless ASC_KEY_PATH says otherwise. Set ASC_APP_ID to skip the bundle-id
lookup. A fresh ES256 token is minted (via openssl) for every request.

Every subcommand is a dry run by default: it prints what it would change
(current -> desired) and sends no writes. Pass --apply to write. Re-running
after an apply shows no changes.

Usage:
  ./asc_store.py status                          # what is set, what is empty
  ./asc_store.py metadata                        # diff store/apple/ vs ASC
  ./asc_store.py metadata --apply
  ./asc_store.py metadata --apply --create-version 0.1.0
  ./asc_store.py screenshots --dir shots/        # shots/ios-iphone-69, shots/ios-ipad-13
  ./asc_store.py screenshots --dir shots/ --apply --replace
  ./asc_store.py testflight-public               # build from .last_build
  ./asc_store.py testflight-public --build 1791081132 --apply

Python 3 standard library only. ASC_API_BASE overrides the API host (for
exercising the flow against a stub server).
"""

import argparse
import base64
import hashlib
import json
import os
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPO_ROOT = os.path.dirname(os.path.abspath(__file__))
STORE_DIR = os.path.join(REPO_ROOT, 'store', 'apple')
RELEASE_ENV = os.path.expanduser('~/.beacon_release.env')

API_BASE = os.environ.get('ASC_API_BASE', 'https://api.appstoreconnect.apple.com')
BUNDLE_ID = os.environ.get('ASC_BUNDLE_ID', 'meshcorebeacon.app')
LOCALE = 'en-CA'

LIMITS = {
    'name': 30,
    'subtitle': 30,
    'keywords': 100,
    'promotional_text': 170,
    'description': 4000,
    'beta_description': 4000,
    'whats_new': 4000,
    'review_notes': 4000,
}

# Screenshot folders -> App Store Connect ScreenshotDisplayType.
# The API has no APP_IPHONE_69 / APP_IPAD_13 values: the 6.9" iPhone slot is
# APP_IPHONE_67 and the 13" iPad slot is APP_IPAD_PRO_3GEN_129. Accepted sizes
# per Apple's "Screenshot specifications" help page.
SCREENSHOT_SETS = {
    'ios-iphone-69': {
        'displayType': 'APP_IPHONE_67',
        'label': '6.9" iPhone',
        'sizes': {(1320, 2868), (2868, 1320), (1290, 2796), (2796, 1290),
                  (1260, 2736), (2736, 1260)},
    },
    'ios-ipad-13': {
        'displayType': 'APP_IPAD_PRO_3GEN_129',
        'label': '13" iPad',
        'sizes': {(2064, 2752), (2752, 2064), (2048, 2732), (2732, 2048)},
    },
}
MAX_SCREENSHOTS_PER_SET = 10

# App Store version states in which metadata can still be edited
EDITABLE_VERSION_STATES = {
    'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED',
    'METADATA_REJECTED', 'INVALID_BINARY',
}
LIVE_INFO_STATES = {'READY_FOR_DISTRIBUTION', 'REPLACED_WITH_NEW_INFO',
                    'READY_FOR_SALE', 'REMOVED_FROM_SALE'}


class Fail(Exception):
    """A user-facing error: printed without a traceback."""


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def load_release_env():
    """Parse ~/.beacon_release.env (KEY=value, optional quotes, # comments).
    Real environment variables take precedence."""
    values = {}
    if os.path.isfile(RELEASE_ENV):
        with open(RELEASE_ENV, encoding='utf-8') as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith('#'):
                    continue
                if line.startswith('export '):
                    line = line[len('export '):].strip()
                if '=' not in line:
                    continue
                key, _, value = line.partition('=')
                key = key.strip()
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in '"\'':
                    value = value[1:-1]
                elif ' #' in value:
                    value = value.split(' #', 1)[0].rstrip()
                values[key] = value
    for key in list(values):
        if os.environ.get(key):
            values[key] = os.environ[key]
    for key, value in os.environ.items():
        if key.startswith('ASC_') and value:
            values[key] = value
    return values


ENV = load_release_env()


def env(key, default=''):
    return ENV.get(key, default) or default


def read_text(rel_path):
    """Store file contents with trailing whitespace stripped, or None when the
    file is missing or empty (both mean: leave the field unchanged)."""
    path = os.path.join(STORE_DIR, rel_path)
    if not os.path.isfile(path):
        return None
    with open(path, encoding='utf-8') as fh:
        text = fh.read().rstrip()
    return text if text else None


def load_app_json():
    path = os.path.join(STORE_DIR, 'app.json')
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding='utf-8') as fh:
            data = json.load(fh)
    except ValueError as exc:
        raise Fail('store/apple/app.json is not valid JSON: %s' % exc)
    if not isinstance(data, dict):
        raise Fail('store/apple/app.json must hold a JSON object.')
    return data


def check_limit(key, text):
    limit = LIMITS.get(key)
    if text is not None and limit and len(text) > limit:
        raise Fail('%s is %d characters; App Store Connect allows %d.' % (key, len(text), limit))
    return text


def load_listing():
    loc = LOCALE + '/'
    listing = {
        'name': read_text(loc + 'name.txt'),
        'subtitle': read_text(loc + 'subtitle.txt'),
        'description': read_text(loc + 'description.txt'),
        'keywords': read_text(loc + 'keywords.txt'),
        'promotional_text': read_text(loc + 'promotional_text.txt'),
        'support_url': read_text(loc + 'support_url.txt'),
        'marketing_url': read_text(loc + 'marketing_url.txt'),
        'privacy_url': read_text(loc + 'privacy_url.txt'),
        'beta_description': read_text(loc + 'beta_description.txt'),
        'feedback_email': read_text(loc + 'feedback_email.txt'),
        'whats_new': read_text(loc + 'whats_new.txt'),
        'review_notes': read_text('review_notes.txt'),
    }
    notes = listing['review_notes']
    if notes and '{REVIEW_SERVER_URL}' in notes:
        server = env('ASC_REVIEW_SERVER_URL')
        if not server:
            raise Fail('review_notes.txt needs ASC_REVIEW_SERVER_URL (env or %s).' % RELEASE_ENV)
        listing['review_notes'] = notes.replace('{REVIEW_SERVER_URL}', server)
    for key, value in listing.items():
        check_limit(key, value)
    return listing


def review_contact():
    return {
        'contactFirstName': env('ASC_REVIEW_FIRST_NAME') or None,
        'contactLastName': env('ASC_REVIEW_LAST_NAME') or None,
        'contactEmail': env('ASC_REVIEW_EMAIL') or None,
        'contactPhone': env('ASC_REVIEW_PHONE') or None,
    }


# ---------------------------------------------------------------------------
# App Store Connect API
# ---------------------------------------------------------------------------

def _b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b'=').decode('ascii')


def _der_to_raw(der):
    """openssl emits ECDSA signatures as DER (SEQUENCE of two INTEGERs); JWS
    ES256 wants the raw r||s pair, each padded to 32 bytes."""
    if not der or der[0] != 0x30:
        raise Fail('Unexpected signature encoding from openssl.')
    idx = 1
    length_byte = der[idx]
    idx += 1
    if length_byte & 0x80:
        idx += length_byte & 0x7F
    parts = []
    for _ in range(2):
        if der[idx] != 0x02:
            raise Fail('Unexpected signature encoding from openssl.')
        idx += 1
        int_len = der[idx]
        idx += 1
        parts.append(int.from_bytes(der[idx:idx + int_len], 'big'))
        idx += int_len
    return parts[0].to_bytes(32, 'big') + parts[1].to_bytes(32, 'big')


def mint_jwt():
    """Fresh ES256 token per request (ASC caps token lifetime at 20 minutes)."""
    key_id = env('ASC_KEY_ID')
    issuer_id = env('ASC_ISSUER_ID')
    if not key_id or not issuer_id:
        raise Fail('ASC_KEY_ID and ASC_ISSUER_ID must be set (env or %s).' % RELEASE_ENV)
    key_path = os.path.expanduser(env('ASC_KEY_PATH') or
                                  '~/.appstoreconnect/private_keys/AuthKey_%s.p8' % key_id)
    if not os.path.isfile(key_path):
        raise Fail('API key file not found: %s' % key_path)

    def compact(obj):
        return json.dumps(obj, separators=(',', ':')).encode('utf-8')

    now = int(time.time())
    header = {'alg': 'ES256', 'kid': key_id, 'typ': 'JWT'}
    payload = {'iss': issuer_id, 'iat': now, 'exp': now + 900, 'aud': 'appstoreconnect-v1'}
    signing_input = (_b64(compact(header)) + '.' + _b64(compact(payload))).encode('ascii')
    result = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', key_path],
                            input=signing_input, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise Fail('openssl could not sign with the API key:\n' +
                   result.stderr.decode('utf-8', 'replace'))
    return signing_input.decode('ascii') + '.' + _b64(_der_to_raw(result.stdout))


class APIError(Fail):
    def __init__(self, method, path, status, body):
        self.status = status
        self.body = body
        self.errors = []
        if isinstance(body, dict):
            self.errors = body.get('errors') or []
        lines = ['%s %s failed (HTTP %s).' % (method, path.split('?')[0], status)]
        if self.errors:
            for err in self.errors:
                line = '  [%s] %s: %s' % (err.get('status', status), err.get('code', ''),
                                          err.get('title', ''))
                if err.get('detail'):
                    line += ' - ' + err['detail']
                pointer = (err.get('source') or {}).get('pointer')
                if pointer:
                    line += ' (%s)' % pointer
                lines.append(line)
        elif body:
            lines.append('  ' + str(body)[:500])
        Fail.__init__(self, '\n'.join(lines))

    def mentions(self, word):
        text = json.dumps(self.errors).lower()
        return word.lower() in text


def api(method, path, body=None, params=None, ok=(200, 201, 204)):
    url = path if path.startswith('http') else API_BASE + path
    if params:
        url += ('&' if '?' in url else '?') + urllib.parse.urlencode(params, safe='[],')
    data = json.dumps(body).encode('utf-8') if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Authorization', 'Bearer ' + mint_jwt())
    if data is not None:
        req.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            status = resp.status
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        status = exc.code
        raw = exc.read()
    except urllib.error.URLError as exc:
        raise Fail('Could not reach App Store Connect: %s' % exc.reason)
    parsed = None
    if raw:
        try:
            parsed = json.loads(raw.decode('utf-8'))
        except ValueError:
            parsed = raw.decode('utf-8', 'replace')
    if status not in ok:
        raise APIError(method, path, status, parsed)
    return parsed


def get(path, params=None):
    return api('GET', path, params=params)


def get_optional(path, params=None):
    """GET a to-one relationship; None when ASC answers 404 or data: null."""
    try:
        res = get(path, params)
    except APIError as exc:
        if exc.status == 404:
            return None
        raise
    return (res or {}).get('data')


def get_all(path, params=None):
    params = dict(params or {})
    params.setdefault('limit', '200')
    res = get(path, params)
    items = list(res.get('data') or [])
    included = list(res.get('included') or [])
    nxt = (res.get('links') or {}).get('next')
    while nxt:
        res = get(nxt)
        items.extend(res.get('data') or [])
        included.extend(res.get('included') or [])
        nxt = (res.get('links') or {}).get('next')
    return items, included


def patch(type_, id_, attributes=None, relationships=None):
    data = {'type': type_, 'id': id_}
    if attributes:
        data['attributes'] = attributes
    if relationships:
        data['relationships'] = relationships
    return api('PATCH', '/v1/%s/%s' % (type_, id_), {'data': data})


def create(type_, attributes=None, relationships=None):
    data = {'type': type_}
    if attributes:
        data['attributes'] = attributes
    if relationships:
        data['relationships'] = relationships
    return api('POST', '/v1/' + type_, {'data': data})['data']


def rel(type_, id_):
    return {'data': {'type': type_, 'id': id_}}


# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------

def app_id():
    if env('ASC_APP_ID'):
        return env('ASC_APP_ID')
    res = get('/v1/apps', {'filter[bundleId]': BUNDLE_ID, 'limit': '1'})
    if not res.get('data'):
        raise Fail('No app found for bundle id %s.' % BUNDLE_ID)
    found = res['data'][0]['id']
    print('  app id %s (set ASC_APP_ID=%s in %s to skip this lookup)' % (found, found, RELEASE_ENV))
    return found


def editable_app_info(app):
    infos, _ = get_all('/v1/apps/%s/appInfos' % app)
    if not infos:
        raise Fail('The app has no appInfos.')
    for info in infos:
        state = info['attributes'].get('state') or info['attributes'].get('appStoreState')
        if state not in LIVE_INFO_STATES:
            return info
    return None


def version_state(version):
    attrs = version['attributes']
    return attrs.get('appVersionState') or attrs.get('appStoreState') or 'UNKNOWN'


def ios_versions(app):
    versions, _ = get_all('/v1/apps/%s/appStoreVersions' % app, {'filter[platform]': 'IOS'})
    return versions


def editable_version(versions):
    for version in versions:
        attrs = version['attributes']
        if (attrs.get('appVersionState') in EDITABLE_VERSION_STATES or
                attrs.get('appStoreState') in EDITABLE_VERSION_STATES):
            return version
    return None


def find_locale(items, locale=LOCALE):
    for item in items:
        if item['attributes'].get('locale') == locale:
            return item
    return None


def read_last_build_epoch():
    path = os.path.join(REPO_ROOT, '.last_build')
    if not os.path.isfile(path):
        return None
    with open(path, encoding='utf-8') as fh:
        for line in fh:
            if line.startswith('EPOCH='):
                return line.split('=', 1)[1].strip() or None
    return None


# ---------------------------------------------------------------------------
# Diff plumbing
# ---------------------------------------------------------------------------

def show(value):
    if value is None or value == '':
        return '(empty)'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if not isinstance(value, str):
        return json.dumps(value)
    flat = value.replace('\n', '\\n')
    if len(flat) > 70:
        return "'%s...' (%d chars)" % (flat[:67], len(value))
    return "'%s'" % flat


class Plan(object):
    """Collects pending writes. In dry-run they are only printed."""

    def __init__(self, apply):
        self.apply = apply
        self.count = 0
        self.notes = []

    def section(self, title):
        print('')
        print('== ' + title)

    def same(self, label, value):
        print('   = %-28s %s' % (label, show(value)))

    def change(self, label, current, desired):
        self.count += 1
        print('   ~ %-28s %s -> %s' % (label, show(current), show(desired)))

    def info(self, text):
        print('     ' + text)

    def note(self, text):
        self.notes.append(text)
        print('   ! ' + text)

    def diff_attrs(self, current_attrs, desired, labels=None):
        """Print each desired attribute; return the subset that differs."""
        changed = {}
        for key, value in desired.items():
            if value is None:
                continue
            cur = (current_attrs or {}).get(key)
            label = (labels or {}).get(key, key)
            if cur == value:
                self.same(label, cur)
            else:
                self.change(label, cur, value)
                changed[key] = value
        return changed

    def finish(self):
        print('')
        if self.count == 0:
            print('No changes.')
        elif self.apply:
            print('%d change(s) applied.' % self.count)
        else:
            print('%d change(s) pending. DRY RUN - nothing was sent. Re-run with --apply to write.'
                  % self.count)


def confirm_tty(question):
    try:
        tty = open('/dev/tty')
    except OSError:
        raise Fail('No terminal to confirm on. Re-run with --yes to proceed without a prompt.')
    with tty:
        sys.stdout.write(question + ' [y/N] ')
        sys.stdout.flush()
        answer = tty.readline().strip().lower()
    return answer in ('y', 'yes')


# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

def field_line(label, value, limit=None):
    if value is None or value == '':
        print('   %-26s EMPTY' % label)
    else:
        extra = ''
        if isinstance(value, str) and limit:
            extra = '  [%d/%d]' % (len(value), limit)
        print('   %-26s %s%s' % (label, show(value), extra))


def cmd_status(args):
    app = app_id()
    app_res = get('/v1/apps/%s' % app)['data']
    a = app_res['attributes']
    print('')
    print('== App')
    print('   %-26s %s' % ('name', a.get('name')))
    print('   %-26s %s' % ('bundleId', a.get('bundleId')))
    print('   %-26s %s' % ('sku', a.get('sku')))
    print('   %-26s %s' % ('primaryLocale', a.get('primaryLocale')))
    field_line('contentRightsDeclaration', a.get('contentRightsDeclaration'))

    info = editable_app_info(app)
    print('')
    if not info:
        print('== App info: no editable appInfo (all live)')
    else:
        state = info['attributes'].get('state') or info['attributes'].get('appStoreState')
        print('== App info %s (state %s)' % (info['id'], state))
        prim = get_optional('/v1/appInfos/%s/relationships/primaryCategory' % info['id'])
        sec = get_optional('/v1/appInfos/%s/relationships/secondaryCategory' % info['id'])
        field_line('primaryCategory', prim and prim['id'])
        field_line('secondaryCategory', sec and sec['id'])
        locs, _ = get_all('/v1/appInfos/%s/appInfoLocalizations' % info['id'])
        print('   localizations: %s' % ', '.join(sorted(l['attributes']['locale'] for l in locs)))
        loc = find_locale(locs)
        la = loc['attributes'] if loc else {}
        field_line(LOCALE + ' name', la.get('name'), 30)
        field_line(LOCALE + ' subtitle', la.get('subtitle'), 30)
        field_line(LOCALE + ' privacyPolicyUrl', la.get('privacyPolicyUrl'))
        age = get_optional('/v1/appInfos/%s/ageRatingDeclaration' % info['id'])
        if not age:
            print('   ageRatingDeclaration       (not available)')
        else:
            attrs = age['attributes']
            empty = sorted(k for k, v in attrs.items() if v is None)
            set_ = sorted(k for k, v in attrs.items() if v is not None)
            print('   ageRatingDeclaration %s: %d set, %d empty' % (age['id'], len(set_), len(empty)))
            if empty:
                print('     empty: ' + ', '.join(empty))

    versions = ios_versions(app)
    print('')
    print('== App Store versions (iOS)')
    if not versions:
        print('   none')
    for v in versions:
        print('   %s  %-10s %s' % (v['id'], v['attributes'].get('versionString'), version_state(v)))
    version = editable_version(versions)
    if not version:
        print('   No editable App Store version. Version-level metadata and screenshots need one')
        print('   (create it with: ./asc_store.py metadata --apply --create-version X.Y.Z).')
    else:
        va = version['attributes']
        print('')
        print('== Editable version %s (%s)' % (va.get('versionString'), version_state(version)))
        field_line('copyright', va.get('copyright'))
        field_line('releaseType', va.get('releaseType'))
        build = get_optional('/v1/appStoreVersions/%s/build' % version['id'])
        field_line('build', build and build['attributes'].get('version'))
        locs, _ = get_all('/v1/appStoreVersions/%s/appStoreVersionLocalizations' % version['id'])
        print('   localizations: %s' % ', '.join(sorted(l['attributes']['locale'] for l in locs)))
        loc = find_locale(locs)
        la = loc['attributes'] if loc else {}
        if not loc:
            print('   %s localization MISSING' % LOCALE)
        field_line(LOCALE + ' description', la.get('description'), 4000)
        field_line(LOCALE + ' keywords', la.get('keywords'), 100)
        field_line(LOCALE + ' promotionalText', la.get('promotionalText'), 170)
        field_line(LOCALE + ' supportUrl', la.get('supportUrl'))
        field_line(LOCALE + ' marketingUrl', la.get('marketingUrl'))
        field_line(LOCALE + ' whatsNew', la.get('whatsNew'), 4000)
        if loc:
            sets, _ = get_all('/v1/appStoreVersionLocalizations/%s/appScreenshotSets' % loc['id'])
            print('   screenshot sets:')
            if not sets:
                print('     none')
            for s in sets:
                shots, _ = get_all('/v1/appScreenshotSets/%s/appScreenshots' % s['id'])
                states = {}
                for shot in shots:
                    st = ((shot['attributes'].get('assetDeliveryState') or {}).get('state')) or '?'
                    states[st] = states.get(st, 0) + 1
                print('     %-24s %d screenshot(s) %s' % (
                    s['attributes'].get('screenshotDisplayType'), len(shots),
                    ' '.join('%s=%d' % kv for kv in sorted(states.items()))))
            for folder, spec in SCREENSHOT_SETS.items():
                if not any(s['attributes'].get('screenshotDisplayType') == spec['displayType'] for s in sets):
                    print('     %-24s MISSING (%s, from %s/)' % (spec['displayType'], spec['label'], folder))
        detail = get_optional('/v1/appStoreVersions/%s/appStoreReviewDetail' % version['id'])
        print('   App Review detail:')
        da = detail['attributes'] if detail else {}
        for key in ('contactFirstName', 'contactLastName', 'contactEmail', 'contactPhone',
                    'demoAccountRequired', 'notes'):
            field_line('  ' + key, da.get(key))

    print('')
    print('== TestFlight')
    bal, _ = get_all('/v1/apps/%s/betaAppLocalizations' % app)
    print('   beta localizations: %s' % (', '.join(sorted(l['attributes']['locale'] for l in bal)) or 'none'))
    loc = find_locale(bal) or (bal[0] if bal else None)
    la = loc['attributes'] if loc else {}
    if loc:
        print('   (showing %s)' % la.get('locale'))
    field_line('beta description', la.get('description'), 4000)
    field_line('beta feedbackEmail', la.get('feedbackEmail'))
    field_line('beta marketingUrl', la.get('marketingUrl'))
    field_line('beta privacyPolicyUrl', la.get('privacyPolicyUrl'))
    brd = get_optional('/v1/apps/%s/betaAppReviewDetail' % app)
    print('   beta review detail:')
    ba = brd['attributes'] if brd else {}
    for key in ('contactFirstName', 'contactLastName', 'contactEmail', 'contactPhone',
                'demoAccountRequired', 'notes'):
        field_line('  ' + key, ba.get(key))

    groups, _ = get_all('/v1/apps/%s/betaGroups' % app)
    print('   beta groups:')
    if not groups:
        print('     none')
    for g in groups:
        ga = g['attributes']
        kind = 'internal' if ga.get('isInternalGroup') else 'external'
        print('     %-22s %s, publicLink %s%s, feedback %s' % (
            ga.get('name'), kind,
            'on' if ga.get('publicLinkEnabled') else 'off',
            (' limit %s' % ga.get('publicLinkLimit')) if ga.get('publicLinkLimitEnabled') else '',
            'on' if ga.get('feedbackEnabled') else 'off'))
        if ga.get('publicLink'):
            print('       %s' % ga.get('publicLink'))

    builds, included = get_all('/v1/builds', {
        'filter[app]': app, 'sort': '-uploadedDate', 'limit': '5',
        'include': 'buildBetaDetail,preReleaseVersion'})
    builds = builds[:5]
    details = {i['id']: i for i in included if i['type'] == 'buildBetaDetails'}
    prv = {i['id']: i for i in included if i['type'] == 'preReleaseVersions'}
    print('   latest builds:')
    for b in builds:
        ba = b['attributes']
        rel_d = ((b.get('relationships') or {}).get('buildBetaDetail') or {}).get('data') or {}
        rel_p = ((b.get('relationships') or {}).get('preReleaseVersion') or {}).get('data') or {}
        bd = details.get(rel_d.get('id'), {}).get('attributes', {})
        pv = prv.get(rel_p.get('id'), {}).get('attributes', {})
        print('     %s (%s) uploaded %s processing=%s external=%s internal=%s encryption=%s%s' % (
            ba.get('version'), pv.get('version', '?'), (ba.get('uploadedDate') or '')[:10],
            ba.get('processingState'), bd.get('externalBuildState'), bd.get('internalBuildState'),
            show(ba.get('usesNonExemptEncryption')),
            ' EXPIRED' if ba.get('expired') else ''))
    subs, _ = get_all('/v1/betaAppReviewSubmissions', {'filter[build]': ','.join(b['id'] for b in builds)}) \
        if builds else ([], [])
    print('   beta review submissions:')
    if not subs:
        print('     none')
    by_id = {b['id']: b['attributes'].get('version') for b in builds}
    for s in subs:
        bid = ((s.get('relationships') or {}).get('build') or {}).get('data') or {}
        print('     build %s: %s (submitted %s)' % (
            by_id.get(bid.get('id'), '?'), s['attributes'].get('betaReviewState'),
            (s['attributes'].get('submittedDate') or '')[:10]))

    print('')
    print('Not managed here (App Store Connect web UI): App Privacy "nutrition labels" (no public')
    print('API), pricing and availability, and submitting the version for App Review.')


# ---------------------------------------------------------------------------
# metadata
# ---------------------------------------------------------------------------

def cmd_metadata(args):
    listing = load_listing()
    cfg = load_app_json()
    plan = Plan(args.apply)
    app = app_id()
    app_res = get('/v1/apps/%s' % app)['data']

    # --- App -------------------------------------------------------------
    plan.section('App (contentRightsDeclaration)')
    changed = plan.diff_attrs(app_res['attributes'],
                              {'contentRightsDeclaration': cfg.get('contentRightsDeclaration')})
    if changed and plan.apply:
        patch('apps', app, changed)
    if not cfg.get('contentRightsDeclaration'):
        plan.info('(app.json contentRightsDeclaration not set - unchanged)')

    # --- App info ----------------------------------------------------------
    info = editable_app_info(app)
    if not info:
        plan.section('App info')
        plan.note('No editable appInfo; name/subtitle/categories/age rating skipped.')
    else:
        plan.section('App info categories (appInfo %s)' % info['id'])
        prim = get_optional('/v1/appInfos/%s/relationships/primaryCategory' % info['id'])
        sec = get_optional('/v1/appInfos/%s/relationships/secondaryCategory' % info['id'])
        rels = {}
        for key, cur in (('primaryCategory', prim), ('secondaryCategory', sec)):
            want = cfg.get(key)
            if not want:
                plan.info('(app.json %s not set - unchanged)' % key)
                continue
            cur_id = cur and cur['id']
            if cur_id == want:
                plan.same(key, cur_id)
            else:
                plan.change(key, cur_id, want)
                rels[key] = rel('appCategories', want)
        if rels and plan.apply:
            patch('appInfos', info['id'], relationships=rels)

        plan.section('App info localization %s' % LOCALE)
        locs, _ = get_all('/v1/appInfos/%s/appInfoLocalizations' % info['id'])
        loc = find_locale(locs)
        desired = {'name': listing['name'], 'subtitle': listing['subtitle'],
                   'privacyPolicyUrl': listing['privacy_url']}
        if loc is None:
            plan.info('(%s localization does not exist - will be created)' % LOCALE)
        changed = plan.diff_attrs(loc and loc['attributes'], desired)
        if changed and plan.apply:
            if loc:
                patch('appInfoLocalizations', loc['id'], changed)
            else:
                if not changed.get('name'):
                    raise Fail('Creating the %s appInfoLocalization needs name.txt.' % LOCALE)
                changed['locale'] = LOCALE
                create('appInfoLocalizations', changed, {'appInfo': rel('appInfos', info['id'])})

        plan.section('Age rating declaration')
        want_age = cfg.get('ageRating') or {}
        if not want_age:
            plan.info('(app.json ageRating not set - unchanged)')
        else:
            age = get_optional('/v1/appInfos/%s/ageRatingDeclaration' % info['id'])
            if not age:
                plan.note('No ageRatingDeclaration found on appInfo %s.' % info['id'])
            else:
                unknown = sorted(k for k in want_age if k not in age['attributes'])
                if unknown:
                    plan.note('ageRating keys not reported by ASC (sent anyway): ' + ', '.join(unknown))
                changed = plan.diff_attrs(age['attributes'], want_age)
                if changed and plan.apply:
                    patch('ageRatingDeclarations', age['id'], changed)

    # --- App Store version -----------------------------------------------
    versions = ios_versions(app)
    version = editable_version(versions)
    plan.section('App Store version')
    if not version and args.create_version:
        if any(v['attributes'].get('versionString') == args.create_version for v in versions):
            raise Fail('Version %s already exists and is not editable.' % args.create_version)
        plan.change('new iOS version', None, args.create_version)
        if plan.apply:
            version = create('appStoreVersions',
                             {'platform': 'IOS', 'versionString': args.create_version},
                             {'app': rel('apps', app)})
    if not version:
        if not args.create_version:
            plan.note('No editable App Store version; skipping copyright, description, keywords, '
                      'promotional text, URLs, whats new and App Review detail. '
                      'Pass --create-version X.Y.Z to create one.')
        else:
            plan.info('(dry run: version-level fields would be set on the new version)')
            _version_fields(plan, None, None, listing, cfg, first_version=not versions)
    else:
        plan.info('%s (%s)' % (version['attributes'].get('versionString'), version_state(version)))
        others = [v for v in versions if v['id'] != version['id']]
        _version_fields(plan, version, version['attributes'], listing, cfg,
                        first_version=not others)

    # --- TestFlight ------------------------------------------------------
    plan.section('Beta app localization %s' % LOCALE)
    bal, _ = get_all('/v1/apps/%s/betaAppLocalizations' % app)
    loc = find_locale(bal)
    desired = {'description': listing['beta_description'], 'feedbackEmail': listing['feedback_email'],
               'marketingUrl': listing['marketing_url'], 'privacyPolicyUrl': listing['privacy_url']}
    if loc is None:
        plan.info('(%s beta localization does not exist - will be created)' % LOCALE)
    changed = plan.diff_attrs(loc and loc['attributes'], desired)
    if changed and plan.apply:
        if loc:
            patch('betaAppLocalizations', loc['id'], changed)
        else:
            changed['locale'] = LOCALE
            create('betaAppLocalizations', changed, {'app': rel('apps', app)})

    plan.section('Beta app review detail')
    brd = get_optional('/v1/apps/%s/betaAppReviewDetail' % app)
    desired = dict(review_contact())
    desired['notes'] = listing['review_notes']
    desired['demoAccountRequired'] = False
    _note_missing_contact(plan, desired)
    if not brd:
        plan.note('No betaAppReviewDetail on the app (ASC normally creates one).')
    else:
        changed = plan.diff_attrs(brd['attributes'], desired)
        if changed and plan.apply:
            patch('betaAppReviewDetails', brd['id'], changed)

    plan.finish()


def _note_missing_contact(plan, desired):
    missing = [k for k in ('contactFirstName', 'contactLastName', 'contactEmail', 'contactPhone')
               if not desired.get(k)]
    if missing:
        plan.info('(env %s not set - unchanged)' % ', '.join(
            'ASC_REVIEW_' + {'contactFirstName': 'FIRST_NAME', 'contactLastName': 'LAST_NAME',
                             'contactEmail': 'EMAIL', 'contactPhone': 'PHONE'}[k] for k in missing))


def _version_fields(plan, version, vattrs, listing, cfg, first_version):
    vid = version and version['id']

    plan.section('App Store version copyright')
    changed = plan.diff_attrs(vattrs, {'copyright': cfg.get('copyright')})
    if not cfg.get('copyright'):
        plan.info('(app.json copyright not set - unchanged)')
    if changed and plan.apply:
        patch('appStoreVersions', vid, changed)

    plan.section('App Store version localization %s' % LOCALE)
    loc = None
    if vid:
        locs, _ = get_all('/v1/appStoreVersions/%s/appStoreVersionLocalizations' % vid)
        loc = find_locale(locs)
    desired = {'description': listing['description'], 'keywords': listing['keywords'],
               'promotionalText': listing['promotional_text'], 'supportUrl': listing['support_url'],
               'marketingUrl': listing['marketing_url'], 'whatsNew': listing['whats_new']}
    if first_version and desired['whatsNew'] is not None:
        plan.note("whatsNew skipped: this is the app's first App Store version (ASC only "
                  "accepts What's New on updates).")
        desired['whatsNew'] = None
    if loc is None:
        plan.info('(%s localization does not exist - will be created)' % LOCALE)
    changed = plan.diff_attrs(loc and loc['attributes'], desired)
    if changed and plan.apply:
        try:
            if loc:
                patch('appStoreVersionLocalizations', loc['id'], changed)
            else:
                attrs = dict(changed, locale=LOCALE)
                create('appStoreVersionLocalizations', attrs,
                       {'appStoreVersion': rel('appStoreVersions', vid)})
        except APIError as exc:
            if 'whatsNew' in changed and exc.mentions('whatsNew'):
                plan.note("ASC rejected whatsNew; retrying without it:\n" + str(exc))
                changed.pop('whatsNew')
                if loc:
                    if changed:
                        patch('appStoreVersionLocalizations', loc['id'], changed)
                else:
                    create('appStoreVersionLocalizations', dict(changed, locale=LOCALE),
                           {'appStoreVersion': rel('appStoreVersions', vid)})
            else:
                raise

    plan.section('App Review detail (App Store submission)')
    desired = dict(review_contact())
    desired['notes'] = listing['review_notes']
    desired['demoAccountRequired'] = False
    _note_missing_contact(plan, desired)
    detail = get_optional('/v1/appStoreVersions/%s/appStoreReviewDetail' % vid) if vid else None
    if detail is None:
        plan.info('(App Review detail does not exist - will be created)')
    changed = plan.diff_attrs(detail and detail['attributes'], desired)
    if changed and plan.apply:
        if detail:
            patch('appStoreReviewDetails', detail['id'], changed)
        else:
            create('appStoreReviewDetails', changed,
                   {'appStoreVersion': rel('appStoreVersions', vid)})


# ---------------------------------------------------------------------------
# screenshots
# ---------------------------------------------------------------------------

def png_size(path):
    with open(path, 'rb') as fh:
        head = fh.read(24)
    if len(head) < 24 or head[:8] != b'\x89PNG\r\n\x1a\n' or head[12:16] != b'IHDR':
        raise Fail('%s is not a PNG.' % path)
    return struct.unpack('>II', head[16:24])


def md5_file(path):
    h = hashlib.md5()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def shot_state(shot):
    return ((shot['attributes'].get('assetDeliveryState') or {}).get('state')) or 'UNKNOWN'


def upload_screenshot(set_id, path, checksum):
    size = os.path.getsize(path)
    name = os.path.basename(path)
    shot = create('appScreenshots', {'fileName': name, 'fileSize': size},
                  {'appScreenshotSet': rel('appScreenshotSets', set_id)})
    ops = shot['attributes'].get('uploadOperations') or []
    with open(path, 'rb') as fh:
        blob = fh.read()
    for op in ops:
        chunk = blob[op['offset']:op['offset'] + op['length']]
        req = urllib.request.Request(op['url'], data=chunk, method=op.get('method', 'PUT'))
        for header in op.get('requestHeaders') or []:
            req.add_header(header['name'], header['value'])
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                resp.read()
        except urllib.error.HTTPError as exc:
            raise Fail('Uploading %s chunk at offset %s failed (HTTP %s): %s' % (
                name, op['offset'], exc.code, exc.read()[:300]))
        except urllib.error.URLError as exc:
            raise Fail('Uploading %s failed: %s' % (name, exc.reason))
    patch('appScreenshots', shot['id'], {'uploaded': True, 'sourceFileChecksum': checksum})
    deadline = time.time() + 300
    while True:
        cur = get('/v1/appScreenshots/%s' % shot['id'])['data']
        state = shot_state(cur)
        if state == 'COMPLETE':
            return cur
        if state == 'FAILED':
            errs = (cur['attributes'].get('assetDeliveryState') or {}).get('errors') or []
            raise Fail('ASC failed to process %s: %s' % (name, '; '.join(
                '%s %s' % (e.get('code', ''), e.get('description', '')) for e in errs) or 'no detail'))
        if time.time() > deadline:
            print('     %s still %s after 5 min; continuing (check again with status).' % (name, state))
            return cur
        time.sleep(3)


def cmd_screenshots(args):
    plan = Plan(args.apply)
    root = os.path.abspath(args.dir)
    if not os.path.isdir(root):
        raise Fail('Screenshot directory not found: %s' % root)

    # Validate local files first, before any network call
    local = {}
    for folder, spec in SCREENSHOT_SETS.items():
        path = os.path.join(root, folder)
        if not os.path.isdir(path):
            continue
        files = sorted(f for f in os.listdir(path) if f.lower().endswith('.png'))
        if not files:
            continue
        if len(files) > MAX_SCREENSHOTS_PER_SET:
            raise Fail('%s has %d PNGs; App Store Connect allows %d per set.' % (
                folder, len(files), MAX_SCREENSHOTS_PER_SET))
        entries = []
        for name in files:
            full = os.path.join(path, name)
            w, h = png_size(full)
            if (w, h) not in spec['sizes']:
                raise Fail('%s/%s is %dx%d; %s accepts %s.' % (
                    folder, name, w, h, spec['label'],
                    ', '.join('%dx%d' % s for s in sorted(spec['sizes']))))
            entries.append({'name': name, 'path': full, 'md5': md5_file(full), 'size': (w, h)})
        local[folder] = entries
    if not local:
        raise Fail('No PNGs found under %s/{%s}.' % (root, ','.join(SCREENSHOT_SETS)))

    app = app_id()
    version = editable_version(ios_versions(app))
    if not version:
        raise Fail('No editable App Store version. Create one first: '
                   './asc_store.py metadata --apply --create-version X.Y.Z')
    locs, _ = get_all('/v1/appStoreVersions/%s/appStoreVersionLocalizations' % version['id'])
    loc = find_locale(locs)
    if not loc:
        raise Fail('Version %s has no %s localization. Run ./asc_store.py metadata --apply first.'
                   % (version['attributes'].get('versionString'), LOCALE))
    sets, _ = get_all('/v1/appStoreVersionLocalizations/%s/appScreenshotSets' % loc['id'])

    for folder, entries in local.items():
        spec = SCREENSHOT_SETS[folder]
        dtype = spec['displayType']
        plan.section('%s -> %s (%s)' % (folder, dtype, spec['label']))
        sset = next((s for s in sets if s['attributes'].get('screenshotDisplayType') == dtype), None)
        existing = []
        if sset:
            existing, _ = get_all('/v1/appScreenshotSets/%s/appScreenshots' % sset['id'])
            order = get('/v1/appScreenshotSets/%s/relationships/appScreenshots' % sset['id'],
                        {'limit': '50'}).get('data') or []
            pos = {o['id']: i for i, o in enumerate(order)}
            existing.sort(key=lambda s: pos.get(s['id'], 999))
        else:
            plan.change('screenshot set', None, 'create ' + dtype)
            if plan.apply:
                sset = create('appScreenshotSets', {'screenshotDisplayType': dtype},
                              {'appStoreVersionLocalization': rel('appStoreVersionLocalizations', loc['id'])})

        # Screenshots to delete: everything on --replace, plus failed uploads
        to_delete = []
        keep = []
        for shot in existing:
            if args.replace or shot_state(shot) == 'FAILED':
                to_delete.append(shot)
            else:
                keep.append(shot)
        for shot in to_delete:
            plan.change('delete', '%s [%s]' % (shot['attributes'].get('fileName'), shot_state(shot)), None)

        by_md5 = {}
        for shot in keep:
            by_md5.setdefault(shot['attributes'].get('sourceFileChecksum'), []).append(shot)
        matched = []  # (entry, existing shot or None)
        for entry in entries:
            hit = by_md5.get(entry['md5'])
            if hit:
                shot = hit.pop(0)
                plan.same(entry['name'], 'already uploaded (%s)' % shot_state(shot))
                matched.append((entry, shot))
            else:
                plan.change(entry['name'], None, 'upload %dx%d' % entry['size'])
                matched.append((entry, None))
        extras = [s for lst in by_md5.values() for s in lst]
        for shot in extras:
            plan.info('kept, not in %s/: %s (pass --replace to remove)' % (
                folder, shot['attributes'].get('fileName')))
        total = len(entries) + len(extras)
        if total > MAX_SCREENSHOTS_PER_SET:
            raise Fail('%s would hold %d screenshots (max %d). Use --replace.' % (
                dtype, total, MAX_SCREENSHOTS_PER_SET))

        current_order = [s['id'] for s in keep]
        desired_known = [s['id'] for _, s in matched if s] + [s['id'] for s in extras]
        needs_upload = any(s is None for _, s in matched)
        if not needs_upload and not to_delete and current_order != desired_known:
            plan.change('order', ', '.join(s['attributes'].get('fileName') or '?' for s in keep),
                        ', '.join(e['name'] for e in entries))

        if not plan.apply:
            continue
        for shot in to_delete:
            api('DELETE', '/v1/appScreenshots/%s' % shot['id'])
        final = []
        for entry, shot in matched:
            if shot is None:
                print('     uploading %s...' % entry['name'])
                shot = upload_screenshot(sset['id'], entry['path'], entry['md5'])
            final.append(shot['id'])
        final += [s['id'] for s in extras]
        order = get('/v1/appScreenshotSets/%s/relationships/appScreenshots' % sset['id'],
                    {'limit': '50'}).get('data') or []
        if [o['id'] for o in order] != final:
            api('PATCH', '/v1/appScreenshotSets/%s/relationships/appScreenshots' % sset['id'],
                {'data': [{'type': 'appScreenshots', 'id': i} for i in final]})
            print('     reordered to match file order')

    for folder in SCREENSHOT_SETS:
        if folder not in local:
            print('')
            print('(%s/ not found or empty - %s set left unchanged)' % (folder, SCREENSHOT_SETS[folder]['displayType']))
    plan.finish()


# ---------------------------------------------------------------------------
# testflight-public
# ---------------------------------------------------------------------------

def find_build(app, number):
    if number:
        res = get('/v1/builds', {'filter[app]': app, 'filter[version]': number,
                                 'sort': '-uploadedDate', 'limit': '1'})
        if not res.get('data'):
            raise Fail('Build %s not found in App Store Connect.' % number)
        return res['data'][0]
    res = get('/v1/builds', {'filter[app]': app, 'filter[processingState]': 'VALID',
                             'sort': '-uploadedDate', 'limit': '1'})
    if not res.get('data'):
        raise Fail('No VALID build found. Upload one with ./upload_ios.sh.')
    return res['data'][0]


def cmd_testflight_public(args):
    cfg = load_app_json()
    pb = cfg.get('publicBeta') or {}
    group_name = pb.get('groupName') or 'Public Beta'
    limit = pb.get('publicLinkLimit')
    plan = Plan(args.apply)
    app = app_id()

    number = args.build or read_last_build_epoch()
    build = find_build(app, number)
    ba = build['attributes']
    plan.section('Build %s (%s)' % (ba.get('version'), build['id']))
    plan.info('processingState=%s uploaded=%s%s' % (
        ba.get('processingState'), (ba.get('uploadedDate') or '')[:19],
        ' EXPIRED' if ba.get('expired') else ''))
    if ba.get('processingState') != 'VALID':
        raise Fail('Build %s is %s, not VALID; it cannot go to external testers yet.' % (
            ba.get('version'), ba.get('processingState')))
    if ba.get('expired'):
        raise Fail('Build %s has expired.' % ba.get('version'))
    detail = get_optional('/v1/builds/%s/buildBetaDetail' % build['id'])
    ext_state = detail and detail['attributes'].get('externalBuildState')
    plan.info('externalBuildState=%s' % ext_state)

    if ba.get('usesNonExemptEncryption') is None:
        plan.change('usesNonExemptEncryption', None, False)
        if plan.apply:
            patch('builds', build['id'], {'usesNonExemptEncryption': False})
    else:
        plan.same('usesNonExemptEncryption', ba.get('usesNonExemptEncryption'))

    # --- Group -----------------------------------------------------------
    plan.section('External beta group "%s"' % group_name)
    groups, _ = get_all('/v1/apps/%s/betaGroups' % app)
    group = next((g for g in groups if g['attributes'].get('name') == group_name), None)
    if group and group['attributes'].get('isInternalGroup'):
        raise Fail('Beta group "%s" is an internal group; pick another publicBeta.groupName.' % group_name)
    desired = {'publicLinkEnabled': True, 'feedbackEnabled': True}
    if limit:
        desired['publicLinkLimitEnabled'] = True
        desired['publicLinkLimit'] = int(limit)
    if group is None:
        plan.change('group', None, 'create "%s"' % group_name)
        plan.diff_attrs({}, desired)
        if plan.apply:
            group = create('betaGroups', {'name': group_name, 'feedbackEnabled': True},
                           {'app': rel('apps', app)})
    else:
        plan.diff_attrs(group['attributes'], desired)
    gid = group and group['id']

    in_group = False
    if gid and 'id' in (group or {}):
        members, _ = get_all('/v1/betaGroups/%s/relationships/builds' % gid)
        in_group = any(m['id'] == build['id'] for m in members)
    if in_group:
        plan.same('build in group', ba.get('version'))
    else:
        plan.change('build in group', None, ba.get('version'))
        if plan.apply:
            api('POST', '/v1/betaGroups/%s/relationships/builds' % gid,
                {'data': [{'type': 'builds', 'id': build['id']}]})

    # Public link settings after the build is in the group: ASC may refuse to
    # enable a public link on a group that has no build yet.
    if plan.apply and gid:
        cur = get('/v1/betaGroups/%s' % gid)['data']['attributes']
        pending = {k: v for k, v in desired.items() if cur.get(k) != v}
        if pending:
            try:
                patch('betaGroups', gid, pending)
            except APIError as exc:
                plan.note('Could not update the public link settings yet:\n' + str(exc))

    # --- Beta review submission -----------------------------------------
    plan.section('Beta App Review submission')
    subs, _ = get_all('/v1/betaAppReviewSubmissions', {'filter[build]': build['id']})
    if subs:
        plan.same('submission', subs[0]['attributes'].get('betaReviewState'))
    else:
        # Preflight: what ASC needs before it accepts a beta review submission
        missing = []
        bal, _ = get_all('/v1/apps/%s/betaAppLocalizations' % app)
        loc = find_locale(bal)
        la = loc['attributes'] if loc else {}
        if not la.get('description'):
            missing.append('beta app description (%s betaAppLocalization)' % LOCALE)
        if not la.get('feedbackEmail'):
            missing.append('beta feedback email (%s betaAppLocalization)' % LOCALE)
        brd = get_optional('/v1/apps/%s/betaAppReviewDetail' % app)
        bra = brd['attributes'] if brd else {}
        for key in ('contactFirstName', 'contactLastName', 'contactEmail', 'contactPhone'):
            if not bra.get(key):
                missing.append('beta review %s' % key)
        bbl, _ = get_all('/v1/builds/%s/betaBuildLocalizations' % build['id'])
        if not any((l['attributes'].get('whatsNew') or '').strip() for l in bbl):
            plan.info('warning: build has no "What to Test" text (./set_whats_new.sh sets it)')

        if ext_state == 'READY_FOR_BETA_SUBMISSION' or (
                ext_state == 'MISSING_EXPORT_COMPLIANCE' and ba.get('usesNonExemptEncryption') is None):
            if missing:
                plan.note('Not submitting: missing ' + '; '.join(missing) +
                          '. Fill store/apple/ + ASC_REVIEW_* and run ./asc_store.py metadata --apply.')
            else:
                plan.change('submission', None, 'submit build %s for Beta App Review' % ba.get('version'))
                if plan.apply:
                    if ext_state != 'READY_FOR_BETA_SUBMISSION':
                        detail = get_optional('/v1/builds/%s/buildBetaDetail' % build['id'])
                        ext_state = detail and detail['attributes'].get('externalBuildState')
                    if ext_state != 'READY_FOR_BETA_SUBMISSION':
                        plan.note('Build is %s after setting export compliance; not submitting. '
                                  'Re-run in a minute.' % ext_state)
                    elif args.yes or confirm_tty('Submit build %s for Beta App Review?' % ba.get('version')):
                        res = api('POST', '/v1/betaAppReviewSubmissions', {'data': {
                            'type': 'betaAppReviewSubmissions',
                            'relationships': {'build': rel('builds', build['id'])}}})
                        print('     submitted: %s' % res['data']['attributes'].get('betaReviewState'))
                    else:
                        print('     Not submitted.')
                        plan.count -= 1
        else:
            plan.info('externalBuildState %s - no submission needed or possible.' % ext_state)
            if missing:
                plan.info('still missing for a future submission: ' + '; '.join(missing))

    plan.finish()
    link = None
    if gid:
        link = get('/v1/betaGroups/%s' % gid)['data']['attributes'].get('publicLink')
    print('')
    if link:
        print('Public TestFlight link: %s' % link)
    else:
        print('Public TestFlight link: (not created yet)')
    print('The link only lets testers in once Beta App Review approves a build for this group.')


# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Manage BEACON Mobile App Store Connect metadata, screenshots and public TestFlight.')
    sub = parser.add_subparsers(dest='command')
    sub.required = True

    sub.add_parser('status', help='read-only overview of what is set and what is empty')

    p = sub.add_parser('metadata', help='push store/apple/ metadata (dry run unless --apply)')
    p.add_argument('--apply', action='store_true', help='perform the writes')
    p.add_argument('--create-version', metavar='X.Y.Z',
                   help='create this iOS App Store version if none is editable')

    p = sub.add_parser('screenshots', help='upload screenshots (dry run unless --apply)')
    p.add_argument('--dir', required=True, help='folder holding ios-iphone-69/ and ios-ipad-13/')
    p.add_argument('--apply', action='store_true', help='perform the writes')
    p.add_argument('--replace', action='store_true',
                   help='delete existing screenshots in those sets first')

    p = sub.add_parser('testflight-public', help='public TestFlight group + beta review submission')
    p.add_argument('--build', help='build number (default: EPOCH from .last_build, else newest VALID)')
    p.add_argument('--apply', action='store_true', help='perform the writes')
    p.add_argument('--yes', '-y', action='store_true', help='skip the submission confirmation prompt')

    args = parser.parse_args()
    handlers = {'status': cmd_status, 'metadata': cmd_metadata,
                'screenshots': cmd_screenshots, 'testflight-public': cmd_testflight_public}
    print('App Store Connect: %s (%s)%s' % (
        BUNDLE_ID, LOCALE, '' if getattr(args, 'apply', False) or args.command == 'status'
        else '  [DRY RUN]'))
    try:
        handlers[args.command](args)
    except Fail as exc:
        print('')
        print('Error: %s' % exc, file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print('\nInterrupted.', file=sys.stderr)
        sys.exit(130)


if __name__ == '__main__':
    main()
