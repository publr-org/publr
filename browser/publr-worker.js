// Service worker: forwards every request to the Publr wasm module and returns its response.

importScripts("publr-files.js");

// The path Publr is served under: the scope's (`/demo/` → `/demo`), empty at the root.
const base = new URL(self.registration.scope).pathname.replace(/\/$/, "");
const passthrough = ["/index.html", "/publr-worker.js", "/publr-files.js", "/publr.wasm"].map((file) => base + file);
const wasi_errno_nosys = 52;
const db_file = "publr.sqlite";
const cookies_file = "publr.cookies.json";
// The database a browser with none of its own starts from: `publr-worker.js?seed=<file>`.
const seed_file = new URL(self.location.href).searchParams.get("seed");
// The project files such a browser starts from: `publr-worker.js?files=<file>`.
const seed_files = new URL(self.location.href).searchParams.get("files");
// Pages showing this Publr hear of every change, to draw again what they show of it.
const changes = new BroadcastChannel("publr");

let instance = null;
let ready = null;
// Cookie and Set-Cookie are forbidden headers inside a service worker, so the worker is the cookie jar.
let cookies = new Map();

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(Promise.all([self.clients.claim(), ensure_ready()])));

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;
  if (passthrough.includes(url.pathname)) return;
  event.respondWith(forward(event.request, url).catch((error) => {
    console.error("publr:", error);
    return new Response(error.message || "Publr could not handle this request", {
      status: error.status || 503,
      headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" },
    });
  }));
});

function ensure_ready() {
  return ready ??= boot().catch((error) => {
    ready = null;
    throw error;
  });
}

async function forward(request, url) {
  await ensure_ready();

  const headers = [...request.headers].map(([name, value]) => ({ name, value }));
  // Host is a forbidden header too; the same-origin check needs the one the page was served at.
  headers.push({ name: "host", value: url.host });
  if (cookies.size > 0) headers.push({ name: "cookie", value: [...cookies].map(([name, value]) => `${name}=${value}`).join("; ") });
  if (request.referrer) headers.push({ name: "referer", value: request.referrer });

  const envelope = {
    method: request.method,
    path: url.pathname,
    query: url.search.slice(1),
    headers,
  };

  const text = JSON.stringify(envelope);
  const read_only = request.method === "GET" || request.method === "HEAD";
  // The body goes over as its bytes, whatever they are: a form, JSON, a file.
  const body = read_only ? new Uint8Array(0) : new Uint8Array(await request.arrayBuffer());

  // A request that reads a library file the module lacks names it; it is handed over from
  // OPFS and the request runs again, as often as it names another one.
  for (let round = 0; round < needs_max; round += 1) {
    const response = JSON.parse(call("publr_request", text, body));
    if (response.need) {
      await attach(response.need);
      continue;
    }

    try {
      if (response.status < 400) await carry_out(response.effects ?? []);
      await PublrFiles.flush();
      for (const { name, value } of response.headers) if (name.toLowerCase() === "set-cookie") store_cookie(value);
      const body = body_bytes();
      if (!read_only) {
        await persist();
        changes.postMessage({ changed: url.pathname });
      }
      return new Response(response.status === 204 || response.status === 304 ? null : body, {
        status: response.status,
        headers: response.headers.map(({ name, value }) => [name, value]),
      });
    } finally {
      instance.exports.publr_settle();
    }
  }
  instance.exports.publr_settle();
  throw Object.assign(new Error("Publr needed more files than it may ask for"), { status: 503 });
}

const needs_max = 8;
const areas = { files: 0, incoming: 1 };

/** The folder an area's files live in, under OPFS's `media/`. */
async function folder_of(area, key, create) {
  let folder = await (await storage()).getDirectoryHandle("media", { create: true });
  if (area === "incoming") folder = await folder.getDirectoryHandle(".incoming", { create: true });
  const parts = key.split("/");
  for (const part of parts.slice(0, -1)) folder = await folder.getDirectoryHandle(part, { create });
  return { folder, name: parts[parts.length - 1] };
}

