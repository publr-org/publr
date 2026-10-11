const std = @import("std");
const sdk = @import("../sdk.zig");
const trash = @import("trash.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const environment = @import("../lib/environment.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const secrets = model.secrets;
const kept = store.secrets;

pub const namespace: sdk.operation.Namespace = .{
    .name = "secret",
    .summary = "Secrets plugins name but never hold: API keys, set by an administrator",
    .details =
    \\A plugin asks for `secret.<NAME>` (a high-tier permission) and writes `{secret:NAME}`
    \\where the value goes in a request it sends out; the value is filled in as the request
    \\leaves, so the plugin never sees it. A value comes from the environment variable of
    \\the same name when one is set, else from what an administrator set here, kept sealed
    \\with the project's key: `PUBLR_SECRET_KEY`, else `secret.key` beside the database.
    \\A value is never answered back. Administrators only.
    ,
};

pub const operations = [_]type{ List, Set, Remove };

/// Where the project's key is: `PUBLR_SECRET_KEY`.
pub const key_variable = "PUBLR_SECRET_KEY";
const key_file = "secret.key";

pub const Listed = struct {
    name: []const u8,
    /// `environment` (the variable wins), `kept` (set here), or `missing`.
    source: []const u8,
    /// The plugins that asked for it.
    used_by: []const []const u8,
    updated_at: i64,
};

const example_listed: Listed = .{
    .name = "STOCKS_API_KEY",
    .source = "kept",
    .used_by = &.{},
    .updated_at = 1789650000000,
};

pub const List = struct {
    pub const name = "secret.list";
    pub const description = "List the secrets: those plugins asked for and those set";
    pub const details =
        \\Each with where its value comes from (`environment`, `kept` or `missing`) and the
        \\plugins that asked for it; never a value. `key` says where the project's key is:
        \\`environment`, `file`, or `none` until a secret is first set.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        secrets: []const Listed,
        key: []const u8,
        total: u32 = 0,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .limit = "How many at most; 50 when omitted, up to 200",
        .offset = "How many to pass over first: the set ones by name, then the asked-for",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .secrets = &.{example_listed},
        .key = "file",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.limit == 0 or in.limit > sdk.operation.page_limit_max) {
            return error.Invalid;
        }

        // The set ones by name, then the ones plugins asked for that are not set yet.
        const set_count = try kept.count(ctx.db);
        const missing = try asked_missing(ctx);
        var listed: std.ArrayList(Listed) = .empty;

        if (in.offset < set_count) {
            for (try kept.names_page(ctx.db, ctx.arena, in.offset, in.limit)) |row| {
                try listed.append(ctx.arena, try listed_of(ctx, row.name, true, row.updated_at));
            }
        }

        const missing_from = in.offset -| set_count;
        const room = in.limit - @as(u32, @intCast(listed.items.len));

        if (missing_from < missing.len and room > 0) {
            const end = @min(missing.len, missing_from + room);

            for (missing[missing_from..end]) |secret_name| {
                try listed.append(ctx.arena, try listed_of(ctx, secret_name, false, 0));
            }
        }

        std.debug.assert(listed.items.len <= in.limit);

        return .{
            .secrets = listed.items,
            .key = try key_source(ctx),
            .total = set_count + @as(u32, @intCast(missing.len)),
        };
    }
};

pub const Set = struct {
    pub const name = "secret.set";
    pub const description = "Set a secret's value, replacing any";
    pub const details =
        \\Kept sealed with the project's key, made beside the database the first time when
        \\`PUBLR_SECRET_KEY` is not set. An environment variable of the same name still wins.
        \\The value is up to 8 KiB and never shown again.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const secret = .{"value"};
    pub const In = struct {
        name: []const u8,
        value: []const u8,
    };
    pub const Out = Listed;
    pub const example: In = .{
        .name = "STOCKS_API_KEY",
        .value = "sk-example",
    };
    pub const example_out: Out = .{
        .name = "STOCKS_API_KEY",
        .source = "kept",
        .used_by = &.{},
        .updated_at = 1789650000000,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "Capitals, digits and underscores: STOCKS_API_KEY",
        .value = "The value; never shown again",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const value = std.mem.trim(u8, in.value, " \t\r\n");

        if (!secrets.valid_name(in.name) or value.len == 0 or value.len > secrets.value_len_max) {
            return error.Invalid;
        }

        const key = try key_of(ctx, .make) orelse return ctx.fail(no_key);
        const sealed = secrets.seal(ctx.arena, ctx.io, key, in.name, value) catch {
            return error.OutOfMemory;
        };

        try kept.put(ctx.db, in.name, sealed, ctx.now_ms);
        ctx.notice("secret.set", in.name);

        return .{
            .name = in.name,
            .source = source_of(try environment_value(ctx.arena, in.name) != null, true),
            .used_by = try users_of(ctx, in.name),
            .updated_at = ctx.now_ms,
        };
    }
};

