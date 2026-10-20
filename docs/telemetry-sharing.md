# Companion telemetry sharing: research and draft integration

Research snapshot: 20 October 2026. App base: `1fb479f97579defe069fae59cccff8fb92649eb0`.
This is a draft alpha, not a production rollout or a replacement for an always-on collector yet.

## What this adds

Settings → Telemetry sharing opens an opt-in session tied to the selected HTTPS
Beacon instance. Connect an exclusive MeshCore companion via **BLE or Wi-Fi/TCP**, select up to six saved repeaters, optionally enter a repeater password
and require admin access, then start. The default interval is six hours, configurable
from one to 72 hours. Environmental sensors, including channel 2, are optional.
The first attempt uses flood discovery; successful login can teach the companion
a route used by the subsequent status/telemetry requests and future polls.

The screen must remain open. Leaving it, locking/backgrounding the app, disconnecting,
or stopping closes the companion connection. Reconnecting requires explicit action.
Saved cooldowns and already collected reports survive a restart. Passwords do not.
BLE discovery lists Nordic UART companions; select the radio and accept any OS pairing prompt.
Wi-Fi/TCP requires its private LAN address and port. Both transports share identity,
cooldowns, congestion checks, enrollment and delivery. There is no firmware installation, private-key export, radio console, packet forwarding,
GPS upload or mobile background service in this draft.

The current upstream Flutter app is an HTTP/WebSocket viewer. Its upstream backend
does not expose the collected-node telemetry intake described below. A compatible
separate intake must be deployed and routed by the instance operator before this
option can work there. A 404 or failed enrollment blocks all RF polling. This is
an installation prerequisite, not manual authorization of each participant.
For the existing experimental intake, add `https://canadaverse.org/beacon-dev` as
a server and select it. Do not assume `meshcore.ca` or `live.meshcore.ca` supports
this yet. No production configuration is changed by this PR.

## Research and choices

| Area | Source finding | Draft choice |
|---|---|---|
| App architecture | Existing server picker, REST/WSS viewer, foreground lifecycle | Reuse the selected instance and settings flow; explicit foreground session |
| Companion protocol | BLE values are complete frames; native TCP framing: `<`, uint16 LE length, command; replies use `>` | MeshMapper-pinned `flutter_blue_plus` 1.36.8 for BLE; `dart:io` for TCP; one shared protocol client |
| Device signing | Firmware supports SIGN_START/DATA/FINISH (33/34/35) | Radio signs only the validated, domain-separated enrollment challenge; its private key stays on-device |
| Identity | Contacts have full 32-byte keys; packed route length encodes 1/2/3-byte hashes | Full-key selection, preserve zero path bytes; reject malformed paths |
| Login ambiguity | Firmware pending-login lookup uses four bytes; push includes six | Reject any selected contact with a duplicate four-byte prefix in the companion list |
| Reply races | Binary response can arrive before SEND returns the request tag | Subscribe before transmit, retain bounded early replies, require the exact returned tag |
| Sensors | Binary telemetry requests return all permitted LPP channels; guest permissions may expose base sensors only | Allowlist voltage, temperature, humidity, pressure and illuminance; preserve channel numbers and explicit zero; skip GPS |
| MeshCore HA | Per-radio persisted flood/direct/message budgets; separate login and data costs | Conservative persisted budget covering all poll commands; no immediate route-healing retries |
| MQTT | Observer packet forwarding is not the collected-repeater telemetry contract | Signed HTTPS first; dedicated MQTT topic/credentials/receipt work remains below |
| Phones | iOS/Android can suspend background work; BLE requires platform permission and lifecycle qualification | Foreground-only BLE and Wi-Fi; retain Collector as an alternate always-on client |

Sources inspected at pinned revisions:

