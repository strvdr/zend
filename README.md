# zend

`zend` is an encrypted file transfer project built mostly in Zig.

Today the repo contains two related transfer paths:

- a relay-backed share flow, where files are encrypted client-side, uploaded as ciphertext, and shared with a link
- a direct peer-to-peer CLI flow, where one machine sends a file straight to another over TCP

The relay-backed path is the center of the current repo: a Zig relay, a Next.js web app, and a Zig/WASM blob format implementation all exist and work together. The CLI also supports that relay flow, and still includes the older direct-transfer mode.

## What the relay flow looks like

1. A sender picks a file in the web app or CLI.
2. The client generates a random 32-byte key locally.
3. The file is framed, optionally compressed per chunk, encrypted with ChaCha20-Poly1305, and tagged with a whole-file integrity record.
4. Ciphertext is uploaded to the relay in ordered append requests.
5. The sender shares a link like `/d/{id}#{key}`.
6. The relay only sees the blob ID and ciphertext. The decryption key stays in the URL fragment, so it is not sent in HTTP requests.
7. The recipient downloads the blob, decrypts it client-side, verifies integrity, and saves the recovered file.
8. After a successful download, the relay deletes the stored blob.

The relay also removes expired finished blobs and abandoned uploads on a background reaper loop.

## Repo layout

```text
apps/
  cli/       Zig CLI for relay uploads/downloads and direct peer-to-peer sends
  relay/     Zig HTTP relay that stores encrypted blobs on disk
  web/       Next.js web app for upload and download flows
packages/
  crypto/    ChaCha20, Poly1305, AEAD primitives
  protocol/  blob framing, packet types, encrypt/decrypt sessions
  compress/  Huffman encoder/decoder used opportunistically per chunk
  wasm/      Zig -> WebAssembly build used by the web client
docs/
  relay-docs/ relay design notes
```

## Components

### Relay

The relay is a small Zig HTTP server. It stores ciphertext on disk and never needs the decryption key.

Current endpoints:

- `POST /upload/start`
- `POST /upload/append/{id}?token=...&index=...`
- `POST /upload/finish/{id}?token=...`
- `GET /download/{id}`
- `DELETE /delete/{id}?token=...`

Current behavior:

- uploads are strictly ordered by chunk index
- upload sessions use per-upload tokens
- completed blobs are deleted after the first successful download
- completed blobs also expire by TTL
- incomplete uploads expire on a separate TTL
- simple per-IP rate limiting is applied per route group
- CORS responses are controlled with `ZEND_ALLOWED_ORIGINS`

### Web app

The web frontend lives in `apps/web` and is built with Next.js.

It currently provides:

- a landing page that explains the encrypted-link model
- an upload page at `/upload`
- a download page at `/d/[id]`
- browser-side encryption and decryption through the WASM module in `apps/web/public/zend_wasm.wasm`

The web upload UI currently caps files at 100 MB even though the relay default is higher.

### CLI

The CLI in `apps/cli` supports both relay-backed and direct-transfer usage:

- `zend ./file` uploads to the relay and prints a share URL
- `zend https://...` downloads from the relay and decrypts locally
- `zend` or `zend :4567` listens for a direct incoming TCP transfer
- `zend ./file 192.168.1.42[:port]` sends directly to another CLI instance

That means the CLI is not just a peer-to-peer toy anymore. In the current codebase it also speaks the relay upload/download flow.

## Crypto and format notes

The shared Zig protocol code is used by the relay-aware CLI and the WASM build.

The current blob format includes:

- encrypted metadata with the original filename and total plaintext size
- encrypted chunk packets
- opportunistic Huffman compression on a chunk-by-chunk basis
- an integrity packet containing the final plaintext size and SHA-256 hash
- a final DONE packet

For the relay-backed flow there is no interactive key exchange. The key is generated client-side and passed out-of-band via the URL fragment.

For the direct CLI peer-to-peer flow there is a separate X25519 handshake and encrypted TCP transport.

