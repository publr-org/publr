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
    Throttled,
    /// The operation's own failure, one the core does not name: `ctx.failure` says which
    /// (a `Failure` its plugin declares), and the adapters answer with its status and name.
    Failed,
    /// A service the operation depends on could not be reached; nothing was changed.
    Unavailable,
    BadCredentials,
    InvalidationFailed,
    /// A modifier's read, noted for its batch: the modifier runs again once the batch's reads
    /// are in. Only a modifier's first pass sees it.
    NotYet,
};

pub const Kind = enum { read, write };

/// Whether the operation destroys what cannot be had back (`pub const destroys = true`):
/// a device never may; a person does it in the admin.
pub fn destroys(comptime Operation: type) bool {
    return @hasDecl(Operation, "destroys") and Operation.destroys;
}

/// What a device is told when it tries to destroy something.
pub const needs_person: Failure = .{
    .name = "NeedsPerson",
    .status = 403,
    .message = "This destroys data for good, so a person does it in the admin, not a device",
};

/// What a `drafts` device is told when its write would change what visitors see.
pub const drafts_only: Failure = .{
    .name = "DraftsOnly",
    .status = 403,
    .message = "This device saves drafts only; a person publishes them in the admin",
};

/// A way an operation fails that the core's errors do not name, raised with `ctx.fail`:
/// "your email is not verified", "the plan's limit is reached". A plugin's operation lists
/// the ones it can end with on its `Fails:` lines.
pub const Failure = struct {
    /// What REST answers (`{ "error": "Unverified" }`): letters only, starting upper-case.
    name: []const u8,
    /// An HTTP status from 400 to 599.
    status: u16,
    /// For people: the CLI prints it, REST sends it as `message`.
    message: []const u8,
};

/// One thing wrong with a call's input, beside its field: `.validate`'s `problems.add`.
pub const Problem = struct {
    /// A field of the input, as named in it.
    field: []const u8,
    /// For people, shown beside the field.
    message: []const u8,
};

pub const problems_max: u32 = 64;
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
    /// What people call it: `Media library`. Empty shows the name.
    label: []const u8 = "",
    /// Where it sits when roles are edited.
    area: Area = .site,

    pub const Area = enum {
        /// What editors write: records, terms, media, their history.
        content,
        /// The site's structure and setup: types, fields, apps, design.
        site,
        /// Accounts, roles and how people sign in.
        people,
        /// How this Publr runs: plugins, secrets, updates, logs.
        system,
        /// What every role needs or no one grants by hand (liveness, a person's own pins
        /// and views): not listed when roles are edited, its grants kept as they are.
        background,
    };
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
            &@splat(.{
                .default_value_ptr = default_ptr,
            }),
        );
    }
}

/// The one way a list is paged: `limit` (1 to 200) and `offset`, and what a page answers.
pub const Page = struct {
    limit: u32 = 50,
    offset: u32 = 0,
};
pub const page_limit_max: u32 = 200;

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

/// An operation on its way out (`.agents/specs/updates.md`, "Deprecation before removal"):
/// it keeps working for at least six months, every caller is told, and only a major removes
/// it. `pub const deprecated: Deprecated = .{ .since = "0.4.0", .instead = "record.save" };`
pub const Deprecated = struct {
    /// The minor release that deprecated it.
    since: []const u8,
    /// The operation to call instead; empty when nothing replaces it.
    instead: []const u8 = "",
    /// Why, in a sentence, when the name of the replacement does not say.
    why: []const u8 = "",
};

pub fn deprecation(comptime Operation: type) ?Deprecated {
    comptime {
        if (!@hasDecl(Operation, "deprecated")) {
            return null;
        }

        const found: Deprecated = @as(?Deprecated, Operation.deprecated) orelse return null;

        std.debug.assert(found.since.len > 0);

        return found;
    }
}

/// `deprecated since 0.4.0; call record.save instead`: what every caller is told.
pub fn deprecation_text(comptime Operation: type) []const u8 {
    comptime {
        std.debug.assert(Operation.name.len > 0);

        const found = deprecation(Operation) orelse return "";
        const instead = if (found.instead.len > 0) "; call " ++ found.instead ++ " instead" else "";
        const why = if (found.why.len > 0) ". " ++ found.why else "";

        return Operation.name ++ " is deprecated since " ++ found.since ++ instead ++ why;
    }
}