async function attach(need) {
  const { folder, name } = await folder_of(need.area, need.key, false).catch(() => ({ folder: null, name: "" }));
  const handle = folder && await folder.getFileHandle(name).catch(() => null);
  if (!handle) throw Object.assign(new Error(`${need.key} is not in this browser's storage`), { status: 404 });
  const bytes = new Uint8Array(await (await handle.getFile()).arrayBuffer());
  const key = new TextEncoder().encode(need.key);
  const key_ptr = instance.exports.publr_alloc(key.length);
  const ptr = bytes.length > 0 ? instance.exports.publr_alloc(bytes.length) : 0;
  if (!key_ptr || !ptr) throw Object.assign(new Error("Publr has no memory for this file"), { status: 503 });
  new Uint8Array(instance.exports.memory.buffer, key_ptr, key.length).set(key);
  new Uint8Array(instance.exports.memory.buffer, ptr, bytes.length).set(bytes);
  const code = instance.exports.publr_attach(areas[need.area], key_ptr, key.length, ptr, bytes.length);
  instance.exports.publr_free(key_ptr, key.length);
  if (code !== 0) throw Object.assign(new Error("Publr could not take the file: " + code), { status: 503 });
}

/** What the response wrote and removed, done in OPFS before it reaches the page. */
async function carry_out(effects) {
  for (const [index, effect] of effects.entries()) {
    const { folder, name } = await folder_of(effect.area, effect.key, effect.kind !== "remove");
    if (effect.kind === "remove") {
      await folder.removeEntry(name).catch(() => {});
      continue;
    }
    const ptr = instance.exports.publr_effect_ptr(index);
    const len = instance.exports.publr_effect_len(index);
    const bytes = new Uint8Array(instance.exports.memory.buffer, ptr, len).slice();
    const handle = await folder.getFileHandle(name, { create: true });
    const append = effect.kind === "append" && effect.offset > 0;
    const writable = await handle.createWritable({ keepExistingData: append });
    if (append) await writable.seek(effect.offset);
    await writable.write(bytes);
    await writable.close();
  }
}

function body_bytes() {
  const ptr = instance.exports.publr_body_ptr();
  const len = instance.exports.publr_body_len();
  return new Uint8Array(instance.exports.memory.buffer, ptr, len).slice();
}

async function boot() {
  const bytes = await (await fetch(new URL("publr.wasm", self.location.href))).arrayBuffer();
  const calls = { ...wasi_stubs, ...PublrFiles.wasi };
  const wasi = new Proxy(calls, { get: (target, name) => target[name] ?? (() => wasi_errno_nosys) });
  const result = await WebAssembly.instantiate(bytes, { wasi_snapshot_preview1: wasi });

  instance = result.instance;
  await PublrFiles.load(() => instance.exports.memory, seed_files && new URL(seed_files, self.location.href), storage);
  instance.exports._initialize?.();

  const code = instance.exports.publr_init();
  if (code !== 0) {
    ready = null;
    throw new Error("publr_init failed: " + code);
  }
  set_address();

  try {
    await restore();
  } catch (error) {
    instance.exports.publr_deinit();
    ready = null;
    throw error;
  }
  console.log("publr: wasm ready");
}

// Publr's own address, the scope's: the links it writes and the path it strips.
function set_address() {
  const encoded = new TextEncoder().encode(self.registration.scope.replace(/\/$/, ""));
  const ptr = instance.exports.publr_alloc(encoded.length);
  if (!ptr) throw new Error("Publr has no memory for its address");
  new Uint8Array(instance.exports.memory.buffer, ptr, encoded.length).set(encoded);
  const code = instance.exports.publr_address(ptr, encoded.length);
  instance.exports.publr_free(ptr, encoded.length);
  if (code !== 0) throw new Error(`Publr cannot be served at ${self.registration.scope}: ${code}`);
}

function call(name, text, body = new Uint8Array(0)) {
  const encoded = new TextEncoder().encode(text);
  const ptr = instance.exports.publr_alloc(encoded.length);
  const body_ptr = body.length > 0 ? instance.exports.publr_alloc(body.length) : 0;
  if (!ptr || (body.length > 0 && !body_ptr)) {
    if (ptr) instance.exports.publr_free(ptr, encoded.length);
    const error = new Error("Request is too large or Publr has no memory available");
    error.status = body.length > 32 * 1024 * 1024 ? 413 : 503;
    throw error;
  }
  try {
    new Uint8Array(instance.exports.memory.buffer, ptr, encoded.length).set(encoded);
    if (body.length > 0) new Uint8Array(instance.exports.memory.buffer, body_ptr, body.length).set(body);
    const code = instance.exports[name](ptr, encoded.length, body_ptr, body.length);
    if (code !== 0) {
      const error = new Error(name + " failed: " + code);
      error.status = code >= 2 && code <= 4 ? 400 : 503;
      throw error;
    }
  } finally {
    instance.exports.publr_free(ptr, encoded.length);
    if (body.length > 0) instance.exports.publr_free(body_ptr, body.length);
  }

  return new TextDecoder().decode(response_bytes());
}

