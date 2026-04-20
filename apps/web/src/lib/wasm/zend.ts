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

type UploadProgress = {
  phase: "encrypting" | "uploading";
  fileBytesTotal: number;
  fileBytesProcessed: number;
  chunkIndex: number;
};

type DownloadProgress = {
  ciphertextBytesProcessed: number;
  plaintextBytesProduced: number;
  filename: string;
  done: boolean;
};

function logDebug(label: string, value: unknown) {
  console.log(`[zend] ${label}`, value);
}

function getExports(instance: WebAssembly.Instance): WasmExports {
  return instance.exports as unknown as WasmExports;
}

function writeBytes(memory: WebAssembly.Memory, ptr: number, data: Uint8Array) {
  new Uint8Array(memory.buffer, ptr, data.length).set(data);
}

function readBytes(memory: WebAssembly.Memory, ptr: number, len: number) {
  const byteOffset = ptr >>> 0;
  const byteLength = len >>> 0;
  const memSize = memory.buffer.byteLength >>> 0;

  if (byteOffset > memSize || byteLength > memSize - byteOffset) {
    const message =
      `WASM returned invalid slice: ptr=${byteOffset} len=${byteLength} memory=${memSize}`;

    console.error("[zend] readBytes invalid slice", {
      ptr: byteOffset,
      len: byteLength,
      memoryBytes: memSize,
      memory,
    });

    throw new Error(message);
  }

  // Copy immediately into JS-owned memory so later WASM memory growth or
  // mutation cannot invalidate the returned bytes.
  return new Uint8Array(memory.buffer.slice(byteOffset, byteOffset + byteLength));
}

function takeResultBytes(exports: WasmExports) {
  const ptr = exports.result_ptr() >>> 0;
  const len = exports.result_len() >>> 0;

  console.log("[zend] takeResultBytes", {
    ptr,
    len,
    memoryBytes: exports.memory.buffer.byteLength >>> 0,
  });

  if (len === 0) return new Uint8Array(0);

  return readBytes(exports.memory, ptr, len);
}

function takeResultFilename(exports: WasmExports) {
  const ptr = exports.result_filename_ptr() >>> 0;
  const len = exports.result_filename_len() >>> 0;

  console.log("[zend] takeResultFilename", {
    ptr,
    len,
    memoryBytes: exports.memory.buffer.byteLength >>> 0,
  });

  if (len === 0) return "";

  return new TextDecoder().decode(readBytes(exports.memory, ptr, len));
}

function utf8(input: string) {
  return new TextEncoder().encode(input);
}

function normalizeWasmError(message: string) {
  const trimmed = message.trim();

  switch (trimmed) {
    case "IntegrityHashMismatch":
    case "IntegritySizeMismatch":
      return "File verification failed. The file may be corrupted or incomplete.";

    case "MissingIntegrity":
    case "InvalidIntegrityPacket":
    case "DuplicateIntegrityPacket":
      return "This file could not be verified.";

    case "AuthenticationFailed":
      return "Decryption failed. The link may be invalid or the key may be wrong.";

    case "IncompleteStream":
    case "FrameTooShort":
    case "FrameTooLarge":
    case "InvalidTagSize":
    case "InvalidMetadata":
    case "InvalidChunk":
    case "InvalidDonePacket":
    case "UnknownPacketType":
      return "The encrypted file is malformed or incomplete.";

    case "ChunkBeforeMetadata":
    case "DuplicateMetadata":
    case "NoMetadata":
      return "The encrypted file metadata is invalid.";

    case "InvalidCompressionFlag":
      return "The encrypted file uses an invalid compression format.";

    case "SessionNotStarted":
    case "SessionAlreadyFinished":
      return "The decrypt session entered an invalid state.";

    default:
      return trimmed || "WASM operation failed.";
  }
}

function readErrorCode(exports: WasmExports) {
  try {
    const ptr = exports.error_ptr() >>> 0;
    const len = exports.error_len() >>> 0;

    if (len === 0) return "";

    return new TextDecoder().decode(readBytes(exports.memory, ptr, len));
  } catch {
    return "";
  }
}

