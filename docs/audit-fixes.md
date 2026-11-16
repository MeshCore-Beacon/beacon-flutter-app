# Development audit fixes — November 2026

This candidate is based on upstream dev `ec35a4d`. It uses upstream's native
telemetry views and server coordination. It does not contain the earlier BLE/Wi-Fi
collector, background collection service or independent intake protocol.

[Full audit and roadmap](https://github.com/MeshCore-Beacon/beacon-docs/blob/codex/audit-docs-20261116/docs/audit-20261116.md)

HTTP timeouts now abort the individual request, including a stalled streamed body,
instead of merely stopping the caller's wait. Other requests on the same client
remain usable. Public reads retain their byte limit; account responses now have a
1 MiB limit and share the same 25-second whole-exchange deadline. Credentials,
session generation checks and error handling remain separate from public caches.
Changing screens also prevents a superseded request from starting a retry.

Tests exercise a real loopback HTTP server, oversized bodies, stale-screen reads
and the existing account/session cases. An APK build is not physical BLE, RF,
background, push-delivery or iOS acceptance. No phone installation accompanies the
audit unless separately recorded.
