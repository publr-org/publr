# Changing Publr safely for updates

What a change to Publr must do so every site updates. What an update does for the people
who run a site is in [Updates](../updates.md).

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

Upgrade tests start at the release `fixtures/upgrade/START` names: 0.7.5, whose
`schema.sql` is the baseline of core's migrations (`baseline` in
`src/lib/db/migrations.zig`). From it on, every release attaches its upgrade site to its
GitHub release (`upgrade-<version>.tar.gz`): a site its own binary seeded through the CLI,
every table filled, with `facts.json` saying what it made. It also attaches
`upgrade-lived.tar.gz`, one site every release has opened and seeded on. The sites are release
assets, never files in the repository; CI fetches them into `.zig-cache/upgrade-sites/`.
`zig build upgrade` (part of `verify-full` and CI) updates every one with the current build
and checks the shape, every fact, the site served, a write, and that the gate's backup puts
it back; `-Dupgrade-previous=<publr>` also checks the release before runs on the result, when that
release is the start release or later.
Released migrations are compared with their tags and may never change. The Release workflow
makes the new site with the release binary; its notes are the changelog.

**A release is Latest as soon as it is published.** Publr releases stand on their own: Cloud
runs them when its own release moves to them. Tools that must not get ahead of Cloud (the
`publr` command and Desktop, for new sites and for updating sites on a computer) follow the
release Cloud runs, which they ask Cloud for.

**The workflow names the release's migration.** It renames `unreleased.zig` to
`<version>.zig` and gives its entry in `src/lib/db/migrations.zig` the version as its name,
so a released binary never records a migration as `unreleased`. It fails when an entry is
still named `unreleased` and there is no `unreleased.zig`.