fn validate_deprecated(comptime Operation: type) void {
    comptime {
        std.debug.assert(Operation.name.len > 0);

        const found = deprecation(Operation) orelse return;

        _ = std.SemanticVersion.parse(found.since) catch
            @compileError(Operation.name ++ ": `deprecated.since` is the release, `0.4.0`");
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

        if (@hasDecl(Operation, "destroys")) {
            assert_decl(Operation, "destroys", bool);

            if (Operation.destroys and Operation.kind != .write) {
                @compileError(Operation.name ++ ": only a write destroys");
            }
        }

        validate_deprecated(Operation);

        if (@hasDecl(Operation, "failures")) {
            for (Operation.failures) |failure| {
                if (!valid_failure(failure)) {
                    @compileError(Operation.name ++ ": failure `" ++ failure.name ++ "` needs " ++
                        "a name of letters starting upper-case, a 4xx or 5xx status and a " ++
                        "message of 1 to 200 characters");
                }
            }
        }
    }
}

/// The content type an operation is about, read from its input by convention: `type`.
pub fn type_of(in: anytype) ?[]const u8 {
    const In = @TypeOf(in);

    comptime std.debug.assert(@typeInfo(In) == .@"struct");

    return if (@hasField(In, "type")) in.type else null;
}

/// `namespace.verb`; `app.` is part of an address (`/_actions/app.x.y`), never of a name.
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

        if (dots != 1) {
            @compileError("operation name must be namespace.verb: " ++ name);
        }

        const doubled = std.mem.indexOf(u8, name, "..") != null;

        if (name[0] == '.' or name[name.len - 1] == '.' or doubled) {
            @compileError("operation name: " ++ name);
        }
    }
}

/// JSON an operation answers as it is, written through untouched: a query's result.
pub const Json = struct {
    text: []const u8,

    pub fn jsonStringify(json: Json, writer: anytype) !void {
        std.debug.assert(json.text.len > 0);

        try writer.beginWriteRaw();
        try writer.writer.writeAll(json.text);
        writer.endWriteRaw();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Json {
        const value = try std.json.Value.jsonParse(allocator, source, options);
        const text = std.json.Stringify.valueAlloc(allocator, value, .{}) catch {
            return error.OutOfMemory;
        };

        return .{
            .text = text,
        };
    }
};

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
                // A reference is written as its id, whatever its record holds; an object
                // whose keys come with the data writes its own JSON.
                if (@hasDecl(Type, "reference") or @hasDecl(Type, "json_object")) {
                    return;
                }

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

/// The comptime branches `namespace` or `verb` takes at most: a caller splitting every
/// operation's name raises its quota by this for each.
pub const split_branches: u32 = name_len_max + 8;

/// Everything before the verb: `record` of `record.create`.
pub fn namespace(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse unreachable;
    std.debug.assert(dot > 0);
    return name[0..dot];
}

pub fn verb(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse unreachable;
    std.debug.assert(dot + 1 < name.len);
    return name[dot + 1 ..];
}

test "namespace and verb split" {
    try std.testing.expectEqualStrings("record", namespace("record.create"));
    try std.testing.expectEqualStrings("create", verb("record.create"));
    comptime assert_name("newsletter.subscribe");
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
    const good: Failure = .{
        .name = "Unverified",
        .status = 403,
        .message = "Verify first",
    };

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

test "a deprecated operation says since when and what to call instead" {
    const Old = struct {
        pub const name = "note.old_save";
        pub const deprecated: Deprecated = .{
            .since = "0.4.0",
            .instead = "note.save",
        };
    };
    const Plain = struct {
        pub const name = "note.save";
    };

    try std.testing.expectEqualStrings(
        "note.old_save is deprecated since 0.4.0; call note.save instead",
        comptime deprecation_text(Old),
    );
    try std.testing.expect(comptime deprecation(Plain) == null);
    try std.testing.expectEqualStrings("", comptime deprecation_text(Plain));
}
