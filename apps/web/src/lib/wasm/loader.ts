let wasm: WebAssembly.Instance | null = null;

export async function loadWasm() {
  if (wasm) return wasm;

  const res = await fetch("/zend_wasm.wasm");
  const bytes = await res.arrayBuffer();

  const { instance } = await WebAssembly.instantiate(bytes, {});
  wasm = instance;

  return instance;
}
