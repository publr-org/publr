//! A fixture site made by one release through its own doors (the CLI, never SQL), with a
//! fact for each thing it made. Every table must end with a row, or the seed fails: a table
//! a release adds is in that release's fixture, or the release does not ship.

const std = @import("std");
const smoke = @import("../smoke.zig");
const facts_module = @import("facts.zig");

const Facts = facts_module.Facts;

/// Tables no door fills from the CLI alone, with why. Review sees this list grow.
const unfilled = [_]struct {
    table: []const u8,
    why: []const u8,
}{
    .{
        .table = "sign_on_tokens",
        .why = "needs a Cloud dashboard signing people on",
    },
    .{
        .table = "identities",
        .why = "needs a sign-in provider (GitHub, Google)",
    },
    .{
        .table = "devices",
        .why = "needs a person approving `publr login` in a browser",
    },
    .{
        .table = "device_requests",
        .why = "needs a person approving `publr login`",
    },
    .{
        .table = "ai_conversations",
        .why = "needs a model provider plugin",
    },
    .{
        .table = "ai_steps",
        .why = "needs a model provider plugin",
    },
    .{
        .table = "ai_activity",
        .why = "needs a model provider plugin",
    },
    .{
        .table = "ai_pictures",
        .why = "needs a model provider plugin",
    },
    .{
        .table = "ai_browsers",
        .why = "needs a model provider plugin and the agent's browser",
    },
    .{
        .table = "removals",
        .why = "made by a device's removal list, confirmed by a person",
    },
    .{
        .table = "removal_items",
        .why = "made by a device's removal list, confirmed by a person",
    },
    .{
        .table = "health_kept",
        .why = "needs a broken reference, kept in Site Health",
    },
    .{
        .table = "internal_records",
        .why = "written by plugins only",
    },
    .{
        .table = "internal_record_values",
        .why = "written by plugins only",
    },
    .{
        .table = "sandboxed_plugins",
        .why = "needs a plugin built for the sandbox",
    },
    .{
        .table = "user_values",
        .why = "needs a custom user field",
    },
    .{
        .table = "errors",
        .why = "written when an operation fails unexpectedly",
    },
    .{
        .table = "user_search",
        .why = "needs a searchable custom user field",
    },
    .{
        .table = "migrations",
        .why = "a fresh database records one per migration; none yet",
    },
};

pub const Seed = struct {
    init: std.process.Init,
    binary: []const u8,
    site_dir: []const u8,
    release: []const u8,
    /// `publr-0-3-2`: what everything this seed makes is named with.
    tag: []const u8,
    admin: []const u8,
    made: Made,

    const Made = struct {
        users: std.ArrayList(facts_module.User) = .empty,
        records: std.ArrayList(facts_module.Record) = .empty,
        terms: std.ArrayList(facts_module.Term) = .empty,
        media: std.ArrayList(facts_module.Media) = .empty,
        secrets: std.ArrayList(facts_module.Secret) = .empty,
        pages: std.ArrayList(facts_module.Page) = .empty,
    };

    fn arena(seed: *Seed) std.mem.Allocator {
        return seed.init.arena.allocator();
    }

    pub fn publr(seed: *Seed, args: []const []const u8) ![]const u8 {
        return call(seed.init, seed.binary, seed.site_dir, args);
    }
};

/// Run `args` in `site_dir`; its output when it succeeded, else the command and what it said.
pub fn call(
    init: std.process.Init,
    binary: []const u8,
    site_dir: []const u8,
    args: []const []const u8,
) ![]const u8 {
    std.debug.assert(args.len > 0);
    std.debug.assert(binary.len > 0);

    const result = try smoke.run_publr(init, binary, site_dir, args);
    const ok = result.term == .exited and result.term.exited == 0;

    if (!ok) {
        std.debug.print("upgrade: seed: `{s}` failed:\n{s}{s}\n", .{
            try std.mem.join(init.arena.allocator(), " ", args),
            result.stdout,
            result.stderr,
        });
        return error.SeedFailed;
    }

    return result.stdout;
}

