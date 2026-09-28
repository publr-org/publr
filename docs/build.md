# Build reference

Requires Zig 0.16.0 (`.zigversion`). `build.zig` only wires steps together;
each concern lives in `build/<topic>.zig`.

## Steps

| Step | What it does |
|---|---|
| `zig build` | Build `zig-out/bin/publr`. |
| `zig build run -- <args>` | Build and run. |
| `zig build test` | Run all tests: the core (`src/publr.zig`), every plugin under `plugins/`, and the scripts (`scripts/tidy.zig`, `scripts/vendor.zig`, `scripts/smoke.zig`, `scripts/parity.zig`). |
| `zig build verify` | `test` + wasm32-wasi compile of the core + `zig fmt --check` + `tidy` + `smoke` + `parity` + `browser`. Run before calling anything done. |
| `zig build parity` | Run the example every `--help` prints and check its answer. |
| `zig build browser` | Build the browser target into `zig-out/browser/` (`publr.wasm`, `index.html`, `publr-worker.js`); see [Publr in the browser](browser.md). |
| `zig build vendor-import` | Re-import `vendor/` from local upstream archives (`-Darchives=<dir>`, default `.vendor-archives/`). |
| `zig build vendor-cache-check` | Prove a no-op build recompiles no vendor C. |

## Options

| Option | Default | Used by |
|---|---|---|
| `-Dtarget`, `-Doptimize` | native, Debug | all |
| `-Darchives=<dir>` | `.vendor-archives` | `vendor-import` |
| `-Dbrowser-debug=true` | `false` | `browser` (Debug wasm with panic messages) |
| `-Dtheme=<name>` | `default` | the folder under `themes/` embedded as the site's theme (`build/theme.zig`) |

## Vendors and libraries

stb and libwebp are vendored **as-is** under `vendor/` and compiled once into
a static library per target (`ReleaseFast`, always). Zig's cache keeps it
built between runs. There is no package manager: to update, download the
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

## The theme

`build/theme.zig` embeds `themes/<name>/` (`-Dtheme`): every `.publr` as text
for the engine to read at startup, `public/*` with the island loader
(`src/adapters/site/islands.js`) and the PublrJS runtime (`../publr-js/dist`)
as the `/theme/*` assets, `theme.zon`, `public/style.css` and the JIT's
preflight as the run-time stylesheet's inputs, and `interactive/*.ptsx`
lowered by `pjsx_gen` like the admin's views. A theme without `theme.zon`,
`style.css` or `interactive/` gets empty placeholders. Nothing generated is
committed.

## Smoke test

`smoke` (`scripts/smoke.zig`) runs the built binary from a fresh directory:
`--version`, `heartbeat check`, `--help`, `init`, `user sign_in`,
`--as` role checks, generated passwords, set-password links, `serve` + a
real `GET /api/health` and `POST /api/auth/sign-in`, then the site: a
published post, `build` into a folder, and `serve` answering the home page,
the post's page, a fragment and the stylesheet.
It listens on port 8090, away from the dev default (8080), so it never
collides with a running `serve`.

`verify` can also run one local hook: when `PUBLR_VERIFY_HOOK=<executable>`
is set, the executable runs after the browser build with the arguments
`<publr binary> <browser dir> <work dir>` and its exit code gates `verify`.
Nothing in the repo depends on it; it exists so a machine can add its own
checks (for example a headless-browser smoke of the wasm build) without
adding tools or scripts to the codebase.

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

`.github/workflows/verify.yml` runs `zig build verify` on every push to `main`
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
