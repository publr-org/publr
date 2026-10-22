// Installed plugins for the Publr module: each plugin's module compiled and run on the
// browser's own WebAssembly. Publr asks for them through its import module `publr_wasm`; a
// plugin calling one of Publr's host functions comes back through Publr's export
// `publr_wasm_host`. A plugin's memory is its own: Publr reads and writes it by copy.

const PublrSandbox = (() => {
  const status = { ok: 0, trap: 1, not_found: 2, exhausted: 3 };
  const page_bytes = 65536;
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const modules = new Map();
  const instances = new Map();
  let next_module = 1;
  let next_instance = 1;
  let host_functions = [];
  let publr = null;

  const memory = () => publr().exports.memory.buffer;
  const bytes = (ptr, len) => new Uint8Array(memory(), ptr, len);

  // A problem in Publr's buffer at `ptr`, at most the length at `len_ptr`, which is set to
  // what was written.
  function tell(text, ptr, len_ptr) {
    const view = new DataView(memory());
    const room = view.getUint32(len_ptr, true);
    const said = encoder.encode(String(text)).slice(0, room);
    bytes(ptr, said.length).set(said);
    new DataView(memory()).setUint32(len_ptr, said.length, true);
  }

  function host_functions_of(names_ptr, names_len) {
    host_functions = decoder.decode(bytes(names_ptr, names_len)).split("\n").filter(Boolean);
  }

  function load(ptr, len, problem_ptr, problem_len) {
    try {
      const module = new WebAssembly.Module(bytes(ptr, len).slice());
      modules.set(next_module, module);
      return next_module++;
    } catch (error) {
      tell(error.message, problem_ptr, problem_len);
      return 0;
    }
  }

  function unload(id) {
    modules.delete(id);
  }

  // A plugin's import of `env.<name>` calls Publr's host function by its index, with the
  // environment Publr gave this instance.
  function imports_for(module, env) {
    const functions = {};
    for (const wanted of WebAssembly.Module.imports(module)) {
      if (wanted.module !== "env" || wanted.kind !== "function") continue;
      const index = host_functions.indexOf(wanted.name);
      if (index < 0) continue;
      functions[wanted.name] = (a = 0, b = 0, c = 0, d = 0, e = 0) =>
        publr().exports.publr_wasm_host(env, index, a, b, c, d, e);
    }
    return { env: functions };
  }

  function instantiate(module_id, env, pages_max, problem_ptr, problem_len) {
    const module = modules.get(module_id);
    if (!module) {
      tell("no such module", problem_ptr, problem_len);
      return 0;
    }
    try {
      const instance = new WebAssembly.Instance(module, imports_for(module, env));
      const kept = { instance, pages_max };
      if (pages_of(kept) > pages_max) throw new Error("its memory starts past its limit");
      instances.set(next_instance, kept);
      return next_instance++;
    } catch (error) {
      tell(error.message, problem_ptr, problem_len);
      return 0;
    }
  }

  function deinstantiate(id) {
    instances.delete(id);
  }

  const pages_of = (kept) => (kept.instance.exports.memory?.buffer.byteLength ?? 0) / page_bytes;

  function call(id, name_ptr, name_len, params_ptr, params_len, result_ptr, problem_ptr, problem_len) {
    const kept = instances.get(id);
    const name = decoder.decode(bytes(name_ptr, name_len));
    const exported = kept?.instance.exports[name];
    if (typeof exported !== "function") {
      tell(name, problem_ptr, problem_len);
      return status.not_found;
    }
    const params = Array.from(new Uint32Array(memory(), params_ptr, params_len));
    try {
      const answer = exported(...params);
      if (pages_of(kept) > kept.pages_max) {
        tell("memory limit exceeded", problem_ptr, problem_len);
        return status.trap;
      }
      new DataView(memory()).setUint32(result_ptr, (answer ?? 0) >>> 0, true);
      return status.ok;
    } catch (error) {
      tell(error.message, problem_ptr, problem_len);
      return status.trap;
    }
  }

  // Bytes between Publr and a plugin's memory; 0 when any of them is outside it.
  function guest_bytes(id, offset, len) {
    const buffer = instances.get(id)?.instance.exports.memory?.buffer;
    if (!buffer || offset + len > buffer.byteLength) return null;
    return new Uint8Array(buffer, offset, len);
  }

  function read(id, offset, target, len) {
    const source = guest_bytes(id, offset, len);
    if (!source) return 0;
    bytes(target, len).set(source);
    return 1;
  }

  function write(id, offset, source, len) {
    const target = guest_bytes(id, offset, len);
    if (!target) return 0;
    target.set(bytes(source, len));
    return 1;
  }

  return {
    /** The import module `publr_wasm` for the Publr instance `of()` answers. */
    imports(of) {
      publr = of;
      return {
        publr_wasm_host_functions: host_functions_of,
        publr_wasm_load: load,
        publr_wasm_unload: unload,
        publr_wasm_instantiate: instantiate,
        publr_wasm_deinstantiate: deinstantiate,
        publr_wasm_call: call,
        publr_wasm_read: read,
        publr_wasm_write: write,
      };
    },
  };
})();