pub const Remove = struct {
    pub const name = "secret.remove";
    pub const description = "Forget a secret's value";
    pub const details =
        \\The plugins that use it then send their requests without it, and are told it is
        \\missing. An environment variable of the same name is left as it is.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
    };
    pub const Out = struct {
        removed: bool,
    };
    pub const example: In = .{
        .name = "STOCKS_API_KEY",
    };
    pub const example_out: Out = .{
        .removed = true,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The secret's name",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (!secrets.valid_name(in.name)) {
            return error.Invalid;
        }

        // Its sealed value waits in the trash; `trash restore` puts it back in use.
        if (try kept.get(ctx.db, ctx.arena, in.name) != null) {
            const key = std.fmt.allocPrint(ctx.arena, "[\"{s}\"]", .{in.name}) catch {
                return error.OutOfMemory;
            };

            _ = try trash.keep(ctx, .{
                .kind = "secret",
                .key = in.name,
                .label = std.fmt.allocPrint(ctx.arena, "Secret {s}", .{in.name}) catch {
                    return error.OutOfMemory;
                },
                .roots = &.{.{
                    .table = "secrets",
                    .column = "name",
                    .keys = key,
                }},
            });
        }

        const removed = try kept.delete(ctx.db, in.name);

        if (removed) {
            ctx.notice("secret.removed", in.name);
        }

        return .{
            .removed = removed,
        };
    }
};

fn source_of(from_environment: bool, is_kept: bool) []const u8 {
    std.debug.assert(key_variable.len > 0);

    if (from_environment) {
        return "environment";
    }

    return if (is_kept) "kept" else "missing";
}

const no_key: sdk.operation.Failure = .{
    .name = "NoKey",
    .status = 503,
    .message = "There is nowhere to keep the project's key: set PUBLR_SECRET_KEY",
};

/// A secret's value as a request leaving the project gets it: the environment variable of
/// the same name, else the one kept here; null when neither is set. Never answered to a
/// caller: core fills it into a request at the last moment.
pub fn value_of(ctx: *Ctx, secret_name: []const u8) Error!?[]const u8 {
    std.debug.assert(secrets.valid_name(secret_name));
    std.debug.assert(ctx.now_ms >= 0);

    if (try environment_value(ctx.arena, secret_name)) |value| {
        return value;
    }

    const row = try kept.get(ctx.db, ctx.arena, secret_name) orelse return null;
    const key = try key_of(ctx, .read) orelse return null;

    return secrets.open(ctx.arena, key, secret_name, row.sealed.bytes) catch error.OutOfMemory;
}

fn environment_value(arena: std.mem.Allocator, secret_name: []const u8) Error!?[]const u8 {
    std.debug.assert(secret_name.len > 0);
    std.debug.assert(secret_name.len <= environment.name_len_max);

    const terminated = arena.dupeZ(u8, secret_name) catch return error.OutOfMemory;

    return environment.get(terminated);
}

const Want = enum { read, make };

