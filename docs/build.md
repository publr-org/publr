# Build reference

Requires Zig 0.16.0 (`.zigversion`). `build.zig` only wires steps together;
each concern lives in `build/<topic>.zig`.

## Steps

| Step | What it does |
|---|---|
| `zig build` | Build `zig-out/bin/publr` with the apps under `apps/` (none in this repository) and check they compile (`publr check-apps`). The first build also compiles the Zig compiler the binary carries (`../lib/zig`, about two minutes); the cache keeps it after that. |
| `zig build run -- <args>` | Build and run. |
| `zig build test` | Run all tests: the core (`src/publr.zig`, built with the fixture apps under `fixtures/apps/`), every plugin compiled in from `plugins/` (`publr.zon`), and the scripts (`scripts/tidy.zig`, `scripts/vendor.zig`, `scripts/smoke.zig`, `scripts/parity.zig`). |
| `zig build verify` | The core's tests + `zig fmt --check` + `tidy`: one compile of the core, the check to run after every change. |
| `zig build verify-full` | `test` + wasm32-wasi compile of the core + `zig fmt --check` + `tidy` + `smoke` + `parity` + `two-mode` + `browser`. Each builds Publr its own way, so it takes minutes; run it before a commit. |
| `zig build parity` | Run the example every `--help` prints and check its answer. |
| `zig build two-mode` | Run every test plugin installed and compiled in, and compare the answers. |
| `zig build sandboxed-plugins` | Build the plugins under `-Dsandboxed-plugins` as installed plugins into `zig-out/sandboxed-plugins/<name>.wasm`, with the `publr` just built; see [The plugins](#the-plugins). |
| `zig build browser` | Build the browser target into `zig-out/browser/` (`publr.wasm`, `index.html`, `publr-worker.js`); see [Publr in the browser](browser.md). |
| `zig build vendor-import` | Re-import `vendor/` from local upstream archives (`-Darchives=<dir>`, default `.vendor-archives/`). |
| `zig build vendor-cache-check` | Prove a no-op build recompiles no vendor C. |

## Options

| Option | Default | Used by |
|---|---|---|
| `-Dtarget`, `-Doptimize` | native, Debug | all |
| `-Darchives=<dir>` | `.vendor-archives` | `vendor-import` |
| `-Dbrowser-debug=true` | `false` | `browser` (Debug wasm with panic messages) |
| `-Dapps=<dir>` | `apps` | the folder of apps compiled in, relative to this repository; absent is none (`build/apps.zig`) |
| `-Dapps-max=<n>` | `32` | how many apps one project may compile in, 1 to 1024 |
| `-Dcompiler=false` | `true` | leave out the compiler for sandboxed plugins (`publr zig`, about 8 MB); the test fixture is built without it |
| `-Dtoolchain-archive=<file>` | none | carry this archive as that compiler instead of building it: `zig build toolchain -Dtarget=<the same target>` in `../lib/zig` makes it (`zig-out/toolchain.tar.gz`). CI keeps one per target until Zig changes |
| `-Dplugins=<dir>` | `plugins` | the folder of plugins, one each, relative to this repository; `publr.zon` beside it names the ones compiled in (`.plugins = .{ .native = ... }`), the rest are built for the sandbox |
| `-Dpreset=<dir>` | none | a project's parts at once: `<dir>/apps`, `<dir>/plugins` and `<dir>/publr.zon` (each option above still wins); the binary reads the preset's apps wherever it runs when the project has no `apps/` of its own |

## Vendors and libraries

stb and libwebp are vendored **as-is** under `vendor/` and compiled once into
a static library per target (`ReleaseFast`, always). Zig's cache keeps it
built between runs. There is no plugin manager: to update, download the
upstream archive, verify its checksum or signature by hand, place it in
`.vendor-archives/`, run `zig build vendor-import`, review the diff. Each
`vendor/<name>/VERSION.zon` records the upstream, archive name and SHA-256.

SQLite, the HTTP server, the auth primitives and the dependency index come in
as Publr's own libraries from the sibling repos (`../lib/{sqlite,http,auth,deps}`,
`../pjsx`, `../jit`, path dependencies in `build.zig.zon`; see
[Dependencies](dependencies.md)).
`build/core.zig` imports their modules into the core; each library's own
`build.zig` builds it for whatever target the core asks for, wasm32-wasi
included (the browser build drives `publr_http` offline, with no socket).