## Local development

### Requirements

- Zig `0.15.2`
- Node.js
- pnpm

## 1. Build and run the relay

From `apps/relay`:

```bash
zig build
./zig-out/bin/zend-relay
```

Useful relay environment variables:

```bash
ZEND_RELAY_PORT=8080
ZEND_BLOB_DIR=blobs
ZEND_MAX_UPLOAD_BYTES=536870912
ZEND_MAX_APPEND_BODY_BYTES=1048576
ZEND_TTL_SECONDS=86400
ZEND_INCOMPLETE_TTL_SECONDS=3600
ZEND_ALLOWED_ORIGINS=http://localhost:3000
ZEND_RATE_LIMIT_WINDOW_SECONDS=60
ZEND_RATE_LIMIT_MAX_REQUESTS_PER_IP=240
ZEND_RATE_LIMIT_MAX_UPLOAD_STARTS_PER_IP=20
ZEND_RATE_LIMIT_MAX_UPLOAD_APPENDS_PER_IP=1200
ZEND_RATE_LIMIT_MAX_UPLOAD_FINISHES_PER_IP=40
ZEND_RATE_LIMIT_MAX_DOWNLOADS_PER_IP=120
```

Defaults in the current relay code:

- port `8080`
- blob dir `blobs`
- max upload size `512 MiB`
- max append body size `1 MiB`
- finished blob TTL `24h`
- incomplete upload TTL `1h`

Note: the runtime config includes `ZEND_RELAY_HOST`, but the current relay entrypoint binds to `0.0.0.0` in code.

## 2. Build the WASM module

From the repo root:

```bash
./build_wasm.sh
```

That builds `packages/wasm` and copies the output into `apps/web/public/zend_wasm.wasm`.

## 3. Run the web app

From `apps/web`:

```bash
pnpm install
NEXT_PUBLIC_RELAY_URL=http://localhost:8080 \
NEXT_PUBLIC_APP_URL=http://localhost:3000 \
pnpm dev
```

Then open `http://localhost:3000`.

The web app depends on:

- `NEXT_PUBLIC_RELAY_URL` for relay API requests
- `NEXT_PUBLIC_APP_URL` for the share links it generates

## 4. Build and use the CLI

From `apps/cli`:

```bash
zig build
sudo ln -sf "$(pwd)/zig-out/bin/zend" /usr/local/bin/zend
zend --help
```

Examples:

```bash
# Upload to relay and print a share URL
zend ./report.pdf

# Download from relay
zend 'https://www.zend.foo/d/<id>#<key>'

# Receive a direct peer-to-peer transfer
zend :9000

# Send directly to another machine
zend ./report.pdf 192.168.1.42:9000
```

The relay-facing CLI currently uses baked-in production constants in `apps/cli/src/relay/relay.zig` for:

- `https://relay.zend.foo`
- `https://www.zend.foo`

So for local relay testing, the web app is the easier path unless you also change those CLI constants.

## Convenience scripts

The repo includes two helper scripts at the top level:

- `./build_wasm.sh` builds the WASM artifact and copies it into the web app
- `./build_relay.sh` builds the relay and deploys it to `/opt/zend-relay` via `systemctl`

`build_relay.sh` is clearly meant for the current production host, not for generic local development.

## Current state of the project

What is implemented today:
- relay-backed encrypted uploads and downloads
- browser upload/download flows using Zig/WASM
- single-use relay downloads with TTL-based cleanup
- relay-side rate limiting
- a Zig CLI that can upload to the relay, download from the relay, or transfer directly over TCP
- shared crypto, framing, compression, and integrity code used across targets

## A few implementation caveats

- The relay stores ciphertext only, but it still sees blob size, timing, IPs, and request metadata.
- The current download route reads the full stored blob into memory before responding, even though the client decrypt path is incremental.
- The web app and CLI are not perfectly symmetrical in configuration yet; the web app is environment-driven, while the CLI relay URLs are hard-coded.
