//! What a removal says before it runs, for the person reviewing a removal list: what goes,
//! in words, what goes with it, and why it can never go this way (with how to do it by
//! hand). Read through the ordinary read operations, as the one who listed it.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const registry = @import("../../server/registry.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Described = model.removal.Described;

/// `input` is the removal's input as JSON.
pub fn of(ctx: *Ctx, operation: []const u8, input: []const u8) Error!Described {
    std.debug.assert(operation.len > 0);
    std.debug.assert(input.len > 0);

    const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, input, .{}) catch {
        return .{
            .label = try say(ctx, "{s} {s}", .{ operation, input }),
        };
    };
    const fields = switch (value) {
        .object => |object| object,
        else => return .{
            .label = try say(ctx, "{s} {s}", .{ operation, input }),
        },
    };
    const forced = if (fields.get("force")) |force| force == .bool and force.bool else false;

    if (eql(operation, "record.purge")) {
        return record_of(ctx, text_of(fields, "id"));
    }

    if (eql(operation, "term.purge")) {
        return term_of(ctx, text_of(fields, "id"));
    }

    if (eql(operation, "media.delete")) {
        return media_of(ctx, fields.get("ids"));
    }

    if (eql(operation, "user.delete")) {
        return user_of(ctx, text_of(fields, "user"));
    }

    if (eql(operation, "trash.remove")) {
        const entry = try store.trash.get(ctx.db, ctx.arena, text_of(fields, "id"));
        const label = if (entry) |found| found.label else text_of(fields, "id");

        return .{
            .label = try say(ctx, "{s}, from the trash", .{label}),
            .detail = "it can never be restored",
        };
    }

    if (eql(operation, "content_type.delete")) {
        return .{
            .label = try say(ctx, "Content type {s}", .{text_of(fields, "type")}),
            .detail = if (forced) "and every record of it" else "only while it has no records",
        };
    }

    if (eql(operation, "taxonomy.delete")) {
        return .{
            .label = try say(ctx, "Taxonomy {s}", .{text_of(fields, "taxonomy")}),
            .detail = if (forced) "and every term in it" else "only while it has no terms",
        };
    }

    return plain(ctx, operation, fields);
}

/// The removals said from their input alone.
fn plain(ctx: *Ctx, operation: []const u8, fields: std.json.ObjectMap) Error!Described {
    std.debug.assert(operation.len > 0);

    if (eql(operation, "custom_fields.delete")) {
        return .{
            .label = try say(ctx, "Field group {s}", .{text_of(fields, "group")}),
            .detail = "its fields, and what they hold",
        };
    }

    if (eql(operation, "plugin.remove")) {
        return .{
            .label = try say(ctx, "Plugin {s}", .{text_of(fields, "name")}),
            .detail = "its grants and versions",
        };
    }

    if (eql(operation, "snapshot.prune")) {
        const keep = if (fields.get("keep")) |count| count.integer else 0;

        return .{
            .label = try say(ctx, "Older {s} snapshots of record {s}", .{
                text_of(fields, "kind"),
                text_of(fields, "id"),
            }),
            .detail = try say(ctx, "keeping the newest {d}", .{keep}),
        };
    }

    if (eql(operation, "trash.empty")) {
        return .{
            .label = "Everything in the trash",
            .detail = "it can never be restored",
        };
    }

    if (eql(operation, "apps.remove")) {
        return .{
            .label = try say(ctx, "App file {s}", .{text_of(fields, "path")}),
        };
    }

    if (eql(operation, "secret.remove")) {
        return .{
            .label = try say(ctx, "Secret {s}", .{text_of(fields, "name")}),
            .detail = "the plugins that use it lose it",
        };
    }

    return .{
        .label = operation,
    };
}

fn record_of(ctx: *Ctx, id: []const u8) Error!Described {
    std.debug.assert(id.len <= 256);

    const Got = struct {
        record: struct {
            type: []const u8 = "",
            title: []const u8 = "",
        },
    };
    const input = try say(ctx, "{{\"id\":\"{s}\",\"purpose\":\"edit\"}}", .{id});
    const got = read(ctx, Got, "record.get", input) orelse return .{
        .label = try say(ctx, "Record {s}", .{id}),
        .detail = "with its changes and revisions",
    };

    return .{
        .label = try say(ctx, "{s} “{s}”", .{ got.record.type, got.record.title }),
        .detail = "with its changes and revisions",
    };
}

