import { loadWasm } from "./loader";

type WasmExports = {
  memory: WebAssembly.Memory;
  alloc_input: (len: number) => number;
  free_input: (ptr: number, len: number) => void;

  clear_result: () => void;
  clear_sessions: () => void;

  error_ptr: () => number;
  error_len: () => number;

  result_ptr: () => number;
  result_len: () => number;
  result_filename_ptr: () => number;
  result_filename_len: () => number;

  encrypt: (
    input_ptr: number,
    input_len: number,
    filename_ptr: number,
    filename_len: number,
    key_ptr: number
  ) => number;

  decrypt: (
    input_ptr: number,
    input_len: number,
    key_ptr: number
  ) => number;

  begin_encrypt: (
    filename_ptr: number,
    filename_len: number,
    total_size: number,
    key_ptr: number
  ) => number;

  encrypt_chunk: (input_ptr: number, input_len: number) => number;
  finish_encrypt: () => number;

  begin_decrypt: (key_ptr: number) => number;
  push_blob_bytes: (input_ptr: number, input_len: number) => number;
  decrypt_done: () => number;
};

function getExports(instance: WebAssembly.Instance): WasmExports {
  return instance.exports as unknown as WasmExports;
}

function writeBytes(memory: WebAssembly.Memory, ptr: number, data: Uint8Array) {
  new Uint8Array(memory.buffer, ptr, data.length).set(data);
}

function readBytes(memory: WebAssembly.Memory, ptr: number, len: number) {
  return new Uint8Array(memory.buffer, ptr, len).slice();
}

function utf8(input: string) {
  return new TextEncoder().encode(input);
}

function readError(exports: WasmExports) {
  const ptr = exports.error_ptr();
  const len = exports.error_len();
  return new TextDecoder().decode(readBytes(exports.memory, ptr, len));
}

function assertStatus(exports: WasmExports, status: number) {
  if (status === 0) return;
  const err = readError(exports);
  throw new Error(err || `WASM operation failed with status ${status}`);
}

function takeResultBytes(exports: WasmExports) {
  const ptr = exports.result_ptr();
  const len = exports.result_len();
  return readBytes(exports.memory, ptr, len);
}

function takeResultFilename(exports: WasmExports) {
  const ptr = exports.result_filename_ptr();
  const len = exports.result_filename_len();
  return new TextDecoder().decode(readBytes(exports.memory, ptr, len));
}

function allocAndWrite(exports: WasmExports, bytes: Uint8Array) {
  const ptr = exports.alloc_input(bytes.length);
  if (!ptr) {
    throw new Error("alloc_input failed");
  }
  writeBytes(exports.memory, ptr, bytes);
  return {
    ptr,
    len: bytes.length,
    free() {
      exports.free_input(ptr, bytes.length);
    },
  };
}

function keyToB64(key: Uint8Array) {
  let s = "";
  for (let i = 0; i < key.length; i++) s += String.fromCharCode(key[i]);
  return btoa(s);
}