function assertStatus(exports: WasmExports, status: number) {
  if (status === 0) return;

  const raw = readErrorCode(exports);
  const normalized = normalizeWasmError(raw);

  console.error("[zend] wasm status error", {
    status,
    rawError: raw,
    normalizedError: normalized,
  });

  throw new Error(normalized);
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
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function keyFromB64(keyB64: string) {
  const padded = keyB64
    .replace(/-/g, "+")
    .replace(/_/g, "/")
    .padEnd(Math.ceil(keyB64.length / 4) * 4, "=");

  const raw = atob(padded);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

async function postBytes(url: string, bytes: Uint8Array) {
  const body = new Uint8Array(bytes);

  const response = await fetch(url, {
    method: "POST",
    body
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || `Request failed with ${response.status}`);
  }

  return response;
}

export async function encryptFile(file: File) {
  const wasm = await loadWasm();
  const exports = getExports(wasm);

  exports.clear_sessions();
  exports.clear_result();

  const fileBytes = new Uint8Array(await file.arrayBuffer());
  const filenameBytes = utf8(file.name);
  const key = crypto.getRandomValues(new Uint8Array(32));

  logDebug("batch upload file", { name: file.name, size: file.size });

  const input = allocAndWrite(exports, fileBytes);
  const name = allocAndWrite(exports, filenameBytes);
  const keyBuf = allocAndWrite(exports, key);

  try {
    const status = exports.encrypt(
      input.ptr,
      input.len,
      name.ptr,
      name.len,
      keyBuf.ptr,
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

export async function uploadEncryptedFileChunked(
  relayUrl: string,
  file: File,
  onPhase?: (phase: "encrypting" | "uploading") => void,
  onProgress?: (progress: UploadProgress) => void,
): Promise<{ id: string; token: string; keyB64: string }> {
  const wasm = await loadWasm();
  const exports = getExports(wasm);

  exports.clear_sessions();
  exports.clear_result();

  const filenameBytes = utf8(file.name);
  const key = crypto.getRandomValues(new Uint8Array(32));

  const name = allocAndWrite(exports, filenameBytes);
  const keyBuf = allocAndWrite(exports, key);

  logDebug("upload file", { name: file.name, size: file.size });

  let uploadId = "";
  let uploadToken = "";
  let fileBytesProcessed = 0;

  try {
    const startRes = await fetch(`${relayUrl}/upload/start`, {
      method: "POST",
    });

    if (!startRes.ok) {
      const text = await startRes.text();
      throw new Error(text || `Upload start failed with ${startRes.status}`);
    }

    const started = (await startRes.json()) as { id: string; token: string };
    uploadId = started.id;
    uploadToken = started.token;

    onPhase?.("encrypting");
    onProgress?.({
      phase: "encrypting",
      fileBytesTotal: file.size,
      fileBytesProcessed: 0,
      chunkIndex: 0,
    });

    const beginStatus = exports.begin_encrypt(
      name.ptr,
      name.len,
      file.size,
      keyBuf.ptr,
    );
    assertStatus(exports, beginStatus);

    let index = 0;

    const metadataFrame = takeResultBytes(exports);
    exports.clear_result();

    if (metadataFrame.length === 0) {
      throw new Error("Missing metadata frame");
    }

    onPhase?.("uploading");
    onProgress?.({
      phase: "uploading",
      fileBytesTotal: file.size,
      fileBytesProcessed: 0,
      chunkIndex: index,
    });

    await postBytes(
      `${relayUrl}/upload/append/${uploadId}?token=${encodeURIComponent(uploadToken)}&index=${index}`,
      metadataFrame,
    );
    index += 1;

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

      const frame = takeResultBytes(exports);
      exports.clear_result();

      if (frame.length === 0) {
        throw new Error(`Missing encrypted frame at index ${index}`);
      }

      await postBytes(
        `${relayUrl}/upload/append/${uploadId}?token=${encodeURIComponent(uploadToken)}&index=${index}`,
        frame,
      );

      fileBytesProcessed += chunk.length;
      onProgress?.({
        phase: "uploading",
        fileBytesTotal: file.size,
        fileBytesProcessed,
        chunkIndex: index,
      });

      index += 1;
    }

    const finishStatus = exports.finish_encrypt();
    assertStatus(exports, finishStatus);

    const doneFrame = takeResultBytes(exports);
    exports.clear_result();

    if (doneFrame.length === 0) {
      throw new Error("Missing DONE frame");
    }

    await postBytes(
      `${relayUrl}/upload/append/${uploadId}?token=${encodeURIComponent(uploadToken)}&index=${index}`,
      doneFrame,
    );

    onProgress?.({
      phase: "uploading",
      fileBytesTotal: file.size,
      fileBytesProcessed: file.size,
      chunkIndex: index,
    });

    const finishRes = await fetch(
      `${relayUrl}/upload/finish/${uploadId}?token=${encodeURIComponent(uploadToken)}`,
      { method: "POST" },
    );

    if (!finishRes.ok) {
      const text = await finishRes.text();
      throw new Error(text || `Upload finish failed with ${finishRes.status}`);
    }

    const finalJson = (await finishRes.json()) as { id: string; token: string };

    return {
      id: finalJson.id,
      token: finalJson.token,
      keyB64: keyToB64(key),
    };
  } finally {
    name.free();
    keyBuf.free();
    exports.clear_sessions();
    exports.clear_result();
  }
}

export async function decryptBlob(blob: ArrayBuffer, keyB64: string) {
  const wasm = await loadWasm();
  const exports = getExports(wasm);

  exports.clear_sessions();
  exports.clear_result();

  const blobBytes = new Uint8Array(blob);
  const key = keyFromB64(keyB64);

  logDebug("download ciphertext bytes", blobBytes.length);

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

export async function decryptBlobStream(
  blob: ReadableStream<Uint8Array>,
  keyB64: string,
  onProgress?: (progress: DownloadProgress) => void,
) {
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
  let totalCiphertextBytes = 0;
  let totalPlaintextBytes = 0;

  try {
    const reader = blob.getReader();

    while (true) {
      const { value, done } = await reader.read();
      if (done) break;

      const chunk = value instanceof Uint8Array ? value : new Uint8Array(value);
      totalCiphertextBytes += chunk.length;

      const input = allocAndWrite(exports, chunk);

      try {
        const status = exports.push_blob_bytes(input.ptr, input.len);
        assertStatus(exports, status);
      } finally {
        input.free();
      }

      let out: Uint8Array;
      try {
        out = takeResultBytes(exports);
      } catch (err) {
        console.error("[zend] invalid wasm result slice after push_blob_bytes", {
          resultPtr: exports.result_ptr(),
          resultLen: exports.result_len(),
          filenamePtr: exports.result_filename_ptr(),
          filenameLen: exports.result_filename_len(),
          memoryBytes: exports.memory.buffer.byteLength >>> 0,
          ciphertextChunkBytes: chunk.length,
          totalCiphertextBytes,
          err,
        });
        throw err;
      }

      if (out.length > 0) {
        parts.push(out);
        totalPlaintextBytes += out.length;
      }

      if (!filename && exports.result_filename_len() > 0) {
        try {
        filename = takeResultFilename(exports);
        } catch (err) {
        console.error("[zend] invalid wasm filename slice after push_blob_bytes", {
          resultPtr: exports.result_ptr(),
          resultLen: exports.result_len(),
          filenamePtr: exports.result_filename_ptr(),
          filenameLen: exports.result_filename_len(),
          memoryBytes: exports.memory.buffer.byteLength >>> 0,
          ciphertextChunkBytes: chunk.length,
          totalCiphertextBytes,
          err,
        });
        throw err;
        }
      }

      const doneNow = exports.decrypt_done() === 1;

      onProgress?.({
        ciphertextBytesProcessed: totalCiphertextBytes,
        plaintextBytesProduced: totalPlaintextBytes,
        filename,
        done: doneNow,
      });

      exports.clear_result();

      if (doneNow) break;
    }

    let total = 0;
    for (const p of parts) total += p.length;

    const fileBytes = new Uint8Array(total);
    let offset = 0;
    for (const p of parts) {
      fileBytes.set(p, offset);
      offset += p.length;
    }

    onProgress?.({
      ciphertextBytesProcessed: totalCiphertextBytes,
      plaintextBytesProduced: fileBytes.length,
      filename,
      done: true,
    });

    return { filename, fileBytes };
  } finally {
    exports.clear_sessions();
    exports.clear_result();
  }
}
