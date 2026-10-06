# Dependencies

Publr's rule is that a dependency must be **rare, boring, and ours to keep**.
Rare: the list is deliberately tiny. Boring: mature, permissively licensed,
dependency-free C. Ours to keep: vendored as-is in this repository, compiled by
`zig build`, never fetched, never updated behind our back.

## The list

| Where | What | Version | License | Why it exists |
|---|---|---|---|---|
| `publr_sqlite` (`../lib/sqlite`) | Our own binding, with the SQLite amalgamation inside it | 3.53.4 | Public domain | Storage. The one piece of infrastructure nobody should rewrite. |
| `publr_http` (`../lib/http`) | Our own HTTP/1.1 server: fixed capacity, one thread, composed at compile time | sibling checkout | Ours | Every door but the CLI. |
| `publr_auth` (`../lib/auth`) | Our own argon2id hashing, sign-in throttle, CSRF tokens, origin check | sibling checkout | Ours | Signing in, and nothing about users. |
| `publr_deps` (`../lib/deps`) | Our own dependency index: what each built artifact read, and the queue of changes to rebuild from | sibling checkout | Ours | Publishing rewrites only the pages that changed. |
| `publr_wasm` (`../lib/wasm`) | Our own sandbox, with WAMR's fast interpreter inside it | WAMR 2.4.5 | Apache-2.0 WITH LLVM-exception | Running installed plugins nobody vouched for. |
| `publr_zig` (`../lib/zig`) | Zig's compiler, built without LLVM, packed with its standard library and a prebuilt compiler_rt into the binary | Zig 0.16.0 | MIT | Building sandboxed plugins where no Zig is installed (`publr zig`). |
| `../publr-js/dist` | PublrJS, the client runtime behind the `data-p-*` wires, read by the build as-is | sibling checkout | Ours | The interactive half of the site's components. |
| `pjsx` (`../pjsx`) | Our own PJSX compiler and its render runtime; build-time, plus the runtime the generated views call | sibling checkout | Ours | The admin's pages, from `.ptsx` to Zig. |
| `publr_jit` (`../jit`) | Our own class-to-CSS compiler; build-time for the stylesheet, in the binary for class merging | sibling checkout | Ours | The admin's stylesheet, and stacked class attributes merged at render. |
| `../ui/src/components`, `../icons/icons` | The design system's PTSX components and the icon artwork, read by the build | sibling checkout | Ours | What the admin's pages are made of. |
| `vendor/stb/` | `stb_image.h`, `stb_image_resize2.h`, `stb_image_write.h` | 2c980bb | MIT / public domain | Decode, resize and encode images for media. |
| `vendor/libwebp/` | libwebp | 1.6.0 | BSD-3-Clause | WebP encoding for optimized media (the native build only). |

That is the whole list. Everything else in the binary is Zig, either the
standard library or code in this repository.

The `publr_*` entries are Publr's own libraries in a sibling checkout,
wired in as *path* dependencies in `build.zig.zon`: nothing is fetched, and a
fix lands in the library once, for every consumer. `src/lib/db.zig`,
`src/lib/http.zig`, `src/lib/auth.zig` and `src/lib/deps.zig` are this app's faces on them: the
PRAGMAs, the app type, the re-exports. The line for what goes into a library is
the one in the workspace README: a mechanism whose first example needs no Publr
noun. The C libraries that stay here (`vendor/stb`, `vendor/libwebp`)
each carry a `VERSION.zon` with the upstream, the archive name and its
SHA-256, and the list of files kept. They are compiled once into a static
library per target (`ReleaseFast`), which Zig's cache keeps between builds;
`zig build vendor-cache-check` proves a no-op build recompiles none of it.
See [Build](build.md) for the import procedure.

## Not dependencies

- **Zig itself**, pinned by `.zigversion`, builds Publr. The compiler inside the binary
  (`publr_zig`) is the same version, vendored as released, and only ever builds plugins.
  There is no package manager use:
  the only `build.zig.zon` dependencies are Publr's own libraries by path, no
  URLs, no lazy fetches.
- **`std`**: JSON, HTTP parsing helpers, crypto (Argon2id, SHA-256, HMAC),
  compression, all from the standard library.
- **Dev tools** on a machine (a browser for the local smoke test) are never
  part of the build and never in the repository.

## The decision tree

```mermaid
flowchart TD
    Need["Something not in Zig std"] --> Small{"A few hundred<br/>lines of Zig?"}
    Small -- yes --> Write["Write it ourselves"]
    Small -- no --> Critical{"Critical<br/>infrastructure?<br/>storage, crypto,<br/>image codecs"}
    Critical -- no --> Write2["Write it ourselves,<br/>even if bigger"]
    Critical -- yes --> C["Look for a C library"]
    C --> Amalg{"Single file or<br/>amalgamation?"}
    Amalg -- no --> Reject["Rejected:<br/>another approach,<br/>or write it"]
    Amalg -- yes --> Deps{"Zero transitive<br/>dependencies?"}
    Deps -- no --> Reject
    Deps -- yes --> License{"Public domain,<br/>MIT or BSD?"}
    License -- no --> Reject
    License -- yes --> Proven{"Battle tested?<br/>10+ years or<br/>industry wide"}
    Proven -- no --> Reject
    Proven -- yes --> Vendor["Vendor it as-is:<br/>vendor/, VERSION.zon,<br/>one line in the table"]
```

## Worked examples

| Need | Decision | Reasoning |
|---|---|---|
| JSON | `std.json` | Already there. |
| HTTP server | Written by us, as `publr_http` | Not critical infrastructure; a bounded parser and an event loop we want to own, and a second Publr program wanted the same one. |
| Password hashing, throttling, CSRF | Written by us over `std.crypto`, as `publr_auth` | The algorithms are `std`'s; the library is the fixed scratch budget, the dummy hash, the throttle table. |
| Session tokens | `std.crypto` (SHA-256, CSPRNG), in `store/sessions.zig` | Already there; the table is Publr's. |
| Database | SQLite, via `publr_sqlite` | Critical infrastructure; passes every gate. Lives in its own library because a second Publr program needed the same binding. |
| Image decode/resize | Vendor stb | Critical for media; single files, no dependencies. |
| WebP | Vendor libwebp | Critical for media optimisation; BSD, widely used. |
| Markdown | Write it | Not critical, small. |
| WebSocket | Write it, on top of our HTTP layer | Not critical, small. |
| YAML config | Rejected | JSON is enough. |
| libcurl, OpenSSL, libpng, zlib | Rejected | Dependencies of their own, or already covered by `std`/stb. |
| A UI framework, npm anything | Rejected | The UI is compiled to Zig from Publr's own sources; see the roadmap. |

## Replacing a dependency

Any vendored library may be replaced by a pure Zig implementation when the
Zig version passes the same tests and stays within reach of the C version's
speed. SQLite, stb and libwebp are the best available answer today, not
permanent decisions.
