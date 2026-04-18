# zend

End-to-end encrypted file transfer built with Zig.

`zend` is a file sharing system designed around a simple idea: the relay should be able to store and serve files without being able to read them. Files are encrypted on the client, uploaded as ciphertext, and retrieved through a single download link.

## Why

Most file sharing tools make tradeoffs between convenience, privacy, and control. `zend` aims to keep the UX simple while preserving strong separation between:

- the **client**, which holds the key
- the **relay**, which stores ciphertext
- the **download link**, which points to the file without exposing plaintext to the server

The result is a file transfer flow that feels lightweight, but keeps the relay untrusted with respect to file contents.

## Features

- End-to-end encrypted file transfer
- Zig relay/server
- Zig protocol implementation
- Zig → WASM client-side crypto for browser upload/download
- Streamed uploads using append/finalize flow
- Download-once semantics
- Expiring blobs and abandoned upload cleanup
- Relay-side rate limiting
- Simple HTTP API

## How it works

At a high level, `zend` works like this:

1. The sender selects a file.
2. The client encrypts the file before upload.
3. Ciphertext is uploaded to the relay in framed chunks.
4. The relay stores the encrypted blob and returns an ID/token pair for the upload session.
5. A download link is shared with the recipient.
6. The recipient downloads the ciphertext and decrypts it client-side using the key embedded in or distributed alongside the link.
7. After download, the blob can be deleted or consumed depending on policy.

The relay handles storage and transfer, but it does not need the decryption key.

## Architecture

The project is split into a few major pieces:

### Relay
The relay is written in Zig and exposes HTTP endpoints for:

- `POST /upload/start`
- `POST /upload/append/{id}?token=...&index=...`
- `POST /upload/finish/{id}?token=...`
- `GET /download/{id}`
- `DELETE /delete/{id}?token=...`

It is responsible for:

- managing upload sessions
- writing encrypted blobs to disk
- serving downloads
- deleting consumed or expired data managing upload sessions
- writing encrypted blobs to disk
- serving downloads
- deleting consumed or expired data
- rate limiting and basic abuse resistance
- cleanup of stale temporary uploads

- rate limiting and basic abuse resistance
- cleanup of stale temporary uploads

### Protocol
The protocol layer defines the framed packet format used for metadata, chunks, and completion markers. This keeps upload and download behavior structured and makes incremental parsing possible.

### Crypto
Core crypto is implemented in Zig and compiled to WebAssembly for browser use. The current implementation includes components such as:

- ChaCha20
- Poly1305
- AEAD construction

This allows the browser to encrypt before upload and decrypt after download without handing the relay plaintext.

### Web client
The web frontend provides upload and download flows on top of the relay and WASM crypto layer.

## Security model

`zend` is designed so that the relay stores encrypted data rather than plaintext.

That means:

- the relay can see that a file exists
- the relay can see blob sizes, timing, and request metadata
- the relay can store and serve ciphertext
- the relay should **not** have the key needed to decrypt the file contents

This is not the same as hiding all metadata from the relay, but it does reduce trust placed in the storage server.

## Relay behavior

The relay currently supports:

- upload sessions with per-upload tokens
- bounded upload sizes
- append body size limits
- configurable TTLs
- cleanup of incomplete uploads
- per-IP rate limiting
- single download / consume-on-read style flows

Example runtime configuration includes values such as:

- host / port
- blob directory
- max upload bytes
- max append size
- TTL for finished blobs
- TTL for incomplete uploads
- allowed web origins
- per-route rate limits

## Configuration

The relay is configured through environment variables.

### Core settings

- `ZEND_RELAY_HOST`
- `ZEND_RELAY_PORT`
- `ZEND_BLOB_DIR`
- `ZEND_MAX_UPLOAD_BYTES`
- `ZEND_MAX_APPEND_BODY_BYTES`
- `ZEND_TTL_SECONDS`
- `ZEND_INCOMPLETE_TTL_SECONDS`
- `ZEND_ALLOWED_ORIGINS`

### Rate limiting

- `ZEND_RATE_LIMIT_WINDOW_SECONDS`
- `ZEND_RATE_LIMIT_MAX_REQUESTS_PER_IP`
- `ZEND_RATE_LIMIT_MAX_UPLOAD_STARTS_PER_IP`
- `ZEND_RATE_LIMIT_MAX_UPLOAD_APPENDS_PER_IP`
- `ZEND_RATE_LIMIT_MAX_UPLOAD_FINISHES_PER_IP`
- `ZEND_RATE_LIMIT_MAX_DOWNLOADS_PER_IP`

## Development status

`zend` is under active development.

Current areas of focus include:

- polish of upload/download UX
- production hardening
- clearer error handling
- relay abuse resistance
- better deployment ergonomics
- optional self-hosting improvements

## Goals

The long-term goal is to make secure file transfer feel simple:

- upload a file
- share a link
- keep the relay out of the trust boundary for file contents

## Non-goals

At least for now, `zend` is not trying to be:

- a general-purpose cloud drive
- a collaborative document platform
- a full anonymity system
- a replacement for object storage infrastructure

## Running locally

Local setup depends on how you’ve structured the repo, but the general flow is:

1. Build the Zig relay
2. Start the relay with a local blob directory
3. Build the WASM module
4. Serve the web frontend
5. Upload a file and test retrieval through the generated link

You will likely also want to configure:

- allowed origins for local frontend development
- max upload sizes for testing
- shorter TTLs while iterating

## Project structure

The codebase currently includes pieces for:

- relay routing and HTTP helpers
- upload/download/delete handlers
- storage path management
- runtime configuration
- reaper/cleanup loop
- rate limiting
- blob framing / packet types
- crypto primitives
- WASM/browser integration

## Roadmap

- [x] Client-side encryption
- [x] Relay upload/download endpoints
- [x] Streaming append flow
- [x] Cleanup for stale uploads
- [x] Rate limiting
- [ ] More complete self-hosting docs
- [ ] Better deployment docs
- [ ] Multi-user / account-backed relay support
- [ ] Quotas and billing-aware relay policies
- [ ] Improved product polish

## Contributing

The project is still moving quickly, so APIs and internals may change. Issues, feedback, and design discussion are welcome.

## License

TBD
