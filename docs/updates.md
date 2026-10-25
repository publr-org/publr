# Updates

A site made by any Publr release since 0.3.0 updates to any later one, skipping as many
releases as it likes. Every update backs the whole site up first. This page says what an
update does, how to run one, and what a change to Publr must do to keep that true. The
reasoning is in `.agents/specs/updates.md` and `upgrade-testing.md`.

## What the version says

| Kind | Example | What it does to a site |
|---|---|---|
| Patch | 0.4.2 → 0.4.3 | Nothing to the data: the database's shape is 0.4.0's. Updating swaps the binary; going back swaps it again. |
| Minor | 0.4.x → 0.5.0 | Runs one migration that only adds (tables, columns that may be empty or have a default, indexes, data filled in). The release before still runs on the result, so going back is a swap too. |
| Major | 0.x → 1.0 | Something plugins, apps or scripts rely on was removed after six months deprecated, or the database changed in a way that cannot be undone by swapping the binary (a drop, a rename, data rewritten). Going back after one puts the backup back. |

## Opening a site

Every command and `serve` open the database through one gate before anything reads it:

- **A new database** is made from `schema.sql`, and every migration the release knows is
  recorded as done.
- **The same release as last time**, nothing to make: the shape is compared with what this
  release expects, and it goes on.
- **Another release opened it last**, or a migration is due, or a table is missing: the
  whole site is backed up, then, in one transaction, the migrations run, missing tables
  are made, and the shape, the references, the file's integrity and a write of each kind
  (a user per role, a record per type, a term per taxonomy, all rolled back) are checked.
  Any failure rolls it all back and refuses to start, saying why. Otherwise the release is
  recorded and `publr.updated` goes into the activity log.
- **A newer release migrated it**: this one runs on it if that was one minor's migration
  that only added. Otherwise it refuses, naming the release and the backup to put back.
- **Made before 0.3.0**, when releases did not record themselves: tables that drifted from
  `schema.sql` are rebuilt to it, their rows kept, once.

`publr db check` says what the gate would find without opening it: the release that last
opened the database, the migrations to run, and every way the shape differs, each one
`fine` or `refused`. `publr db tables` counts every table's rows.

## Backups

Before every update the whole site is copied to `<data>/backups/<time>-<from>-to-<to>/`:
the database (a consistent copy, while others read), the media library (hard-linked, which
costs no space, since a media file is never rewritten in place), installed plugins,
`apps/`, `plugins/` and `publr.zon`. The last three are kept. `publr backups` lists them;
`publr restore <name>` puts one back once `serve` is stopped, after keeping the site as it
is in a backup of its own.

## Updating a self-hosted Publr

Settings › Updates shows the release running and checks for newer ones, each with its
kind and what it means. Update starts it; the page follows it to the restart:

1. **Downloading** the release for this machine from GitHub.
2. **Verifying**: `SHA256SUMS` must carry Publr's signature (Ed25519; the public key is in
   the binary) and list the binary's SHA-256. A checksum from the same page alone proves
   nothing.
3. **Rehearsing**: the new release opens a copy of the database, migrations and checks
   included. A refusal ends the update; the site never changed.
4. **Swapping**: the binary goes in place of this one, which is kept beside it as
   `publr.previous`.
5. **Restarting**: `serve` stops, lets go of everything, and becomes the new binary with the
   same arguments. Its gate backs the site up and migrates it.

If the new release cannot open the site, it puts the one it replaced back and runs that
instead; the page says it failed and why. Go back to the previous release from the same
page, or `publr --as-admin update rollback`. The same steps run from the CLI:
`publr --as-admin update check`, `update apply --version 0.4.0`, `update status`
([`update`](cli/update.md)). `serve --auto-update patch` looks once a day for a newer patch
of the running minor and applies it the same way; minor and major releases are a person's
decision.

The binary must be writable by the user `serve` runs as. `PUBLR_RELEASES_URL` and
`PUBLR_RELEASES_API` point the downloads and the release list at a mirror; the signature is
checked wherever they come from.

## On Publr Cloud

`PUBLR_UPDATES=managed`: Publr Cloud keeps the site's Publr up to date, and Settings ›
Updates says so instead of offering updates. Cloud rehearses each release, backs each
project's data up before moving it, moves projects one at a time, and holds any that fail
on the release before.

## Changing Publr

**A change to the database's shape is a migration.** Write it in
`src/lib/db/migrations/unreleased.zig` (`zig build migration-draft` starts one from the
schema's changes since the last release) and list it in `src/lib/db/migrations.zig`. A
migration:

- says everything itself in SQL and plain Zig: never `schema.sql`, never today's code, so it
  does the same when a release years later runs it;
- checks before it acts (`db.schema.has_column`), so it may run again: while unreleased, a
  development database runs it again whenever the file changes;
- declares `pub const one_way = true` when it drops, renames, retypes or rewrites; only a
  major may ship one, and data people made is exported first;
- never changes once released, and is never removed.

A compiled-in plugin keeps its own in its folder and lists them as
`pub const migrations = [_]publr.db.migration.Migration{ .of("<name>", ...) }`.

**Readers are tolerant.** Code reading rows, documents and stored JSON ignores what it does
not know and fills in what is missing with its default, so a release runs on a database the
next one added to.

**Removing something people build on takes a deprecation first.** An operation declares
`pub const deprecated: publr.sdk.operation.Deprecated = .{ .since = "0.4.0", .instead = "..." }`:
it keeps working; `--help` says so; the CLI prints it on every call; REST answers with a
`Deprecation` header; the server logs who called it. A major removes it six months later at
the earliest.

**The Release button checks the kind.** A patch with a migration, or a minor whose
migration is one-way, is refused; a schema change with no migration is refused; a minor
without a migration is allowed and flagged.

## Upgrade tests

Upgrade tests have not started yet: until `fixtures/upgrade/START` names the release they
start from, no release has an upgrade site, `zig build upgrade` checks nothing, and a release
may change stored data freely. From that release on, every release attaches its upgrade site
to its GitHub release (`upgrade-<version>.tar.gz`): a site its own binary seeded through the
CLI, every table filled, with `facts.json` saying what it made. It also attaches
`upgrade-lived.tar.gz`, one site every release has opened and seeded on. The sites are release
assets, never files in the repository; CI fetches them into `.zig-cache/upgrade-sites/`.
`zig build upgrade` (part of `verify-full` and CI) updates every one with the current build
and checks the shape, every fact, the site served, a write, and that the gate's backup puts
it back; `-Dupgrade-previous=<publr>` also checks the release before runs on the result.
Released migrations are compared with their tags and may never change. The Release workflow
makes the new site with the release binary and puts the table of results in the release
notes.
