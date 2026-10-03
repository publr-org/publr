const std = @import("std");
const db = @import("../lib/db.zig");

pub const name_len_max: u32 = 64;
pub const type_depth_max: u32 = 8;
pub const fields_max: u32 = 64;

pub const Error = db.Error || error{
    Denied,
    Invalid,
    NotFound,
    Conflict,
    Vetoed,
    Throttled,
    /// The operation's own failure, one the core does not name: `ctx.failure` says which
    /// (a `Failure` its plugin declares), and the adapters answer with its status and name.
    Failed,
    /// A service the operation depends on could not be reached; nothing was changed.
    Unavailable,
    BadCredentials,
    InvalidationFailed,
};

pub const Kind = enum { read, write };

/// A way an operation fails that the core's errors do not name, declared by the plugin that
/// owns the operation and raised with `ctx.fail`: "your email is not verified", "the plan's
/// limit is reached". An operation lists the ones it can end with in `failures`, for its
/// documentation.
pub const Failure = struct {
    /// What REST answers (`{ "error": "Unverified" }`): letters only, starting upper-case.
    name: []const u8,
    /// An HTTP status from 400 to 599.
    status: u16,
    /// For people: the CLI prints it, REST sends it as `message`.
    message: []const u8,
};

pub const failure_name_len_max: u32 = 64;
pub const failure_message_len_max: u32 = 200;

/// A failure as declared: a name of letters starting upper-case, a 4xx or 5xx status, and
/// a message of 1 to 200 characters.
pub fn valid_failure(failure: Failure) bool {
    std.debug.assert(failure_name_len_max > 0);

    const name = failure.name;
    const name_ok = name.len > 0 and name.len <= failure_name_len_max and
        std.ascii.isUpper(name[0]);
    const status_ok = failure.status >= 400 and failure.status <= 599;
    const message_ok = failure.message.len > 0 and
        failure.message.len <= failure_message_len_max;

    for (name) |char| {
        if (!std.ascii.isAlphabetic(char)) {
            return false;
        }
    }

    return name_ok and status_ok and message_ok;
}

pub const Namespace = struct {
    name: []const u8,
    summary: []const u8,
    details: []const u8,
};

pub const Resource = struct {
    type_id: ?[]const u8 = null,
    record_id: ?[]const u8 = null,
    owner_id: ?[]const u8 = null,
    from_status: ?[]const u8 = null,
    to_status: ?[]const u8 = null,
    fields: []const []const u8 = &.{},
};

pub fn Docs(comptime Shape: type) type {
    comptime {
        const source = @typeInfo(Shape).@"struct".fields;
        const empty: []const u8 = "";
        const default_ptr: ?*const anyopaque = @ptrCast(&empty);

        std.debug.assert(source.len <= fields_max);

        return @Struct(
            .auto,
            null,
            std.meta.fieldNames(Shape),
            &@splat([]const u8),
            &@splat(.{ .default_value_ptr = default_ptr }),
        );
    }
}

/// The one way a list is paged: `limit` (1 to 200) and `offset`, and what a page answers.
pub const Page = struct { limit: u32 = 50, offset: u32 = 0 };
pub const page_limit_max: u32 = 200;

pub fn PageOut(comptime Item: type) type {
    comptime std.debug.assert(@sizeOf(Item) > 0);

    return struct { items: []const Item, next_offset: ?u32 = null };
}

/// The bounds an operation declares on its input's fields (`pub const rules`), checked by
/// core before it runs: `.{ .quantity = .{ .min = 1, .max = 20 } }`.
pub fn Rules(comptime Shape: type) type {
    comptime {
        const Rule = @import("../model/input_rule.zig").Rule;
        const none: Rule = .{};
        const default_ptr: ?*const anyopaque = @ptrCast(&none);

        std.debug.assert(@typeInfo(Shape).@"struct".fields.len <= fields_max);

        return @Struct(
            .auto,
            null,
            std.meta.fieldNames(Shape),
            &@splat(Rule),
            &@splat(.{ .default_value_ptr = default_ptr }),
        );
    }
}