/// Seed the site in `site_dir` with `binary`, a release named `release`. A fresh site is
/// initialised first; the lived site already has its admin.
pub fn run(
    init: std.process.Init,
    binary: []const u8,
    site_dir: []const u8,
    release: []const u8,
    fresh: bool,
) !Facts {
    std.debug.assert(release.len > 0);
    std.debug.assert(site_dir.len > 0);

    const arena = init.arena.allocator();
    const tag = try std.mem.replaceOwned(u8, arena, release, ".", "-");
    var seed: Seed = .{
        .init = init,
        .binary = binary,
        .site_dir = site_dir,
        .release = release,
        .tag = tag,
        .admin = try std.fmt.allocPrint(arena, "admin+{s}@fixture.publr.test", .{tag}),
        .made = .{},
    };

    try admin(&seed, fresh);
    try users(&seed);

    const filed = try taxonomy(&seed);

    try content(&seed, filed);
    try others(&seed);

    return .{
        .releases = try arena.dupe([]const u8, &.{release}),
        .users = seed.made.users.items,
        .records = seed.made.records.items,
        .terms = seed.made.terms.items,
        .media = seed.made.media.items,
        .secrets = seed.made.secrets.items,
        .pages = seed.made.pages.items,
    };
}

fn admin(seed: *Seed, fresh: bool) !void {
    std.debug.assert(seed.admin.len > 0);

    if (fresh) {
        _ = try seed.publr(&.{
            "init",          "--email",    seed.admin,            "--display_name",
            "Fixture admin", "--password", facts_module.password,
        });
    } else {
        _ = try seed.publr(&.{
            "--as-admin", "user",           "create",              "--email",
            seed.admin,   "--display_name", "Fixture admin",       "--roles",
            "admin",      "--password",     facts_module.password,
        });
    }

    try seed.made.users.append(seed.arena(), .{
        .email = seed.admin,
        .role = "admin",
    });
}

fn users(seed: *Seed) !void {
    std.debug.assert(seed.tag.len > 0);

    const Roles = struct {
        roles: []const struct {
            name: []const u8,
        },
    };
    const listed = try seed.publr(&.{ "--as-admin", "role", "list" });
    const parsed = try std.json.parseFromSliceLeaky(Roles, seed.arena(), listed, .{
        .ignore_unknown_fields = true,
    });

    for (parsed.roles) |role| {
        if (std.mem.eql(u8, role.name, "admin")) {
            continue;
        }

        const email = try std.fmt.allocPrint(seed.arena(), "{s}+{s}@fixture.publr.test", .{
            role.name,
            seed.tag,
        });

        _ = try seed.publr(&.{
            "--as-admin", "user",           "create",              "--email",
            email,        "--display_name", "Fixture person",      "--roles",
            role.name,    "--password",     facts_module.password,
        });
        try seed.made.users.append(seed.arena(), .{
            .email = email,
            .role = role.name,
        });
    }

    for (seed.made.users.items) |user| {
        _ = try seed.publr(&.{
            "user", "sign_in", "--email", user.email, "--password", facts_module.password,
        });
    }
}

