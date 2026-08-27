# Whoops

Whoops is a macOS menu bar app that pauses plaintext HTTP connections to
`localhost`, `127.0.0.1`, and `::1`, then lets you pass them through or route
them to a configured HTTP/HTTPS origin.

## Install

1. Download the ZIP from the [latest release](https://github.com/daleal/whoops/releases).
2. Extract it and move `Whoops.app` to `Applications`.
3. Remove the quarantine attribute (the app is not notarized, so macOS blocks
   it otherwise):

```sh
xattr -d com.apple.quarantine /Applications/Whoops.app
```

## Build

Requires macOS 13 or newer and the Swift command-line tools.

```sh
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open dist/Whoops.app
```

Run parser and loopback proxy tests with `./scripts/test.sh`.

## Release

Run the `release` workflow from the Actions tab on the `main` branch and choose
a patch, minor, or major version bump. After tests and the release build pass,
the workflow updates the app version and publishes a tagged GitHub Release with
the application ZIP and its SHA-256 checksum.

Enabling interception asks for administrator approval. Whoops installs only a
runtime `pf` anchor and one loopback alias. A privileged watchdog removes both
when interception is disabled or the app exits.

## Behavior

- Clients remain connected with no response while a request awaits a choice.
- Passthrough reconnects to the original local port.
- Redirect keeps the request method, path, query, headers, and body, while
  changing the upstream host and optional base path.
- `Same :port` uses the intercepted local port.
- `Default :port` uses port 80 for HTTP or 443 for HTTPS.
- TLS and non-HTTP localhost protocols cannot be routed. Because `pf` works
  below HTTP, they are also paused while interception is armed; disarm Whoops
  before using local databases or other raw TCP services.
- Interception covers destination ports below the system ephemeral range
  (typically 1-49151). Redirecting ephemeral ports would capture the proxy's
  own reply packets and wedge every connection, so servers listening on
  ephemeral ports are intentionally not intercepted.
- A decision applies to one HTTP connection. Most clients open a fresh
  connection because Whoops asks the upstream to close after its response;
  already-pipelined requests follow the same decision.
