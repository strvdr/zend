# zend web

The web app is the browser client for the relay-backed Zend flow.

It lets a sender encrypt a file in the browser, upload the ciphertext to the relay, and share a link whose fragment contains the decryption key. The recipient later opens that link, downloads the ciphertext, decrypts it client-side, and saves the recovered file.

## What it includes

- landing page at `/`
- upload flow at `/upload`
- download flow at `/d/[id]`
- Zig/WASM-backed encryption and decryption in `src/lib/wasm`

The relay-backed browser flow is the primary product surface in the current repository.

## Local development

From this directory:

```bash
pnpm install
NEXT_PUBLIC_RELAY_URL=http://localhost:8080 \
NEXT_PUBLIC_APP_URL=http://localhost:3000 \
pnpm dev
```

Then open `http://localhost:3000`.

## Environment

- `NEXT_PUBLIC_RELAY_URL`
  Base URL for relay API requests
- `NEXT_PUBLIC_APP_URL`
  Base URL used when generating share links

## WASM dependency

The web app expects `public/zend_wasm.wasm` to exist.

From the repo root, build and copy it with:

```bash
./build_wasm.sh
```

## Checks

From this directory:

```bash
pnpm lint
pnpm build
```

## Notes

- The current UI caps file size at 100 MB even though the relay default is higher.
- The relay only receives ciphertext. The decryption key stays in the URL fragment and is not sent in HTTP requests.