/// The project's key: `PUBLR_SECRET_KEY`, else `secret.key` beside the database, made
/// (0600) when `want` is `make` and it is not there yet. Null when there is none.
fn key_of(ctx: *Ctx, want: Want) Error!?secrets.Key {
    std.debug.assert(key_variable.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    if (environment.get(key_variable)) |hex| {
        return secrets.key_of(hex) orelse ctx.fail(bad_key);
    }

    const path = try key_path(ctx) orelse return null;
    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(256);
    const text = cwd.readFileAlloc(ctx.io, path, ctx.arena, limit) catch |err| switch (err) {
        error.FileNotFound => return if (want == .make) try make_key(ctx, path) else null,
        else => return error.Unavailable,
    };

    return secrets.key_of(text) orelse ctx.fail(bad_key);
}

fn make_key(ctx: *Ctx, path: []const u8) Error!secrets.Key {
    std.debug.assert(path.len > 0);
    std.debug.assert(std.mem.endsWith(u8, path, key_file));

    var key: secrets.Key = undefined;
    ctx.io.random(&key);

    const hex = std.fmt.bytesToHex(key, .lower);
    var file = std.Io.Dir.cwd().createFile(ctx.io, path, .{
        .permissions = .fromMode(0o600),
        .exclusive = true,
    }) catch return error.Unavailable;
    defer file.close(ctx.io);

    file.writeStreamingAll(ctx.io, &hex) catch return error.Unavailable;

    return key;
}

fn key_path(ctx: *Ctx) Error!?[]const u8 {
    std.debug.assert(key_file.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const database = try kept.database_path(ctx.db, ctx.arena);

    if (database.len == 0) {
        return null;
    }

    const dir = std.fs.path.dirname(database) orelse ".";

    return std.fs.path.join(ctx.arena, &.{ dir, key_file }) catch error.OutOfMemory;
}

fn key_source(ctx: *Ctx) Error![]const u8 {
    std.debug.assert(key_variable.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    if (environment.get(key_variable) != null) {
        return "environment";
    }

    const path = try key_path(ctx) orelse return "none";

    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch return "none";

    return "file";
}

const bad_key: sdk.operation.Failure = .{
    .name = "BadKey",
    .status = 500,
    .message = "The project's key is not 64 hex digits",
};

/// Adds every secret an installed plugin asked for that `names` lacks.
/// The secrets plugins asked for that are not set, each once, in the plugins' order.
fn asked_missing(ctx: *Ctx) Error![]const []const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    var names: std.ArrayList([]const u8) = .empty;
    const sandboxed = ctx.sandboxed_plugins orelse return names.items;

    for (sandboxed.manifests()) |manifest| {
        for (manifest.permissions) |ask| {
            const asked = secret_in(ask.key) orelse continue;

            if (find_name(names.items, asked) or try kept.get(ctx.db, ctx.arena, asked) != null) {
                continue;
            }

            try names.append(ctx.arena, asked);
        }
    }

    return names.items;
}

/// A secret as the list shows it.
fn listed_of(ctx: *Ctx, secret_name: []const u8, is_set: bool, updated_at: i64) Error!Listed {
    std.debug.assert(secret_name.len > 0);

    const from_environment = try environment_value(ctx.arena, secret_name) != null;

    return .{
        .name = secret_name,
        .source = source_of(from_environment, is_set),
        .used_by = try users_of(ctx, secret_name),
        .updated_at = updated_at,
    };
}

/// The plugins that asked for `secret.<name>`.
fn users_of(ctx: *Ctx, secret_name: []const u8) Error![]const []const u8 {
    std.debug.assert(secret_name.len > 0);

    var users: std.ArrayList([]const u8) = .empty;
    const sandboxed = ctx.sandboxed_plugins orelse return users.items;

    for (sandboxed.manifests()) |manifest| {
        for (manifest.permissions) |ask| {
            const asked = secret_in(ask.key) orelse continue;

            if (std.mem.eql(u8, asked, secret_name)) {
                try users.append(ctx.arena, manifest.name);
            }
        }
    }

    return users.items;
}

fn secret_in(key: []const u8) ?[]const u8 {
    std.debug.assert(key.len <= 64 << 10);

    if (key.len == 0 or !model.permission.is_secret(key)) {
        return null;
    }

    return key[model.permission.secret_prefix.len..];
}

fn find_name(names: []const []const u8, wanted: []const u8) bool {
    std.debug.assert(wanted.len > 0);

    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, wanted)) {
            return true;
        }
    }

    return false;
}