function response_bytes() {
  const ptr = instance.exports.publr_response_ptr();
  const len = instance.exports.publr_response_len();
  return new Uint8Array(instance.exports.memory.buffer, ptr, len).slice();
}

function store_cookie(header) {
  const [pair, ...attributes] = header.split(";").map((part) => part.trim());
  const equals = pair.indexOf("=");
  if (equals <= 0) return;
  const name = pair.slice(0, equals);
  const expired = attributes.some((attribute) => attribute.toLowerCase() === "max-age=0");
  if (expired) cookies.delete(name);
  else cookies.set(name, pair.slice(equals + 1));
}

async function persist() {
  await write_file(cookies_file, new TextEncoder().encode(JSON.stringify([...cookies])));
  if (instance.exports.publr_export() !== 0) return;
  await write_file(db_file, response_bytes());
}

// This Publr's own folder in OPFS: its scope's path (`demo/shop/`), so Publrs under
// different scopes of one site keep separate databases and files; the root for one at `/`.
async function storage() {
  let folder = await navigator.storage.getDirectory();
  for (const part of base.split("/").filter(Boolean)) folder = await folder.getDirectoryHandle(part, { create: true });
  return folder;
}

async function write_file(name, bytes) {
  const root = await storage();
  const handle = await root.getFileHandle(name, { create: true });
  const writable = await handle.createWritable();
  await writable.write(bytes);
  await writable.close();
}

async function read_file(name) {
  const root = await storage();
  const handle = await root.getFileHandle(name).catch(() => null);
  if (!handle) return null;
  return new Uint8Array(await (await handle.getFile()).arrayBuffer());
}

async function restore() {
  const saved_cookies = await read_file(cookies_file);
  if (saved_cookies && saved_cookies.length > 0) cookies = new Map(JSON.parse(new TextDecoder().decode(saved_cookies)));
  const bytes = await read_file(db_file) ?? await read_seed();
  if (!bytes || bytes.length === 0) return;
  const ptr = instance.exports.publr_alloc(bytes.length);
  if (!ptr) throw new Error("Saved database is too large or Publr has no memory available");
  try {
    new Uint8Array(instance.exports.memory.buffer, ptr, bytes.length).set(bytes);
    const code = instance.exports.publr_import(ptr, bytes.length);
    if (code !== 0) throw new Error("Saved database could not be restored: " + code);
  } finally {
    instance.exports.publr_free(ptr, bytes.length);
  }
}

async function read_seed() {
  if (!seed_file) return null;
  const response = await fetch(new URL(seed_file, self.location.href));
  if (!response.ok) throw new Error(`The seed database ${seed_file} could not be fetched: ${response.status}`);
  return new Uint8Array(await response.arrayBuffer());
}

const wasi_stubs = {
  clock_time_get(id, precision, out) {
    new DataView(instance.exports.memory.buffer).setBigUint64(out, BigInt(Date.now()) * 1000000n, true);
    return 0;
  },
  clock_res_get(id, out) {
    new DataView(instance.exports.memory.buffer).setBigUint64(out, 1000000n, true);
    return 0;
  },
  random_get(ptr, len) {
    crypto.getRandomValues(new Uint8Array(instance.exports.memory.buffer, ptr, len));
    return 0;
  },
  environ_sizes_get(count, size) {
    const view = new DataView(instance.exports.memory.buffer);
    view.setUint32(count, 0, true); view.setUint32(size, 0, true);
    return 0;
  },
  environ_get: () => 0,
  args_sizes_get(count, size) {
    const view = new DataView(instance.exports.memory.buffer);
    view.setUint32(count, 0, true); view.setUint32(size, 0, true);
    return 0;
  },
  args_get: () => 0,
  poll_oneoff: () => wasi_errno_nosys,
  proc_exit(code) { throw new Error("proc_exit " + code); },
};