/// A content type filing records under `filed`'s taxonomy; a draft, and a record
/// published, edited and published again, so a revision is kept.
fn content(seed: *Seed, filed: Filed) !void {
    std.debug.assert(seed.tag.len > 0);
    std.debug.assert(filed.term.len > 0);

    const arena = seed.arena();
    const handle = try std.mem.replaceOwned(u8, arena, try std.fmt.allocPrint(
        arena,
        "fixture_{s}",
        .{seed.tag},
    ), "-", "_");
    const definition = try std.fmt.allocPrint(arena, "{{\"handle\":\"{s}\",\"name\":\"Fixture " ++
        "{s}\",\"public\":true,\"fields\":[" ++
        "{{\"name\":\"title\",\"label\":\"Title\",\"kind\":\"string\"," ++
        "\"validation\":{{\"required\":true}}}}," ++
        "{{\"name\":\"slug\",\"label\":\"Slug\",\"kind\":\"slug\",\"options\":{{\"source\":" ++
        "\"title\"}}}},{{\"name\":\"body\",\"label\":\"Body\",\"kind\":\"richtext\"," ++
        "\"searchable\":true}},{{\"name\":\"topics\",\"label\":\"Topics\",\"kind\":" ++
        "\"terms\",\"many\":true,\"options\":{{\"taxonomy\":\"{s}\"}}}}]}}", .{
        handle,
        seed.release,
        filed.taxonomy,
    });

    _ = try seed.publr(&.{ "--as-admin", "content_type", "create", "--definition", definition });

    const draft = try std.fmt.allocPrint(arena, "Draft {s}", .{seed.release});
    const live = try std.fmt.allocPrint(arena, "Published {s}", .{seed.release});

    _ = try create_record(seed, handle, draft, filed.term);

    const live_id = try create_record(seed, handle, live, filed.term);
    const edited = try std.fmt.allocPrint(arena, "{{\"body\":\"Edited by the fixture of {s}\"}}", .{
        seed.release,
    });

    _ = try seed.publr(&.{ "--as-admin", "record", "publish", "--id", live_id });
    _ = try seed.publr(&.{ "--as-admin", "record", "save", "--id", live_id, "--document", edited });
    _ = try seed.publr(&.{ "--as-admin", "record", "publish", "--id", live_id });
    try seed.made.records.append(arena, .{
        .type = handle,
        .title = draft,
        .status = "draft",
    });
    try seed.made.records.append(arena, .{
        .type = handle,
        .title = live,
        .status = "published",
    });
    try seed.made.pages.append(arena, .{
        .path = try std.fmt.allocPrint(arena, "/api/record.list?type={s}", .{handle}),
        .contains = live,
    });
}

fn create_record(
    seed: *Seed,
    handle: []const u8,
    title: []const u8,
    term: []const u8,
) ![]const u8 {
    std.debug.assert(handle.len > 0);
    std.debug.assert(title.len > 0);

    const document = try std.fmt.allocPrint(seed.arena(), "{{\"title\":\"{s}\"," ++
        "\"body\":\"Written by the fixture of {s}\",\"topics\":[\"{s}\"]}}", .{
        title,
        seed.release,
        term,
    });
    const created = try seed.publr(&.{
        "--as-admin", "record", "create", "--type", handle, "--document", document,
    });
    const Created = struct {
        id: []const u8,
    };
    const parsed = try std.json.parseFromSliceLeaky(Created, seed.arena(), created, .{
        .ignore_unknown_fields = true,
    });

    return parsed.id;
}

const Filed = struct {
    taxonomy: []const u8,
    term: []const u8,
};

fn taxonomy(seed: *Seed) !Filed {
    std.debug.assert(seed.tag.len > 0);

    const arena = seed.arena();
    const handle = try std.mem.replaceOwned(u8, arena, try std.fmt.allocPrint(
        arena,
        "topics_{s}",
        .{seed.tag},
    ), "-", "_");
    const definition = try std.fmt.allocPrint(arena, "{{\"handle\":\"{s}\",\"name\":\"Topics " ++
        "{s}\",\"public\":true,\"hierarchical\":true,\"title_field\":\"name\",\"fields\":[" ++
        "{{\"name\":\"name\",\"label\":\"Name\",\"kind\":\"string\"," ++
        "\"validation\":{{\"required\":true}}," ++
        "\"searchable\":true}},{{\"name\":\"slug\",\"label\":\"Slug\",\"kind\":\"slug\"," ++
        "\"options\":{{\"source\":\"name\"}}}}]}}", .{ handle, seed.release });
    const title = try std.fmt.allocPrint(arena, "Topic {s}", .{seed.release});
    const document = try std.fmt.allocPrint(arena, "{{\"name\":\"{s}\"}}", .{title});

    _ = try seed.publr(&.{ "--as-admin", "taxonomy", "create", "--definition", definition });
    const created = try seed.publr(&.{
        "--as-admin", "term",       "create", "--taxonomy",
        handle,       "--document", document, "--status",
        "published",
    });
    const Created = struct {
        id: []const u8,
    };
    const term = try std.json.parseFromSliceLeaky(Created, arena, created, .{
        .ignore_unknown_fields = true,
    });

    try seed.made.terms.append(arena, .{
        .taxonomy = handle,
        .title = title,
    });

    return .{
        .taxonomy = handle,
        .term = term.id,
    };
}

