//! Every file under `src/` is one kind of thing, and its directory says which. This check
//! keeps the kinds apart: pure rules never see a database, stores never see the SDK,
//! operations never write SQL, adapters never reach into stores (except the two that turn
//! a cookie or a `--as` flag into a caller).

const std = @import("std");

const Rule = struct {
    /// The directory (as a path prefix inside `src/`) the rule applies to.
    prefix: []const u8,
    /// Import path fragments that must not appear.
    banned_imports: []const []const u8 = &.{},
    /// Whether SQL string literals are banned.
    no_sql: bool = false,
    /// Files (by suffix) the rule skips.
    exceptions: []const []const u8 = &.{},
    what: []const u8,
};

const rules = [_]Rule{
    .{
        .prefix = "model",
        .banned_imports = &.{
            "/db/",   "/store/", "/sdk/",    "/operations/", "/http/",
            "/rest/", "/admin/", "/plugin/", "registry.zig",
        },
        .no_sql = true,
        .what = "model is pure: data in, data out",
    },
    .{
        .prefix = "store",
        .banned_imports = &.{
            "/sdk/",   "/operations/", "/http/",       "/rest/",
            "/admin/", "/plugin/",     "registry.zig",
        },
        .what = "store is SQL only: it knows tables, not operations",
    },
    .{
        .prefix = "operations",
        .no_sql = true,
        .what = "operations orchestrate: SQL belongs in store/",
    },
    .{
        .prefix = "adapters/admin",
        .banned_imports = &.{"/store/"},
        .no_sql = true,
        .what = "an adapter calls operations, never the store",
    },
    .{
        .prefix = "adapters/cli",
        .banned_imports = &.{"/store/"},
        .no_sql = true,
        .exceptions = &.{"adapters/cli.zig"},
        .what = "an adapter calls operations, never the store",
    },
    .{
        .prefix = "adapters/site",
        .banned_imports = &.{"/store/"},
        .no_sql = true,
        .what = "an adapter calls operations, never the store",
    },
    .{
        .prefix = "adapters/rest",
        .banned_imports = &.{"/store/"},
        .no_sql = true,
        .exceptions = &.{"adapters/rest/identity.zig"},
        .what = "an adapter calls operations, never the store",
    },
};

const sql_markers = [_][]const u8{
    "\"SELECT ", "\"INSERT ", "\"UPDATE ", "\"DELETE ", "\"PRAGMA ", "\"CREATE ",
};

pub fn check(text: []const u8, path: []const u8, hint: []const u8, report: bool) u32 {
    std.debug.assert(path.len > 0);
    std.debug.assert(rules.len > 0);

    const rule = rule_for(path) orelse return 0;
    var violations: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: u32 = 1;

    while (lines.next()) |line| : (line_no += 1) {
        const problem = offence(rule, line) orelse continue;

        violations += 1;

        if (report) {
            std.debug.print("{s}:{d}: {s} ({s}){s}\n", .{
                path,
                line_no,
                problem,
                rule.what,
                hint,
            });
        }
    }

    return violations;
}

fn rule_for(path: []const u8) ?*const Rule {
    std.debug.assert(path.len > 0);
    std.debug.assert(rules.len < 16);

    for (&rules) |*rule| {
        const at = std.mem.indexOf(u8, path, rule.prefix) orelse continue;
        const starts_segment = at == 0 or path[at - 1] == '/';

        if (!starts_segment) {
            continue;
        }

        for (rule.exceptions) |exception| {
            if (std.mem.endsWith(u8, path, exception)) {
                return null;
            }
        }

        return rule;
    }

    return null;
}

fn offence(rule: *const Rule, line: []const u8) ?[]const u8 {
    std.debug.assert(rule.prefix.len > 0);
    std.debug.assert(line.len <= 1 << 16);

    if (std.mem.indexOf(u8, line, "@import(\"") != null) {
        for (rule.banned_imports) |banned| {
            if (std.mem.indexOf(u8, line, banned) != null) {
                return "import across kinds";
            }
        }
    }

    if (rule.no_sql) {
        for (sql_markers) |marker| {
            if (std.mem.indexOf(u8, line, marker) != null) {
                return "SQL outside store/";
            }
        }
    }

    return null;
}

test "kinds: model may not import the store, operations may not write SQL, stores may" {
    const bad_model = "const store = @import(\"../store/store.zig\");\n";
    try std.testing.expectEqual(@as(u32, 1), check(bad_model, "src/model/x.zig", "", false));
    try std.testing.expectEqual(@as(u32, 0), check(bad_model, "src/operations/x.zig", "", false));

    const sql = "    var select = try connection.prepare(\"SELECT 1\");\n";
    try std.testing.expectEqual(@as(u32, 1), check(sql, "src/operations/x.zig", "", false));
    try std.testing.expectEqual(@as(u32, 0), check(sql, "src/store/x.zig", "", false));

    const identify = "const users = @import(\"../store/users.zig\");\n";
    const identity_path = "src/adapters/rest/identity.zig";
    const adapter_path = "src/adapters/rest.zig";
    try std.testing.expectEqual(@as(u32, 0), check(identify, identity_path, "", false));
    try std.testing.expectEqual(@as(u32, 1), check(identify, adapter_path, "", false));
}