/// The shape of what an operation takes, its declared rules on its top-level fields.
pub fn input_shape(comptime Operation: type) []const @import("../model/contract.zig").Node {
    comptime {
        const contract = @import("../model/contract.zig");
        const described = contract.describe(Operation.In);

        std.debug.assert(described.len > 0);

        if (!@hasDecl(Operation, "rules")) {
            return described;
        }

        var nodes = described[0..described.len].*;

        for (&nodes) |*node| {
            if (node.parent == 0 and @hasField(@TypeOf(Operation.rules), node.name)) {
                node.rule = @field(Operation.rules, node.name);
            }
        }

        const fixed = nodes;

        return &fixed;
    }
}

pub fn field_doc(
    comptime Operation: type,
    comptime docs_name: []const u8,
    comptime field: []const u8,
) []const u8 {
    comptime {
        std.debug.assert(docs_name.len > 0);
        std.debug.assert(field.len > 0);

        if (!@hasDecl(Operation, docs_name)) {
            return "";
        }

        return @field(@field(Operation, docs_name), field);
    }
}

pub fn validate(comptime Operation: type) void {
    comptime {
        assert_decl(Operation, "name", []const u8);
        assert_decl(Operation, "description", []const u8);
        assert_decl(Operation, "kind", Kind);
        assert_decl(Operation, "In", type);
        assert_decl(Operation, "Out", type);
        assert_name(Operation.name);
        assert_serialisable(Operation.In, 0);
        assert_serialisable(Operation.Out, 0);

        if (!@hasDecl(Operation, "run")) {
            @compileError(Operation.name ++ ": missing `run`");
        }

        if (!@hasDecl(Operation, "example")) {
            @compileError(Operation.name ++ ": missing `example: In`");
        }

        if (@TypeOf(Operation.example) != Operation.In) {
            @compileError(Operation.name ++ ": `example` must be an `In`");
        }

        if (!@hasDecl(Operation, "example_out")) {
            @compileError(Operation.name ++ ": missing `example_out: Out`");
        }

        assert_decl(Operation, "example_out", Operation.Out);

        if (@hasDecl(Operation, "field_docs")) {
            assert_decl(Operation, "field_docs", Docs(Operation.In));
        }

        if (@hasDecl(Operation, "output_docs")) {
            assert_decl(Operation, "output_docs", Docs(Operation.Out));
        }

        if (@hasDecl(Operation, "details")) {
            assert_decl(Operation, "details", []const u8);
        }

        if (@hasDecl(Operation, "failures")) {
            for (Operation.failures) |failure| {
                if (!valid_failure(failure)) {
                    @compileError(Operation.name ++ ": failure `" ++ failure.name ++ "` needs " ++
                        "a name of letters starting upper-case, a 4xx or 5xx status and a " ++
                        "message of 1 to 200 characters");
                }
            }
        }

        const gone = @hasDecl(Operation, "resource") or @hasDecl(Operation, "seed") or
            @hasDecl(Operation, "volatile_fields") or @hasDecl(Operation, "example_caller");

        if (gone) {
            @compileError(Operation.name ++ ": `resource`, `seed`, `volatile_fields` and " ++
                "`example_caller` are gone; the resource is read from `In` by field name");
        }
    }
}

/// What an operation is about, read from its input by convention: `type` names the
/// content type, `id` the record, `to` (or `status`) the target status.
pub fn resource_of(in: anytype) Resource {
    const In = @TypeOf(in);

    comptime std.debug.assert(@typeInfo(In) == .@"struct");

    var resource: Resource = .{};

    if (@hasField(In, "type")) {
        resource.type_id = in.type;
    }

    if (@hasField(In, "id")) {
        resource.record_id = in.id;
    }

    if (@hasField(In, "to")) {
        resource.to_status = in.to;
    } else if (@hasField(In, "status")) {
        resource.to_status = in.status;
    }

    std.debug.assert(resource.fields.len == 0);

    return resource;
}

