let wasm: WebAssembly.Instance | null = null;

export async function loadWasm() {
  if (wasm) return wasm;

  const res = await fetch("/zend_wasm.wasm");
  if (!res.ok) {
    throw new Error(`Failed to load wasm: ${res.status}`);
  }

  const bytes = await res.arrayBuffer();

  const memory = new WebAssembly.Memory({
    initial: 32,
    maximum: 256,
  });

  const { instance } = await WebAssembly.instantiate(bytes, {
    env: { memory },
  });

  wasm = instance;
  return instance;
}