function keyFromB64(keyB64: string) {
  const raw = atob(keyB64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

export async function encryptFile(file: File) {
  const wasm = await loadWasm();
  const exports = getExports(wasm);

  exports.clear_sessions();
  exports.clear_result();

  const fileBytes = new Uint8Array(await file.arrayBuffer());
  const filenameBytes = utf8(file.name);
  const key = crypto.getRandomValues(new Uint8Array(32));

  const input = allocAndWrite(exports, fileBytes);
  const name = allocAndWrite(exports, filenameBytes);
  const keyBuf = allocAndWrite(exports, key);

  try {
    const status = exports.encrypt(
      input.ptr,
      input.len,
      name.ptr,
      name.len,
      keyBuf.ptr
    );

    assertStatus(exports, status);

    const blob = takeResultBytes(exports);
    exports.clear_result();

    return {
      blob,
      keyB64: keyToB64(key),
    };
  } finally {
    input.free();
    name.free();
    keyBuf.free();
  }
}

export async function encryptFileStream(file: File): Promise<{
  body: ReadableStream<Uint8Array>;
  keyB64: string;
}> {
  const wasm = await loadWasm();
  const exports = getExports(wasm);

  exports.clear_sessions();
  exports.clear_result();

  const filenameBytes = utf8(file.name);
  const key = crypto.getRandomValues(new Uint8Array(32));

  const name = allocAndWrite(exports, filenameBytes);
  const keyBuf = allocAndWrite(exports, key);

  const beginStatus = exports.begin_encrypt(
    name.ptr,
    name.len,
    file.size,
    keyBuf.ptr
  );

  name.free();
  keyBuf.free();

  assertStatus(exports, beginStatus);

  const body = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        const first = takeResultBytes(exports);
        if (first.length > 0) controller.enqueue(first);
        exports.clear_result();

        const reader = file.stream().getReader();

        while (true) {
          const { value, done } = await reader.read();
          if (done) break;

          const chunk = value instanceof Uint8Array ? value : new Uint8Array(value);
          const input = allocAndWrite(exports, chunk);

          try {
            const status = exports.encrypt_chunk(input.ptr, input.len);
            assertStatus(exports, status);
          } finally {
            input.free();
          }

          const out = takeResultBytes(exports);
          if (out.length > 0) controller.enqueue(out);
          exports.clear_result();
        }

        const finishStatus = exports.finish_encrypt();
        assertStatus(exports, finishStatus);

        const finalChunk = takeResultBytes(exports);
        if (finalChunk.length > 0) controller.enqueue(finalChunk);
        exports.clear_result();

        controller.close();
      } catch (err) {
        controller.error(err);
      } finally {
        exports.clear_sessions();
        exports.clear_result();
      }
    },

    cancel() {
      exports.clear_sessions();
      exports.clear_result();
    },
  });

  return {
    body,
    keyB64: keyToB64(key),
  };
}

export async function decryptBlob(blob: ArrayBuffer, keyB64: string) {
  const wasm = await loadWasm();
  const exports = getExports(wasm);

  exports.clear_sessions();
  exports.clear_result();

  const blobBytes = new Uint8Array(blob);
  const key = keyFromB64(keyB64);

  const input = allocAndWrite(exports, blobBytes);
  const keyBuf = allocAndWrite(exports, key);

  try {
    const status = exports.decrypt(input.ptr, input.len, keyBuf.ptr);
    assertStatus(exports, status);

    const fileBytes = takeResultBytes(exports);
    const filename = takeResultFilename(exports);

    exports.clear_result();

    return { filename, fileBytes };
  } finally {
    input.free();
    keyBuf.free();
  }
}

export async function decryptBlobStream(blob: ReadableStream<Uint8Array>, keyB64: string) {
  const wasm = await loadWasm();
  const exports = getExports(wasm);

  exports.clear_sessions();
  exports.clear_result();

  const key = keyFromB64(keyB64);
  const keyBuf = allocAndWrite(exports, key);

  try {
    const beginStatus = exports.begin_decrypt(keyBuf.ptr);
    assertStatus(exports, beginStatus);
  } finally {
    keyBuf.free();
  }

  let filename = "";
  const parts: Uint8Array[] = [];

  try {
    const reader = blob.getReader();

    while (true) {
      const { value, done } = await reader.read();
      if (done) break;

      const chunk = value instanceof Uint8Array ? value : new Uint8Array(value);
      const input = allocAndWrite(exports, chunk);

      try {
        const status = exports.push_blob_bytes(input.ptr, input.len);
        assertStatus(exports, status);
      } finally {
        input.free();
      }

      const out = takeResultBytes(exports);
      if (out.length > 0) parts.push(out);

      if (!filename && exports.result_filename_len() > 0) {
        filename = takeResultFilename(exports);
      }

      exports.clear_result();

      if (exports.decrypt_done() === 1) break;
    }

    let total = 0;
    for (const p of parts) total += p.length;

    const fileBytes = new Uint8Array(total);
    let offset = 0;
    for (const p of parts) {
      fileBytes.set(p, offset);
      offset += p.length;
    }

    return { filename, fileBytes };
  } finally {
    exports.clear_sessions();
    exports.clear_result();
  }
}