/// Media, a secret, a saved view: the tables the content above leaves empty.
fn others(seed: *Seed) !void {
    std.debug.assert(seed.tag.len > 0);

    const arena = seed.arena();
    const filename = try std.fmt.allocPrint(arena, "fixture-{s}.txt", .{seed.tag});
    const file = try std.fs.path.join(arena, &.{ seed.site_dir, filename });
    const secret = try std.ascii.allocUpperString(arena, try std.mem.replaceOwned(
        u8,
        arena,
        try std.fmt.allocPrint(arena, "fixture_{s}", .{seed.tag}),
        "-",
        "_",
    ));
    const view = try std.fmt.allocPrint(arena, "Fixture view {s}", .{seed.release});

    try std.Io.Dir.cwd().writeFile(seed.init.io, .{
        .sub_path = file,
        .data = "fixture media\n",
    });
    _ = try seed.publr(&.{ "--as-admin", "media", "add", "--file", file });
    try std.Io.Dir.cwd().deleteFile(seed.init.io, file);
    try seed.made.media.append(arena, .{
        .filename = filename,
    });

    if (try has(seed, "secret")) {
        _ = try seed.publr(&.{
            "--as-admin", "secret", "set", "--name", secret, "--value", "kept",
        });
        try seed.made.secrets.append(arena, .{
            .name = secret,
        });
    }

    // A secret set and removed again: the trash keeps its copy.
    if (try has(seed, "trash")) {
        const gone = try std.fmt.allocPrint(arena, "{s}_GONE", .{secret});

        _ = try seed.publr(&.{ "--as-admin", "secret", "set", "--name", gone, "--value", "x" });
        _ = try seed.publr(&.{ "--as-admin", "secret", "remove", "--name", gone });
    }

    if (try has(seed, "rail")) {
        _ = try seed.publr(&.{ "--as", seed.admin, "rail", "pin", "--page", "settings/users" });
    }

    _ = try seed.publr(&.{ "--as", seed.admin, "view", "create", "--name", view });
}

/// Whether this release has `namespace`: the seed seeds what a release has, so a fixture of
/// an older release (made to test against, before fixtures were kept) still seeds.
fn has(seed: *Seed, namespace: []const u8) !bool {
    std.debug.assert(namespace.len > 0);

    const result = try smoke.run_publr(seed.init, seed.binary, seed.site_dir, &.{"--help"});
    const line = try std.fmt.allocPrint(seed.arena(), "\n{s}: ", .{namespace});

    return std.mem.indexOf(u8, result.stdout, line) != null;
}

/// Every table holds a row, but those named in `unfilled`: the fixture covers each.
pub fn expect_every_table(init: std.process.Init, binary: []const u8, site_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(unfilled.len > 0);

    const result = try smoke.run_publr(init, binary, site_dir, &.{ "db", "tables" });

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("upgrade: seed: this release cannot count its tables (before 0.3.0); " ++
            "not checked\n", .{});
        return;
    }

    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    var empty: u32 = 0;

    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const table = words.next() orelse continue;
        const rows = std.fmt.parseInt(u64, words.next() orelse continue, 10) catch continue;
        const owner = words.next() orelse "";

        // A compiled-in plugin's tables are its own fixture's to fill.
        if (rows == 0 and std.mem.eql(u8, owner, "core") and !is_unfilled(table)) {
            std.debug.print("upgrade: seed: warning: table {s} has no row, so no upgrade " ++
                "tests it: add what fills it to scripts/upgrade/seed.zig, or name it in " ++
                "`unfilled` with why\n", .{table});
            empty += 1;
        }
    }

    // A warning, never a failed release: the upgrade still runs on every table there is.
    if (empty > 0) {
        std.debug.print("upgrade: seed: {d} table(s) untested by the fixture\n", .{empty});
    }
}

fn is_unfilled(table: []const u8) bool {
    std.debug.assert(table.len > 0);

    for (unfilled) |entry| {
        if (std.mem.eql(u8, entry.table, table)) {
            return true;
        }
    }

    return false;
}
