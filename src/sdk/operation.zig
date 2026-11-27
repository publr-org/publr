const std = @import("std");
const db = @import("../lib/db.zig");
const public = @import("../publr/operation.zig");

pub const values = @import("operation/values.zig");
pub const lists = @import("operation/lists.zig");
pub const shaped = @import("operation/shaped.zig");
pub const json_fields = @import("operation/json_fields.zig");
const checked = @import("operation/checked.zig");

pub const name_len_max = public.name_len_max;
pub const fields_max = public.fields_max;

pub const Error = db.Error || public.Error;

/// The error a plugin hears for one of core's: the database's own become what a plugin can
/// act on (a broken constraint a conflict, a locked or failing database unavailable, a
/// statement stopped or too big invalid).
pub fn public_of(err: Error) public.Error {
    std.debug.assert(@typeInfo(public.Error).error_set.error_names.?.len > 0);

    return switch (err) {
        error.Constraint => error.Conflict,
        error.Busy, error.ReadOnly, error.Sqlite => error.Unavailable,
        error.Interrupted, error.TooBig => error.Invalid,
        else => |other| other,
    };
}

pub const Kind = public.Kind;

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

pub const Failure = public.Failure;
pub const Problem = public.Problem;

pub const problems_max: u32 = 64;
pub const failure_name_len_max = public.failure_name_len_max;
pub const failure_message_len_max = public.failure_message_len_max;

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

pub const Namespace = public.Namespace;

pub const Docs = public.Docs;

/// The one way a list is paged: `limit` (1 to 200) and `offset`, and what a page answers.
pub const Page = struct {
    limit: u32 = 50,
    offset: u32 = 0,
};
pub const page_limit_max = public.page_limit_max;

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

pub const Deprecated = public.Deprecated;

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

/// `record.old is deprecated since 0.9.0 and removed on 2027-03-01; call record.save instead.
/// <migration>`: what every caller is told.
pub fn deprecation_text(comptime Operation: type) []const u8 {
    comptime {
        std.debug.assert(Operation.name.len > 0);

        const found = deprecation(Operation) orelse return "";
        const instead = if (found.instead.len > 0) "; call " ++ found.instead ++ " instead" else "";

        return Operation.name ++ " is deprecated since " ++ found.since ++ " and removed on " ++
            found.removed_on ++ instead ++ ". " ++ found.migration;
    }
}

/// Whether `text` is a day as `YYYY-MM-DD` writes it, with a month and a day that exist in
/// some year.
pub fn valid_day(text: []const u8) bool {
    std.debug.assert(text.len <= 1 << 16);

    if (text.len != 10 or text[4] != '-' or text[7] != '-') {
        return false;
    }

    _ = std.fmt.parseInt(u16, text[0..4], 10) catch return false;

    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return false;

    return month >= 1 and month <= 12 and day >= 1 and day <= 31;
}

/// What every deprecation must say, whatever it is on (an operation, an event, a mod): the
/// release, the day, what to change, and an `instead` other than itself.
pub fn check_deprecated(comptime name: []const u8, comptime found: Deprecated) void {
    comptime {
        std.debug.assert(name.len > 0);

        _ = std.SemanticVersion.parse(found.since) catch
            @compileError(name ++ ": `deprecated.since` is the release, `0.4.0`");

        if (!valid_day(found.removed_on)) {
            @compileError(name ++ ": `deprecated.removed_on` is a day, `2027-03-01`");
        }

        if (found.migration.len == 0) {
            @compileError(name ++ ": `deprecated.migration` says what to change");
        }

        if (std.mem.eql(u8, found.instead, name)) {
            @compileError(name ++ ": `deprecated.instead` names something else");
        }
    }
}

pub const validate = checked.validate;

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

pub const Json = public.Json;

/// The comptime branches `namespace` or `verb` takes at most: a caller splitting every
/// operation's name raises its quota by this for each.
pub const split_branches: u32 = name_len_max + 8;

pub const namespace = public.namespace;
pub const verb = public.verb;

test "namespace and verb split" {
    try std.testing.expectEqualStrings("record", namespace("record.create"));
    try std.testing.expectEqualStrings("create", verb("record.create"));
    comptime assert_name("newsletter.subscribe");
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
            .removed_on = "2027-03-01",
            .instead = "note.save",
            .migration = "Same input, under the new name.",
        };
    };
    const Plain = struct {
        pub const name = "note.save";
    };

    try std.testing.expectEqualStrings(
        "note.old_save is deprecated since 0.4.0 and removed on 2027-03-01; " ++
            "call note.save instead. Same input, under the new name.",
        comptime deprecation_text(Old),
    );
    try std.testing.expect(comptime deprecation(Plain) == null);
    try std.testing.expectEqualStrings("", comptime deprecation_text(Plain));
}

test "a removal day is written YYYY-MM-DD" {
    try std.testing.expect(valid_day("2027-03-01"));
    try std.testing.expect(!valid_day("2027-3-1"));
    try std.testing.expect(!valid_day("2027-13-01"));
    try std.testing.expect(!valid_day("2027-03-00"));
    try std.testing.expect(!valid_day("next march"));
}
