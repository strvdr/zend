# zend cli

The CLI supports two different transfer modes:

- relay-backed upload and download
- direct peer-to-peer transfer over TCP

That makes it both a practical command-line client for the main Zend share flow and a lower-level direct transfer tool.

## Modes

### Relay-backed

```bash
zend ./report.pdf
zend 'https://www.zend.foo/d/<id>#<key>'
```

- `zend <file>` encrypts locally, uploads to the relay, and prints a share URL
- `zend <url>` downloads from the relay and decrypts locally

### Direct peer-to-peer

```bash
zend
zend :4567
zend ./report.pdf 192.168.1.42
zend ./report.pdf 192.168.1.42:4567
```

- `zend` or `zend :port` listens for an incoming direct transfer
- `zend <file> <peer>` sends directly to another CLI instance

Legacy explicit commands still work:

```bash
zend send --host 192.168.1.42 --port 9000 ./report.pdf
zend recv --port 9000 --out /tmp
```

## Local build

From this directory:

```bash
zig build
sudo ln -sf "$(pwd)/zig-out/bin/zend" /usr/local/bin/zend
zend --help
```

## Relay configuration

The CLI defaults to the production relay URLs, but you can override them at runtime:

- `ZEND_CLI_RELAY_URL`
- `ZEND_CLI_APP_URL`

That is the easiest way to point the CLI at a local or self-hosted relay.

## How it works

### Relay-backed flow

- generate a random 32-byte file key locally
- encrypt and frame the file using the shared Zig blob format
- upload ciphertext to the relay
- print a share URL whose fragment contains the decryption key
- on download, fetch ciphertext, decrypt locally, and verify integrity

### Direct peer-to-peer flow

- connect sender and receiver over TCP
- perform an X25519 handshake
- transfer framed, encrypted file chunks directly

## Shared implementation

The CLI reuses the same shared Zig crypto, compression, and blob-format code used elsewhere in the repo. That means the relay-aware CLI and the browser client speak the same encrypted blob format.

## Tests

From this directory:

```bash
zig build test
```

The test suite includes RFC/vector coverage for cryptographic primitives and protocol-level checks for the direct transfer path.

## Current limits

- direct mode has no NAT traversal
- interrupted transfers do not resume
- relay mode depends on the configured relay URL