- [MeshCore companion firmware](https://github.com/meshcore-dev/MeshCore/blob/81dbae592ffad40b4212bc0b37e82b38da08f4bc/examples/companion_radio/MyMesh.cpp)
  and [repeater firmware](https://github.com/meshcore-dev/MeshCore/blob/81dbae592ffad40b4212bc0b37e82b38da08f4bc/examples/simple_repeater/MyMesh.cpp).
- [Companion protocol guide](https://github.com/meshcore-dev/MeshCore/blob/81dbae592ffad40b4212bc0b37e82b38da08f4bc/docs/companion_protocol.md).
  The guide warns that portions can be incomplete; firmware is authoritative.
- [meshcore_py TCP framing](https://github.com/meshcore-dev/meshcore_py/blob/105f407b85b19709ffff8616d3bf1e83b79c0b9a/src/meshcore/tcp_cx.py),
  [binary requests](https://github.com/meshcore-dev/meshcore_py/blob/105f407b85b19709ffff8616d3bf1e83b79c0b9a/src/meshcore/commands/binary.py)
  and [parser](https://github.com/meshcore-dev/meshcore_py/blob/105f407b85b19709ffff8616d3bf1e83b79c0b9a/src/meshcore/reader.py).
- [MeshCore HA traffic governance](https://github.com/meshcore-dev/meshcore-ha/blob/36074f863dc04f271114573c33fc23f306176e55/custom_components/meshcore/traffic.py)
  and [MQTT uploader](https://github.com/meshcore-dev/meshcore-ha/blob/36074f863dc04f271114573c33fc23f306176e55/custom_components/meshcore/mqtt_uploader.py).
  Its flood bucket is burst 5/refill 20 per hour, direct 20/120 and messages 10/60.
  We do not copy its immediate route retries or radio-private-key export for MQTT JWTs.
- [Cayenne LPP data types](https://github.com/myDevicesIoT/CayenneLPP) and
  [extended types](https://github.com/ElectronicCats/CayenneLPP).
- [Apple Core Bluetooth background execution](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
  and [Android BLE background guidance](https://developer.android.com/develop/connectivity/bluetooth/ble/background).

This is a fresh client implementation against protocol/interface facts. No private
Collector implementation or history is copied into the app. The intake remains a
separate service regardless of which client collects measurements.

## RF limits and scheduling

- Persist an attempt before any RF command. A crash, disconnect, login failure,
  new server selection, manual restart or interval reduction cannot erase it.
- At most two repeater attempts per companion in a rolling hour, reserving three
  commands each: login, status, optional telemetry. Unused reservations are not
  refunded. Attempts are spaced by at least one minute and run serially.
- Require two local airtime samples at least 15 seconds apart. A nonempty TX
  queue, reset/decreasing counters, unknown stats or combined TX/RX duty above
  10% defers polling. These are local heuristics, not a regional congestion meter.
- Learned routes over three hops are not polled. Flood discovery cannot guarantee
  a three-hop cap; firmware/network policy still controls propagation.
- A failed route may rediscover only on its next scheduled attempt. BLE link setup may retry up to three times before any RF; confirmed Android GATT-busy refusals retry at 50/100/150 ms, while uncertain write failures do not. There are no
  catch-up bursts or immediate flood retries. Other apps/radios cannot be governed
  by this local budget; use the companion exclusively.
- A system clock that moves backwards fails closed while it is behind a saved attempt timestamp.
  Changing or deleting app storage can defeat client controls. These limits are
  cooperative safeguards, not enforcement against modified clients.

The existing gateway's per-radio/target quota runs *after* RF. It is not a global
poll lease. Before wider participation, add server-issued pre-RF leases/budgets
shared by app and Collector, with explicit expiry, outage behavior and no
fail-open flooding. A lease still cannot prevent an independently modified radio
from transmitting. Local congestion checks remain necessary with leases.

## Signed HTTPS contract (experimental v1)

All endpoints are relative to `<selected-instance>/api/v1/node-telemetry`.
HTTPS is required and redirects are rejected. Normal observer MQTT credentials,
MeshMapper keys and operator API keys must never be embedded in the app.

1. `POST /challenge` with `radioKey` and `collectorKey`, both lowercase 64-hex
   public keys. The client key is generated locally and its seed is held in
   platform secure storage.
2. Response: `challenge`, `message`, `instance`. Validate the bounded token's
   challenge kind, exact selected instance and keys, and short future expiry.
   Sign only `BEACON-TELEMETRY-ENROLL-V1\n` followed by that exact token. Both
   the radio and app sign. Verify the radio's signature locally as well.
3. `POST /enroll` with `challenge`, `radioSignature`, `collectorSignature`.
   Response includes `authorization`, `expires` (epoch seconds) and `instance`.
   Session expiry or 401 requires enrollment again, not another repeater poll.
4. `POST /reports` with `authorization`, `payload` (base64 of exact JSON bytes)
   and `signature` (hex Ed25519 signature over those bytes).

Payload shape:

```json
{
  "schema": 1,
  "sampleId": "a stable UUID for this observation",
  "receivedAt": 1792454400000,
  "instance": "https://example.org/beacon",
  "collectorKey": "full 32-byte client public key in hex",
  "radioKey": "full companion public key in hex",
  "nodeKey": "full selected repeater public key in hex",
  "source": "companion-poll",
  "intervalHours": 6,
  "values": {"batteryMv": 4000, "uptimeSeconds": 7200},
  "sensors": [{"channel": 2, "kind": "temperature", "value": 10.0, "unit": "C"}],
  "route": {"login": "flood", "request": "direct", "learned": true}
}
```

The server validates full identities, schema, signature, session/instance binding,
allowed types, finite numbers, units/ranges, quotas and freshness. Current limits:
8,192 payload bytes, 12,000 envelope bytes, 32 sensor values, 24 hours old at most,
two minutes future skew. A duplicate `(collectorKey, sampleId)` is idempotent.
Only an `accepted: true` response acknowledges persistence. A 429/503 delays
delivery and RF; retries reuse identical sample bytes and ID. The outbox is bounded
to 12 reports, expires reports after 24 hours and never sends them to a different
instance or for a different radio. A missing environment response can retain the
valid status sample; it is never fabricated as zero sensor data.

Key control proves a participant can use those keys. It does not attest genuine
hardware, repeater permission provenance, sensor calibration or measurement truth.
Display these as attributed community reports, separate from observer telemetry.
No passwords, private keys, messages, raw packets, channel secrets or GPS enter
the report. TCP companion traffic itself is unencrypted: use a trusted LAN.

## MQTT and backend adoption

The separate intake already accepts the same signed envelope on
`beacon/telemetry/v1/<collectorKey>`. Reuse validation/storage and idempotence,
not the ordinary observer packet topic. Publishing directly from mobile needs:

1. Short-lived MQTT credentials obtained after the same enrollment, broker TLS,
   publish-only ACL for the client's telemetry topic and a scoped receipt topic.
2. A correlated application receipt issued only after validation and persistence.
   A publisher PUBACK is not proof of intake acceptance.
3. Reconnect/backoff, credential rotation/revocation and outbox parity with HTTPS.
4. Pre-RF leases if polling is coordinated across users, separate from upload quota.

These APIs do not exist in the current gateway. Adding an MQTT dependency now
would create an unusable or weaker delivery path; HTTPS is the implemented path.
The operator still needs to expose the intake behind the Beacon instance, publish
a capability/version contract (ideally `/info`), configure limits, and expose
collected-node history to Atlas. Existing preview Atlas cards can render the
gateway's node measurements. Upstream production Atlas/read endpoints and mobile
charts require a separate coordinated backend/web change; this app PR cannot
make them appear on an unmodified deployment.

Keep the Collector as the alternate headless USB/TCP/Pi client. Both clients
should eventually share enrollment, report schema, pre-RF leases, receipts and
retention. Do not run them on the same companion concurrently. Deprecate Collector
only after phone transport/lifecycle qualification and equivalent operator support,
not merely because this draft compiles.

## Qualification and release gates

Automated tests use a local TCP companion simulator, a fake BLE driver and mock HTTPS intake. They
exercise real framing and signing, early responses, exact tag matching, contact
widths, channel-2 decoding, cooldown persistence, clock rollback, missing intake,
network retry idempotence and report privacy. They do not establish RF performance
or physical iOS/Android behavior.

Before removing draft status:

- Exercise real BLE and TCP companions and supported firmware on Android and iOS, including
  permission prompts, screen lock, app kill, socket loss, storage failure, radio
  reboot, guest/admin denial, missing sensors and future/replayed challenges.
- Confirm firmware supports on-device signing and local stats; unsupported versions
  must stay fail-closed. Confirm exclusive companion ownership and no extra RF.
- Test the actual HTTPS gateway and Atlas history without fabricated production data;
  verify channel 2, report deduplication, chart gaps, retention and revocation.
- Complete translations for operational status/error messages and a mobile usability pass.
- Review the iOS export-compliance declaration before distributing client-side
  signing. This PR preserves the existing declaration; it does not make a legal
  classification or authorize App Store/TestFlight distribution.
- Audit secure-storage backup/restore behavior. Android auto-backup is disabled;
  decryption errors must not reset Android's saved identity or polling limits.
  iOS uses an unlocked, device-only keychain item and requires signing with the included entitlement.
- Agree on multi-client leases and controlled cohort limits before broad rollout.

BLE uses Nordic UART service 6e400001 (RX 6e400002, TX 6e400003). Commands
are complete characteristic writes with acknowledgement, never arbitrary chunks.
The connection sequence matches MeshMapper: connect with automatic MTU negotiation
disabled, request 512 after connecting on Android, read the negotiated MTU on iOS,
discover services, await notification enablement, then run the protocol-4 DEVICE_QUERY
plus APP_START handshake. Contact frames require negotiated MTU of at least 151.
We use notification-only `onValueReceived` to avoid replaying cached responses.
Android 12+ requests scan/connect; older Android requests foreground location for
scanning, but the app never collects coordinates. iOS requests Bluetooth permission.
No background BLE modes or automatic RF reconnects are enabled.

### MeshMapper compatibility review

The user requested parity with MeshMapper. Current sources inspected:

- [MeshMapper Flutter mobile BLE](https://github.com/MeshMapper/MeshMapper_Flutter_App/blob/f0f04f584444c9c4fb6f346f12c614f8a3649b54/lib/services/bluetooth/mobile_bluetooth.dart),
  [retry policy](https://github.com/MeshMapper/MeshMapper_Flutter_App/blob/f0f04f584444c9c4fb6f346f12c614f8a3649b54/lib/services/bluetooth/ble_connect_retry_policy.dart),
  [common handshake](https://github.com/MeshMapper/MeshMapper_Flutter_App/blob/f0f04f584444c9c4fb6f346f12c614f8a3649b54/lib/services/meshcore/connection.dart),
  [TCP](https://github.com/MeshMapper/MeshMapper_Flutter_App/blob/f0f04f584444c9c4fb6f346f12c614f8a3649b54/lib/services/transport/tcp_service.dart)
  and [stream framing](https://github.com/MeshMapper/MeshMapper_Flutter_App/blob/f0f04f584444c9c4fb6f346f12c614f8a3649b54/lib/services/transport/stream_frame_codec.dart).
- [MeshMapper WebClient connection workflow](https://github.com/MeshMapper/MeshMapper_WebClient/blob/d30398e93e77ccb949700de90adfda94158c00e4/docs/CONNECTION_WORKFLOW.md)
  and [Web BLE](https://github.com/MeshMapper/MeshMapper_WebClient/blob/d30398e93e77ccb949700de90adfda94158c00e4/content/mc/connection/web_ble_connection.js).

MeshMapper locks Flutter Blue Plus at 1.36.8. This draft pins the same version
(BSD-3-Clause) rather than silently moving to the newer major release. MeshMapper's
connection sequencing and known GATT-busy handling are adapted with attribution;
its MIT notice is included in `docs/licenses/meshmapper-MIT.txt`. Both TCP clients
use port 5000, TCP_NODELAY, a ten-second connection timeout and `<`/`>` length
framing with junk resynchronization. BLE has no TCP headers. The shared protocol
client serializes writes and registers reply listeners before sending.

Intentional telemetry-specific differences: no wardriving location disclosure or
GPS collection, no radio-power changes, no radio key export, no channel scan/wardrive
auth, no automatic reconnect that could trigger RF, and no on-the-wire retry after
an uncertain send. Stale iOS bonds fail without repeated attempts or silently
removing a user's bond. Notifications use `onValueReceived`, not a replaying
last-value stream. MTU too small for a complete contact fails before polling.
These preserve transport compatibility while keeping the telemetry feature scoped.

Browser BLE, USB from phones, background services and observer-firmware collection
are separate work. Real iOS/Android qualification is still required.