fn term_of(ctx: *Ctx, id: []const u8) Error!Described {
    std.debug.assert(id.len <= 256);

    const Got = struct {
        term: struct {
            title: []const u8 = "",
            type: []const u8 = "",
        },
    };
    const input = try say(ctx, "{{\"id\":\"{s}\",\"purpose\":\"edit\"}}", .{id});
    const got = read(ctx, Got, "term.get", input) orelse return .{
        .label = try say(ctx, "Term {s}", .{id}),
    };

    return .{
        .label = try say(ctx, "Term “{s}” of {s}", .{ got.term.title, got.term.type }),
    };
}

fn media_of(ctx: *Ctx, ids: ?std.json.Value) Error!Described {
    std.debug.assert(model.removal.label_len_max > 0);

    const list = switch (ids orelse return .{
        .label = "Files",
    }) {
        .array => |array| array.items,
        else => return .{
            .label = "Files",
        },
    };
    var names: std.ArrayList(u8) = .empty;

    for (list, 0..) |item, index| {
        if (item != .string) {
            continue;
        }

        const id = item.string;
        const Got = struct {
            media: struct {
                filename: []const u8 = "",
            },
        };
        const input = try say(ctx, "{{\"id\":\"{s}\"}}", .{id});
        const name = if (read(ctx, Got, "media.get", input)) |got| got.media.filename else id;

        if (index > 0) {
            names.appendSlice(ctx.arena, ", ") catch return error.OutOfMemory;
        }

        names.appendSlice(ctx.arena, name) catch return error.OutOfMemory;
    }

    const plural: []const u8 = if (list.len == 1) "" else "s";

    return .{
        .label = try say(ctx, "{d} file{s}: {s}", .{
            list.len,
            plural,
            model.ai.clipped(names.items, 200),
        }),
        .detail = "with their resized copies",
    };
}

fn user_of(ctx: *Ctx, user: []const u8) Error!Described {
    std.debug.assert(user.len <= 256);

    const Got = struct {
        user: struct {
            id: []const u8 = "",
            email: []const u8 = "",
            display_name: []const u8 = "",
        },
    };
    const input = try say(ctx, "{{\"user\":\"{s}\"}}", .{user});
    const got = read(ctx, Got, "user.get", input) orelse return .{
        .label = try say(ctx, "User {s}", .{user}),
    };
    const label = try say(ctx, "User {s} ({s})", .{ got.user.display_name, got.user.email });
    const own = if (ctx.caller.user_id()) |caller| eql(caller, got.user.id) else false;

    if (own) {
        return .{
            .label = label,
            .blocked = try say(ctx, "Your own account is never removed from it. Another " ++
                "administrator deletes it under Settings › Users, or on the server: " ++
                "publr --as-admin user delete --user {s}", .{got.user.email}),
        };
    }

    return .{
        .label = label,
        .detail = "signed out everywhere; what they made stays",
    };
}

/// A read operation's answer, or null when it cannot be read.
fn read(ctx: *Ctx, comptime Shape: type, operation: []const u8, input: []const u8) ?Shape {
    std.debug.assert(operation.len > 0);

    const output = registry.SDK.call_json(ctx, operation, input) catch return null;

    return std.json.parseFromSliceLeaky(Shape, ctx.arena, output, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

fn text_of(fields: std.json.ObjectMap, name: []const u8) []const u8 {
    std.debug.assert(name.len > 0);

    const value = fields.get(name) orelse return "";

    return if (value == .string) value.string else "";
}

fn say(ctx: *Ctx, comptime format: []const u8, args: anytype) Error![]const u8 {
    const text = std.fmt.allocPrint(ctx.arena, format, args) catch return error.OutOfMemory;

    return model.ai.clipped(text, model.removal.label_len_max);
}

fn eql(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
