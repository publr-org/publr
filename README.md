# Publr

**The content platform that fits in one file.**

Publr is an agentic-first CMS: a complete content platform compiled into a
single small binary that runs anywhere, natively on a server or entirely
inside your browser, and is as easy for an automated agent to drive as for a
person.

- **Everything you expect**: content types with every field type, records,
  media, users and roles, a visual editor when you want one.
- **One contract**: every capability is an operation; the admin, the CLI, the
  REST API and plugins all use the same ones, with permissions decided once.
- **Tiny core, plugins for the rest**: workflows, revisions, releases,
  integrations and other enterprise features are plugins on the same SDK.
- **Owned top to bottom**: pure Zig, three vendored libraries, one SQLite
  file, no npm, no frameworks. `zig build` and you have it.
- **Runs in the browser**: the same binary as WebAssembly, no server at all.

Status: **v0.2, pre-release.** Nothing is stable yet.

## Install

One binary. The installer detects your OS and CPU, downloads the matching
build, verifies its checksum and puts `publr` on your PATH:

```
curl -fsSL https://publr.dev/install.sh | sh
```

If you would rather not pipe a script into your shell, fetch it, check it
against the hash published here, and only then run it:

```
curl -fsSL https://raw.githubusercontent.com/publr-org/publr/v0.2.0/install.sh -o install.sh
echo "<sha256 of install.sh, published with each release>  install.sh" | shasum -a 256 -c -
sh install.sh
```

Or pick a build by hand from the [releases page](https://github.com/publr-org/publr/releases)
(macOS and Linux, Apple Silicon and x86_64). Every build ships with its
SHA-256 next to it, and the installer refuses a mismatch.

## Run it

```
publr serve                                  # http://127.0.0.1:8080
publr init --email you@example.com --display_name You   # first admin; the password is generated and shown once
publr build                                  # the public site as files, into ./output (served by `serve`)
publr --help                                 # every command; publr <namespace> <verb> --help for details
```

The database lives in `data/publr.db` next to where you run it (`--db <path>`
to choose another).

## Develop

Requires Zig 0.16.0.

```
zig build run -- serve             # build and serve natively
zig build run -- serve --browser   # the same, running in your browser tab (after: zig build browser)
zig build test                     # tests
zig build verify                   # tests + wasm check + formatting + tidy rules + smoke; run before calling anything done
```

## Docs

- [Philosophy](docs/philosophy.md): why Publr is shaped the way it is.
- [Architecture](docs/architecture.md): how Publr works, in plain terms.
- [Content](docs/content.md): types, records, documents, statuses, media.
- [Admin](docs/admin.md): the plain HTML admin at `/admin`.
- [The site](docs/site.md): themes, `.publr` templates, islands, the static build.
- [Streaming islands](docs/streaming.md): a proposal for islands in the page's own response, and hosting it anywhere.
- [Authentication](docs/auth.md): accounts, sessions, passwords, setup.
- [SDK](docs/sdk.md): the plugin surface: operations, hooks, UI.
- [Plugins](docs/plugins.md): compiled-in plugins and runtime (WebAssembly) plugins.
- [CLI reference](docs/cli.md): flags and every command, one page per namespace.
- [REST API](docs/rest.md): the server and the `/api/` routes.
- [Publr in the browser](docs/browser.md): the same binary as WebAssembly, no server.
- [Database schema](docs/schema.md): every table, column and index, and why.
- [Dependencies](docs/dependencies.md): the three libraries, and the decision tree for any more.
- [Build reference](docs/build.md): every build step and rule.
