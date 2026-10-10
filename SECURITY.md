# Security Policy

## Reporting a Vulnerability

Please do not report security vulnerabilities through public GitHub issues.

Instead, report it privately through GitHub:
[open a security advisory](https://github.com/MeshCore-Beacon/beacon-flutter-app/security/advisories/new).
Include as much detail as possible: the nature of the issue, steps to
reproduce, and any potential impact.

If you cannot use GitHub, contact the maintainers via the MeshCore Canada
Discord server: [MeshCore Canada Discord](https://discord.gg/Gz3KvJx2hf); reach
out to **dedskelly** directly.

We will acknowledge receipt within 48 hours and aim to provide a fix or
mitigation within 14 days depending on severity.

Once a fix is released we will publish a security advisory on the repository.

## Scope

beacon-flutter-app is a native iOS and Android client that reads from the
beacon-server REST and WebSocket API. Relevant findings include issues in the
app itself (e.g. insecure local storage, unsafe handling of server data,
insecure transport, excessive permissions), dependency vulnerabilities, and the
build/release pipeline. Vulnerabilities in the backend API itself belong in the
[beacon-server](https://github.com/MeshCore-Beacon/beacon-server) repository.