/// `namespace.verb`, or `app.<feature>.verb` for what apps call: the grants a role gives
/// its visitors name those (`app.newsletter.*`), never the admin's (`newsletter.*`).
pub fn assert_name(comptime name: []const u8) void {
    comptime {
        if (name.len == 0 or name.len > name_len_max) {
            @compileError("operation name length: " ++ name);
        }

        var dots: u32 = 0;

        for (name) |ch| {
            const ok = (ch >= 'a' and ch <= 'z') or ch == '_' or ch == '.';
            if (!ok) {
                @compileError("operation name must be [a-z_.]: " ++ name);
            }
            if (ch == '.') {
                dots += 1;
            }
        }

        const dots_wanted: u32 = if (is_app(name)) 2 else 1;

        if (dots != dots_wanted) {
            @compileError("operation name must be namespace.verb or app.feature.verb: " ++ name);
        }

        const doubled = std.mem.indexOf(u8, name, "..") != null;

        if (name[0] == '.' or name[name.len - 1] == '.' or doubled) {
            @compileError("operation name: " ++ name);
        }
    }
}

/// Whether an operation is one apps call: `app.<feature>.<verb>`.
pub fn is_app(name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= name_len_max);

    return std.mem.startsWith(u8, name, "app.");
}

pub fn assert_serialisable(comptime Type: type, comptime depth: u32) void {
    comptime {
        if (depth > type_depth_max) {
            return;
        }

        switch (@typeInfo(Type)) {
            .bool, .int, .float, .void => {},
            .@"enum" => {},
            .optional => |optional| assert_serialisable(optional.child, depth + 1),
            .pointer => |pointer| {
                if (pointer.size != .slice) {
                    @compileError("only slices: " ++ @typeName(Type));
                }
                assert_serialisable(pointer.child, depth + 1);
            },
            .array => |array| assert_serialisable(array.child, depth + 1),
            .@"struct" => |structure| {
                if (structure.fields.len > fields_max) {
                    @compileError("too many fields: " ++ @typeName(Type));
                }
                for (structure.fields) |field| assert_serialisable(field.type, depth + 1);
            },
            else => @compileError("not serialisable: " ++ @typeName(Type)),
        }
    }
}

fn assert_decl(comptime Operation: type, comptime decl: []const u8, comptime Type: type) void {
    if (!@hasDecl(Operation, decl)) {
        @compileError(@typeName(Operation) ++ ": missing `" ++ decl ++ "`");
    }

    const actual = @TypeOf(@field(Operation, decl));
    const ok = actual == Type or (Type == []const u8 and @typeInfo(actual) == .pointer);

    if (!ok) {
        @compileError(@typeName(Operation) ++ "." ++ decl ++ ": wrong type");
    }
}

/// Everything before the verb: `record` of `record.create`, `app.newsletter` of
/// `app.newsletter.subscribe`.
pub fn namespace(name: []const u8) []const u8 {
    @setEvalBranchQuota(100_000);

    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse unreachable;
    std.debug.assert(dot > 0);
    return name[0..dot];
}

pub fn verb(name: []const u8) []const u8 {
    @setEvalBranchQuota(100_000);

    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse unreachable;
    std.debug.assert(dot + 1 < name.len);
    return name[dot + 1 ..];
}

test "namespace and verb split" {
    try std.testing.expectEqualStrings("record", namespace("record.create"));
    try std.testing.expectEqualStrings("create", verb("record.create"));
    try std.testing.expectEqualStrings("app.newsletter", namespace("app.newsletter.subscribe"));
    try std.testing.expectEqualStrings("subscribe", verb("app.newsletter.subscribe"));
    try std.testing.expect(is_app("app.newsletter.subscribe"));
    try std.testing.expect(!is_app("newsletter.list"));
    comptime assert_name("app.newsletter.subscribe");
}

test "serialisable types are accepted, pointers to single items rejected at comptime" {
    const Good = struct {
        id: []const u8,
        count: u32,
        ratio: ?f64,
        tags: []const []const u8,
        on: bool,
    };
    comptime assert_serialisable(Good, 0);
    comptime assert_name("hello.record");
}

test "a failure is a name of letters, a 4xx or 5xx status and a short message" {
    const good: Failure = .{ .name = "Unverified", .status = 403, .message = "Verify first" };

    try std.testing.expect(valid_failure(good));

    var lower = good;
    lower.name = "unverified";
    var spaced = good;
    spaced.name = "Not Verified";
    var success = good;
    success.status = 200;
    var silent = good;
    silent.message = "";

    for ([_]Failure{ lower, spaced, success, silent }) |bad| {
        try std.testing.expect(!valid_failure(bad));
    }
}