## The apps

`build/apps.zig` compiles in every folder under `-Dapps` (`apps/` by default); each must
carry its `app.zon`, whose `.name` (`[a-z][a-z0-9_]*`) is the app's id, whatever its
folder. For each app it generates one module: its templates as text for the engine to read at
startup, its generated client code (the island loader `src/adapters/apps/islands.js`, the
toolbar, the PublrJS runtime from `../publr-js/dist` and the stores of its interactive
components) as its `/_app/*` assets, `app.zon`, `public/style.css` and the JIT's
preflight as its run-time stylesheet's inputs, `interactive/*.ptsx` lowered by
`pjsx_gen` like the admin's views (`build/apps/embed.zig`), and its `middleware.zig`,
which imports `publr` and every built-in plugin. An app without `style.css`,
`interactive/` or `middleware.zig` gets empty placeholders. The generated `apps` module
lists them all; `src/adapters/apps/spec.zig` reads it at compile time, and a name, a
mount or a role that is not valid fails the build there. Nothing generated is committed.

Core ships no app. Its own tests and the smoke build a second binary, `publr-fixture`,
with the fixture apps under `fixtures/apps/`: `www` at the root, `docs` under `/docs`
and `portal`, which has no pages, on a subdomain.

## The plugins

`build/sandboxed_plugins.zig` builds each plugin for the sandbox the way its users do:
it runs the `publr` just built, `publr plugin build --name <name> --dir <folder> --out
<file>`, with the toolchain written out under `.zig-cache/publr-toolchain` rather than
the user's cache. That compiles the plugin, the `publr` module and a generated root that
exports the module's entry points (`publr_alloc`, `publr_free`, `publr_invoke`,
`publr_manifest`) for `wasm32-freestanding` with a 256 KiB stack, by the compiler Publr
carries (`../lib/zig`: no LLVM, so modules are larger than an LLVM build's). The `publr`
module is the core's own source, packed into the binary with the build (`sdk_archive`);
what the sandbox never reaches (SQLite, the HTTP server, the apps) is an empty module in
its place, so a plugin that reaches for them fails to compile. The manifest (see
[Plugins](plugins.md#installed-plugins-dlp)) is read by running `publr_manifest` in the
sandbox and written into the module's `publr` custom section. The WebAssembly runtime
itself is `../lib/wasm` (WAMR's fast interpreter, vendored), a path dependency like
SQLite. Each folder the build packs lists its files as inputs, so a change to `src/`
packs the SDK again.

Core's tests, parity and smoke add the test plugins under `src/server/sandboxed_plugins/testdata/` (test inputs, not plugins of the product):
`greeter`, its next version `greeter_next`, which asks for more, `farewell`, and
`sampler`, which declares every part of the plugin contract once; `recorder`, compiled
into the two-mode check's native binary only, which keeps every structure change it
hears; and `postcard`, which the smoke installs in that binary.

## Smoke test

`smoke` (`scripts/smoke.zig`) runs the fixture binary from a fresh directory:
`--version`, `heartbeat check`, `--help`, `init`, `user sign_in`,
`--as` role checks, generated passwords, set-password links, the fixture plugin
added and enabled with `plugin add` and `enable`, its operation called (and refused to nobody), `serve` + a
real `GET /api/health` and `POST /api/auth/sign-in`, then the apps: a
published post, `build` into a folder per app, and `serve` answering the home page,
the post's page, a fragment, the stylesheet, a page of the app under `/docs` and the app
on a subdomain. Then the plain binary, with no apps, answers `/` with the admin. Last,
the binary with the test plugins compiled in (the two-mode check's) serves the admin on
port 8092: `sampler`'s settings page at its own route, its entry in the Settings sidebar
and its item in the top bar, the page reading the port from the plugin's state; its
operator command refused without the key and answered with it; and `--sampler-in`, its
CLI pre-command hook, running a command in another folder; then a content type, a
taxonomy, a field group and `postcard` added and enabled through the running server,
each heard by `recorder`, as the apps loaded at start were. It listens on port 8090, away from the dev default (8080), so it never
collides with a running `serve`.

`verify-full` can also run one local hook: when `PUBLR_VERIFY_HOOK=<executable>`
is set, the executable runs after the browser build with the arguments
`<publr binary> <browser dir> <work dir>` and its exit code gates `verify-full`.
Nothing in the repo depends on it; it exists so a machine can add its own
checks (for example a headless-browser smoke of the wasm build) without
adding tools or scripts to the codebase.

## Two-mode check

`two-mode` (`scripts/two_mode.zig`) proves that a plugin does the same whichever way it
runs. It builds Publr twice from the same sources, with the fixture apps: once with
`greeter`, `farewell` and `sampler` compiled in, once with none. In a fresh project for
each it creates the same admin and editor, adds, enables and grants the three modules in
the second, then makes the same calls of both (`scripts/two_mode/scenario.zig`): every
operation as the admin, the editor, nobody and the operator, the refusals, bad flags and
failures included, the hooks' effects, the records, types, field group and roles the
plugins leave, and every `--help`. Exit code, output and error must match, ids and times
masked; any difference fails `verify-full` and prints both answers.

Every field of the manifest is placed in `scripts/two_mode/coverage.zig`: exercised by a
test plugin and a call, or named as the sandbox's own (its limits, the content it may
reach, the domains, `depends_on`). A field added to the manifest fails the build there
until it is placed, and so does a hook stage or field shape no test plugin uses.

## Parity check

`parity` (`scripts/parity.zig`) proves that the documentation works. For every
registered operation it makes a directory of its own, seeds a database with
what the examples name (`scripts/parity/world.zig`: an admin to pass to `--as`,
an editor who can sign in, an invited account holding the documented token, the
`post` and `page` types, a live record with a revision behind it, one with
parked changes, a draft, and a trusted sign-on issuer), then asks the built binary for
`<namespace> <verb> --help`, takes the example command line out of what it
printed, and runs exactly that. The one exception is `sign_on redeem`: a
sign-on token is good for a minute, so no printed one can work, and parity
signs a fresh one with the seeded issuer's key in its place.

The answer is parsed into the operation's `Out` and compared with the
`example_out` printed beside it: the same fields, the same optionals set or
null, lists empty or not together, flags and enums equal. Ids, timestamps,
counts and generated passwords differ every run and are not compared, and a
documented list is a sample rather than a census.

It fails when an example names something that does not exist, when the printed
command cannot run as printed, and when an operation's real answer stops
matching its documented one.

## Continuous integration

`.github/workflows/verify.yml` runs `zig build verify-full` on every push to `main`
and every pull request. The browser smoke is agent-only, so it is skipped there.
The sibling repositories come from `.github/actions/workspace`, which checks
out the latest `main` of `lib`, `pjsx`, `jit`, `ui`, `icons` and `publrjs`
beside this one, builds `publrjs` with Vite+ into `../publr-js/dist`, and
installs Zig. Each run's summary lists the commit of every repository it built.
Another repository building on Publr uses the same action after checking out
itself and `publr`.

## `tidy` rules

`verify` fails on any of these in `build.zig`, `build/`, `src/`, `scripts/`:

- line over 100 columns;
- trailing whitespace;
- top-level `var`;
- `usize` in a declaration (constants, fields, function signatures);
- empty `catch {}`;
- single-letter identifiers;
- abbreviated identifiers, checked per segment of every declared name
  (`op_id`, `OpId`, `stmt`, `tx`, `rc`, `tmp`, ...);
- fewer than two assertions in a non-trivial function;
- functions longer than 70 lines;
- control flow (`if`, `while`, `for`, `switch`) without a blank line before
  and after it;
- `if`/`else` bodies without braces;
- em dashes in Markdown.

The rules live in `scripts/tidy/`; every message can carry a hint from
`PUBLR_TIDY_HINT` (empty by default).

## Debugging

`zig build` is a Debug build with DWARF, so `lldb zig-out/bin/publr -- --db data/publr.db
record list --type post` works as is. For VS Code, `.vscode/launch.json` has three
CodeLLDB configurations: `publr serve (8090)`, `publr <command>` (asks for the arguments)
and `publr tests`, which runs `zig build test-exe` first to put the test binary at
`zig-out/bin/publr-tests`. Breakpoints in `.zig` files work; the recommended extensions are
`vadimcn.vscode-lldb` and `ziglang.vscode-zig`.
