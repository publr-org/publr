//! Updating this site's Publr to a newer release, and stepping back: what the last update did,
//! the releases there are, starting one and rolling back.
const operation = @import("../operation.zig");
const release = @import("../model/release.zig");
const heartbeat = @import("heartbeat.zig");

pub const namespace: operation.Namespace = .{
    .name = "update",
    .label = "Updates",
    .area = .system,
    .summary = "Updating this site's Publr to a newer release, and stepping back",
    .details =
    \\Administrators only, on a running server. An update downloads the release for this
    \\machine, checks it against the checksums Publr signed, rehearses it on a copy of the
    \\database, backs the whole site up, swaps the binary and restarts in place; if the new
    \\release cannot start, the old one comes back by itself. A patch only swaps the binary,
    \\a minor runs a migration that only adds, a major may change what plugins and apps
    \\rely on: read its notes first. Where Publr Cloud runs the site, it keeps Publr up to
    \\date and nothing here starts an update.
    ,
};

pub const managed_failure: operation.Failure = .{
    .name = "Managed",
    .status = 409,
    .message = "Publr Cloud keeps this site's Publr up to date",
};

pub const not_started: operation.Failure = .{
    .name = "NotStarted",
    .status = 409,
    .message = "The update could not start; `publr update status` says why",
};

pub const unreachable_failure: operation.Failure = .{
    .name = "Unreachable",
    .status = 502,
    .message = "Publr's releases could not be reached",
};

pub const Status = struct {
    pub const name = "update.status";
    pub const description = "This site's Publr, and what the last update did";
    pub const details =
        \\Nothing is changed. `step` is `idle`, or the step an update is on (`downloading`,
        \\`verifying`, `rehearsing`, `swapping`, `restarting`), then `done` or `failed` with
        \\a `message`. `previous` names the release kept to roll back to.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        version: []const u8,
        managed: bool,
        step: []const u8,
        target: []const u8,
        message: []const u8,
        previous: ?[]const u8,
        backups: []const release.UpdateBackup,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .version = heartbeat.version,
        .managed = false,
        .step = "idle",
        .target = "",
        .message = "",
        .previous = null,
        .backups = &.{},
    };
    pub const output_docs: operation.Docs(Out) = .{
        .version = "The release running",
        .managed = "Whether Publr Cloud keeps it up to date",
        .step = "idle, the step an update is on, or done / failed",
        .target = "The release the last update went to",
        .message = "What the last update did, or why it failed",
        .previous = "The release kept to roll back to; null when there is none",
        .backups = "The backups taken before updates, newest first: name, from, to, at_ms; " ++
            "`publr restore <name>` puts one back",
    };
};

pub const Check = struct {
    pub const name = "update.check";
    pub const description = "List the releases newer than this one, with what each would do";
    pub const details =
        \\Answers what the last look at GitHub, where Publr publishes its releases, found, and
        \\starts a new look in the background when that one is over a minute old: while
        \\`looking`, ask again for what it finds. Each release comes with its kind against
        \\this release (patch, minor, major) and its notes. Nothing is changed.
    ;
    pub const kind: operation.Kind = .read;
    pub const failures = [_]operation.Failure{unreachable_failure};
    pub const In = struct {};
    pub const Out = struct {
        version: []const u8,
        managed: bool,
        releases: []const release.Release,
        looking: bool,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .version = heartbeat.version,
        .managed = false,
        .releases = &.{.{
            .version = "0.4.0",
            .kind = .minor,
            .notes = "Saved views can be pinned.",
            .published_at = "2026-11-02T10:00:00Z",
            .url = "https://github.com/publr-org/publr/releases/tag/v0.4.0",
        }},
        .looking = false,
    };
    pub const output_docs: operation.Docs(Out) = .{
        .version = "The release running",
        .managed = "Whether Publr Cloud keeps it up to date",
        .releases = "Newer releases, newest first: version, kind, notes, published_at, url",
        .looking = "A look for newer releases is on its way: ask again for what it finds",
    };
};

pub const Apply = struct {
    pub const name = "update.apply";
    pub const description = "Update this site's Publr to a newer release";
    pub const details =
        \\Starts the update and answers at once; `update status` follows it. The site is
        \\backed up first, and if the new release cannot start, this one comes back. A
        \\major release may change what plugins and apps rely on: read its notes first.
    ;
    pub const kind: operation.Kind = .write;
    pub const failures = [_]operation.Failure{ managed_failure, not_started };
    pub const In = struct {
        version: []const u8,
    };
    pub const Out = struct {
        started: bool,
        kind: release.Kind,
    };
    pub const example: In = .{
        .version = "0.4.0",
    };
    pub const example_out: Out = .{
        .started = true,
        .kind = .minor,
    };
    pub const field_docs: operation.Docs(In) = .{
        .version = "The release to update to, newer than this one (`update check` lists them)",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .started = "The update is on its way",
        .kind = "patch, minor or major, against this release",
    };
};

pub const Rollback = struct {
    pub const name = "update.rollback";
    pub const description = "Go back to the release this one replaced";
    pub const details =
        \\Starts at once; `update status` follows it. Swaps the kept binary back and restarts.
        \\The data stays as it is, which the release before can run on, unless this release's
        \\migration was one-way (only a major's can be): then the backup taken before the
        \\update is put back, and what was written since is lost.
    ;
    pub const kind: operation.Kind = .write;
    pub const failures = [_]operation.Failure{ managed_failure, not_started };
    pub const In = struct {};
    pub const Out = struct {
        started: bool,
        to: []const u8,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .started = true,
        .to = "0.3.2",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .started = "The step back is on its way",
        .to = "The release it goes back to",
    };
};
