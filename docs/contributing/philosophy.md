# Philosophy

Publr is a content platform built on a stubborn idea: **you should be able to
read the whole thing.** One binary, one database file, one language, a core
small enough to review in an afternoon. Everything below follows from that.

## Simplicity over complexity

Every feature costs twice: once to build, forever to understand. So the core
does the few things every site needs (content types, records, users, media, a
way in) and nothing else. Workflows, revisions, releases, environments,
notifications, activity logs: real needs, but not everyone's needs, so they
are plugins that sit on top of the same operations as everything else. A
plugin can be read on its own; the core stays readable without it.

When two designs do the job, Publr picks the one with fewer moving parts, even
when the other is more elegant on paper. Boring and obvious beats clever.

## Owning the stack

Publr is written in Zig, top to bottom: the HTTP server, the router, the
templates, the operations, the CLI, the build. There is no npm, no bundler,
no framework, no runtime, no package manager, no build-time network access.
`zig build` on a clean machine with one Zig binary produces one Publr binary,
today and in ten years.

Owning the stack is not pride, it is control: when something is slow, wrong or
insecure, the fix is in this repository, in a language and a style you already
know, with tests you can run in seconds. Nothing is "somebody else's problem".

## Hand-picked, ultra-limited dependencies

Three third-party libraries exist: SQLite for storage, stb for image decoding
and resizing, libwebp for WebP. Each is a mature, permissively licensed C
library with no dependencies of its own, vendored **as-is** under `vendor/`
with its version, upstream and archive checksum recorded next to it, compiled
once into a static library and never touched by hand. Anything else that is
tempting to pull in has to pass the decision tree in
[Dependencies](dependencies.md); most things fail it, and the answer becomes a
few hundred lines of Zig we own instead.

## Tiny, lean core: everything else is a plugin

The core is the smallest set of things every site needs and nothing more,
and it is held to that by review: each module is approved on its own, and
anything that can live outside the core does. Enterprise features, integrations,
workflows, even most of what looks "built in" are plugins that use exactly the
same SDK any third party would. That keeps two promises at once: the core
stays small enough to trust, and the plugin API stays honest, because Publr
itself is its heaviest user.

## Tiny core, one contract

Every capability, from creating a record to signing in, is an **operation**:
a name, an input, an output, one function. The admin UI, the CLI, the REST
API and plugins are adapters over that one table; permissions, transactions,
events and audit happen in one place, once. This is what keeps the core tiny:
adding a feature means adding an operation, and every surface gets it for
free, documented (see [Architecture](architecture.md), [SDK](../sdk.md)).

## Data, not code

Content types, fields, statuses and metadata are data in the database, not
types in the binary. Sites and plugins extend Publr at runtime; the binary
does not need to know your schema.

## Runs anywhere, exactly the same

Native it is one process on a port. In the browser it is the very same code
compiled to WebAssembly, behind a service worker, with the database in memory
and saved to the browser's storage. There is no "lite" mode and no second
implementation: one codebase, two targets, identical behaviour, proven by the
same test suite.

## Correct by construction

Rules that matter are enforced by the machine, not by review: `zig build
verify` runs the tests, compiles the WebAssembly target, checks formatting,
and applies the style rules (assertions in every function, bounded sizes, no
global state, no abbreviations, full control-flow shapes), then runs the real
binary end to end. If a rule can be checked mechanically, it is.

## Made for people and for agents

Everything is discoverable and documented at the source: `publr --help`,
`publr <namespace> --help`, `publr <namespace> <verb> --help` render the
same documentation the code carries, with runnable examples. A person new to
Publr and an automated agent driving it get the same, complete map.
