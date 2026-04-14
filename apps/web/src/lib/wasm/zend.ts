import { loadWasm } from "./loader";

function writeBytes(memory: WebAssembly.Memory, ptr: number, data: Uint8Array) {
  new Uint8Array(memory.buffer, ptr, data.length).set(data);
}

function readBytes(memory: WebAssembly.Memory, ptr: number, len: number) {
  return new Uint8Array(memory.buffer, ptr, len).slice();
}

export async function encryptFile(file: File) {
  const wasm = await loadWasm();
  const exports = wasm.exports as any;
  const memory = exports.memory as WebAssembly.Memory;

  const fileBytes = new Uint8Array(await file.arrayBuffer());
  const filenameBytes = new TextEncoder().encode(file.name);

  // generate key in JS
  const key = crypto.getRandomValues(new Uint8Array(32));

  const inputPtr = exports.alloc_input(fileBytes.length);
  writeBytes(memory, inputPtr, fileBytes);

  const namePtr = exports.alloc_input(filenameBytes.length);
  writeBytes(memory, namePtr, filenameBytes);

  const keyPtr = exports.alloc_input(32);
  writeBytes(memory, keyPtr, key);

  const status = exports.encrypt(
    inputPtr,
    fileBytes.length,
    namePtr,
    filenameBytes.length,
    keyPtr
  );

  if (status !== 0) {
    const errPtr = exports.error_ptr();
    const errLen = exports.error_len();
    const err = new TextDecoder().decode(readBytes(memory, errPtr, errLen));
    throw new Error(err);
  }

  const outPtr = exports.result_ptr();
  const outLen = exports.result_len();
  const blob = readBytes(memory, outPtr, outLen);

  exports.clear_result();

  return {
    blob,
    keyB64: btoa(String.fromCharCode(...key)),
  };
}

export async function decryptBlob(blob: ArrayBuffer, keyB64: string) {
  const wasm = await loadWasm();
  const exports = wasm.exports as any;
  const memory = exports.memory as WebAssembly.Memory;

  const blobBytes = new Uint8Array(blob);
  const key = Uint8Array.from(atob(keyB64), c => c.charCodeAt(0));

  const inputPtr = exports.alloc_input(blobBytes.length);
  writeBytes(memory, inputPtr, blobBytes);

  const keyPtr = exports.alloc_input(32);
  writeBytes(memory, keyPtr, key);

  const status = exports.decrypt(inputPtr, blobBytes.length, keyPtr);

  if (status !== 0) {
    const errPtr = exports.error_ptr();
    const errLen = exports.error_len();
    const err = new TextDecoder().decode(readBytes(memory, errPtr, errLen));
    throw new Error(err);
  }

  const outPtr = exports.result_ptr();
  const outLen = exports.result_len();
  const fileBytes = readBytes(memory, outPtr, outLen);

  const namePtr = exports.result_filename_ptr();
  const nameLen = exports.result_filename_len();
  const filename = new TextDecoder().decode(readBytes(memory, namePtr, nameLen));

  exports.clear_result();

  return { filename, fileBytes };
}
