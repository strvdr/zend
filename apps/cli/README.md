# zend

Encrypted file transfer over TCP. Built from scratch in Zig — no libraries for networking, encryption, or compression.

## What it does

Send a file from one machine to another over an encrypted connection. The receiver listens, the sender connects, and the file is transferred with compression and authenticated encryption. That's it.

```
Sender                              Receiver
  │                                     │
  │<-- X25519 key exchange ------------>│
  │                                     │
  │-- encrypted file chunks ----------->│
  │                                     │
  │<-- acknowledgment ------------------│
```

## Quick start

```bash
zig build
```

```bash
sudo ln -s $(pwd)/zig-out/bin/zend /usr/local/bin/zend
```

On the receiving machine:

```bash
zend
# Listening on port 9000...
```

On the sending machine:

```bash
zend ./myfile.tar 192.168.1.42
```

## Usage

The CLI infers whether you're sending or receiving. If you pass a file, you're sending. Otherwise, you're listening.

```bash
# Receive
zend                                  # listen on :9000, save to cwd
zend :4567                            # listen on custom port
zend --out /tmp/received              # save files to a specific directory

# Send
zend ./photo.jpg 192.168.1.42        # send to host, default port 9000
zend ./photo.jpg 192.168.1.42:4567   # send to host on custom port
zend ./photo.jpg                     # send to localhost (for testing)

# Explicit mode (also works)
zend send --host 192.168.1.42 --port 9000 ./photo.jpg
zend recv --port 9000 --out /tmp
```

## How it works

Everything is implemented by hand as a learning exercise:

- **X25519** key exchange — both sides generate ephemeral keypairs and derive a shared secret without ever transmitting it
- **ChaCha20-Poly1305** authenticated encryption — every packet is encrypted and authenticated with a unique nonce. Tampered packets are rejected immediately
- **Huffman compression** — file chunks are compressed before encryption, with adaptive fallback (skips compression if it would make the data larger)
- **Length-prefixed framing** — TCP is a byte stream, so each message is preceded by a 4-byte length header to recover message boundaries
- **Monotonic nonce counter** — each encrypted packet gets a unique nonce derived from a random connection ID and an incrementing counter

File data is sent in 64 KiB chunks. Each chunk is independently compressed, encrypted, framed, and sent over TCP.

## Project structure

```
src/
├── main.zig              CLI entry point
├── send.zig              Sender orchestration
├── recv.zig              Receiver orchestration
├── net/
│   ├── tcp.zig           TCP connect/listen/accept
│   └── framing.zig       Length-prefixed message framing
├── crypto/
│   ├── x25519.zig        Diffie-Hellman key exchange
│   ├── chacha20.zig      ChaCha20 stream cipher
│   ├── poly1305.zig      Poly1305 MAC
│   └── aead.zig          ChaCha20-Poly1305 AEAD
├── compress/
│   ├── huffman.zig       Huffman encoding/decoding
│   └── bitwriter.zig     Bit-level writer
└── protocol/
    ├── handshake.zig     Key exchange state machine
    ├── transfer.zig      Chunked file transfer
    └── message.zig       Packet types and serialization
```

## Tests

Each module has inline tests validated against RFC test vectors where applicable (RFC 7748 for X25519, RFC 8439 for ChaCha20-Poly1305).

```bash
zig build test
```

## Requirements

Zig 0.15.2

## Limitations

- Single file transfers only (no directories yet)
- One transfer at a time
- No resume on interrupted transfers
- Both sides must be reachable over TCP (no NAT traversal)
