# Publr in the browser

Publr runs in two places from one codebase: natively, as a binary listening on
a port, and in the browser, as the very same code compiled to WebAssembly.
This page is the one place that explains the browser side; every other page
describes Publr once, and it holds for both.

## How it works

```mermaid
flowchart LR
    Page[Page] -->|fetch| Worker[Service worker]
    Worker -->|request JSON| Wasm[Publr wasm]
    Wasm -->|response JSON| Worker
    Worker -->|Response| Page
```

A tiny page registers a service worker and reloads. From then on the worker
intercepts every request the page makes to its own origin, hands it to the
Publr module as a JSON envelope (method, path, query, headers) with the body's
bytes beside it as they are, and
returns the module's response as a real HTTP response. Publr answers exactly
as the native server would: the same routes, the same operations, the same
permissions. The worker knows nothing about Publr; it only carries requests in
and responses out.

The worker's scope is Publr's address, as `--url` is the native server's: the
apps' links and the admin's way to each app are written at it. Registered below
the root (`/demo/`), the worker answers only what is under it, and Publr runs
under that path: requests arrive without it and every address sent back carries it. The
worker loads `publr.wasm` from beside itself (with `publr-worker.js?v=<version>`, as
`publr.wasm?v=<version>`, and the same for its other script, so a cache in front never mixes
builds), and keeps everything in OPFS under
its scope's path (`demo/shop/`), so Publrs at different scopes of one site never share a
database or a file. That is how a site embeds Publr
on its own pages: the files under `/demo/`, a frame opening `/demo/admin`.

It needs that storage: Safari keeps none in a private window, and the worker then says so
instead of starting. Safari before 26 lets a service worker read OPFS but not write it (no
`createWritable`): there Publr runs from memory for the visit, the database, files and
pictures included, and starts again from the seed once the browser stops the worker. It starts in about 90 MB: the buffers it keeps for as long as it runs
(SQLite's heap, the request arena, the password hashing scratch) are grown by exactly their
size, since an iPhone lets a service worker grow only so far.

Three things the worker does own, because the module cannot reach them:

- **the database**: SQLite lives in memory inside the module and is written
  to the browser's storage after every change and restored on the next boot. A
  browser with none of its own starts from the file the worker was registered
  with, `publr-worker.js?seed=<file>`, when there is one: a demo's content, ready;
- **the session cookie**: `Set-Cookie` and `Cookie` are invisible to service
  workers, so the worker keeps the cookie jar itself and persists it with the
  database;
- **the project's files**: the folder Publr runs in, its apps first, is OPFS's
  `files/`. Publr reads and writes it as it would a disk, through WASI's file
  calls, which the worker answers from a copy it keeps in memory (OPFS cannot be
  reached synchronously) and carries out in OPFS before the response leaves. A
  browser with none starts from `publr-worker.js?files=<file>`, a JSON object
  of paths and their contents in base64. So the apps are read from `apps/`, as
  `serve` reads them, and what edits them (the design system, `apps.write`)
  works here too. A browser whose copy started from other seeds (an earlier build of a
  demo, whose seed addresses carry its version) drops it and starts from these;
- **the media library's files**: each file is its own file in OPFS under
  `media/`, which only the worker can open, and only asynchronously. When a request
  needs one the module does not hold, its answer names it (`need`); the worker hands
  it over (`publr_attach`) and runs the request again, which is safe because a failed
  request changed nothing. What a request writes or removes comes back as `effects`,
  carried out in OPFS before the response reaches the page. A file OPFS does not hold
  comes from `publr-worker.js?media=<folder>`, when the worker was registered with one,
  at `<folder>/<key>`, and is kept in OPFS from then on: a demo's pictures, fetched only
  when a page shows them. The module resizes images
  as the server does, but keeps their format (no WebP) and keeps no copies. A
  response's body is read by pointer (`publr_body_ptr`), so it may be bytes;
- **installed plugins' modules**: a plugin uploaded in the admin is kept in `files/plugins/`,
  added and enabled as on a server, and runs on the browser's own WebAssembly:
  `publr-sandbox.js` compiles each module in the worker, Publr calls it through its import
  module `publr_wasm`, and the plugin's calls back into Publr return through the export
  `publr_wasm_host`. The browser keeps no instruction budget, so a plugin that never
  returns holds the tab; its memory limit is checked after each call.

## Building and running it

```
zig build browser                  # zig-out/browser: publr.wasm, index.html, the worker
zig build run -- serve --browser   # http://127.0.0.1:8081/
```

`serve --browser [<dir>]` serves that directory as static files (`/` is
`index.html`); after the first load, everything under `/` is answered by the
module in the tab. The module serves the apps in the project's `apps/`, or,
when that holds none, the ones it was built with (`-Dpreset`, `-Dapps`), every
page rendered on request; with neither, `/` opens the admin, which asks for the
first administrator on a fresh database.

After every change the worker posts `{ changed: <path> }` on the
`BroadcastChannel` named `publr`, so a page showing a site beside its admin can
draw it again. Native and browser servers run side by side on `8080` and
`8081`. `-Dbrowser-debug=true` builds the module in Debug mode with panic
messages.

## What it is for

Trying Publr without installing anything, demos, offline editing, and one day
a full local-first workflow. It is not a "lite" version: the test suite and
the smoke tests run against the same code, and `zig build verify-full` compiles the
WebAssembly target on every run.
