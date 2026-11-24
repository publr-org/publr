//! A provider slot against its contract's `.with`: what the owner's `<ProviderSlot>` hands
//! over and what a provider's component reads, each checked against the fields `.with` names.
const std = @import("std");
const Node = @import("../../../model/contract.zig").Node;
const Reason = @import("../../../lib/report.zig").Reason;

/// Attributes one slot hands over at most.
pub const attributes_max: u32 = 32;

pub const Error = error{SlotMismatch};

/// One attribute as written: `city="Kraków"` (quoted) or `city={cart.city}`.
const Attribute = struct {
    name: []const u8,
    quoted: bool,
};

/// Every attribute of `others` is a field of `with`, quoted only when the field is text, and
/// every required field is given. A mismatch is the owner's page's mistake: `reason` says it.
pub fn check_slot(
    contract: []const u8,
    others: []const u8,
    with: []const Node,
    reason: ?*Reason,
) Error!void {
    std.debug.assert(contract.len > 0);
    std.debug.assert(with.len > 0);

    var given: [attributes_max]Attribute = undefined;
    const count = try attributes_of(others, &given);

    for (given[0..count]) |attribute| {
        const field = field_of(with, attribute.name) orelse {
            return refuse(reason, contract, attribute.name, "is no field of its `.with`");
        };

        if (attribute.quoted and field.kind != .string) {
            const why = "is quoted, and its `.with` field is no text";

            return refuse(reason, contract, attribute.name, why);
        }
    }

    for (with) |field| {
        if (field.parent != 0 or !field.required) {
            continue;
        }

        const found = for (given[0..count]) |attribute| {
            if (std.mem.eql(u8, attribute.name, field.name)) break true;
        } else false;

        if (!found) {
            return refuse(reason, contract, field.name, "is required by its `.with` and not given");
        }
    }
}

fn refuse(reason: ?*Reason, contract: []const u8, name: []const u8, why: []const u8) Error {
    std.debug.assert(contract.len > 0);
    std.debug.assert(why.len > 0);

    if (reason) |said| {
        said.set("<ProviderSlot contract=\"{s}\">: `{s}` {s}", .{ contract, name, why });
    }

    return error.SlotMismatch;
}

/// The first `props.<name>` the component reads that `with` does not name, when it reads one.
pub fn unknown_prop(text: []const u8, with: []const Node) ?[]const u8 {
    std.debug.assert(with.len > 0);
    std.debug.assert(text.len <= 4 << 20);

    const marker = "props.";
    var at: usize = 0;

    while (std.mem.indexOfPos(u8, text, at, marker)) |found| {
        const start = found + marker.len;
        var end = start;

        while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) {
            end += 1;
        }

        const name = text[start..end];
        const own_word = found == 0 or !(std.ascii.isAlphanumeric(text[found - 1]) or
            text[found - 1] == '_' or text[found - 1] == '.');

        if (own_word and name.len > 0 and field_of(with, name) == null) {
            return name;
        }

        at = end;
    }

    return null;
}

/// The top-level field `name` of `with`, whose root is the object.
fn field_of(with: []const Node, name: []const u8) ?Node {
    std.debug.assert(with.len > 0);
    std.debug.assert(name.len > 0);

    for (with) |node| {
        if (node.parent == 0 and std.mem.eql(u8, node.name, name)) {
            return node;
        }
    }

    return null;
}

/// The attributes written in `others`, in order, into `into`: how many.
fn attributes_of(others: []const u8, into: *[attributes_max]Attribute) Error!u32 {
    std.debug.assert(others.len <= 2048);

    var count: u32 = 0;
    var at: usize = 0;

    while (at < others.len) {
        if (std.ascii.isWhitespace(others[at])) {
            at += 1;
            continue;
        }

        const start = at;

        while (at < others.len and (std.ascii.isAlphanumeric(others[at]) or
            others[at] == '_' or others[at] == '-'))
        {
            at += 1;
        }

        if (at == start or count == attributes_max) {
            return error.SlotMismatch;
        }

        const name = others[start..at];
        var quoted = false;

        if (at < others.len and others[at] == '=') {
            at += 1;
            quoted = at < others.len and (others[at] == '"' or others[at] == '\'');
            at = try value_end(others, @intCast(at));
        }

        into[count] = .{
            .name = name,
            .quoted = quoted,
        };
        count += 1;
    }

    return count;
}

/// Where the value starting at `at` ends: past its closing quote or brace.
fn value_end(text: []const u8, at: u32) Error!u32 {
    std.debug.assert(at <= text.len);

    if (at == text.len) {
        return error.SlotMismatch;
    }

    const opening = text[at];

    if (opening == '"' or opening == '\'') {
        const close = std.mem.indexOfScalarPos(u8, text, at + 1, opening) orelse {
            return error.SlotMismatch;
        };

        return @intCast(close + 1);
    }

    if (opening != '{') {
        return error.SlotMismatch;
    }

    var depth: u32 = 0;
    var index = at;

    while (index < text.len) : (index += 1) {
        if (text[index] == '{') {
            depth += 1;
        } else if (text[index] == '}') {
            depth -= 1;

            if (depth == 0) {
                return @intCast(index + 1);
            }
        }
    }

    return error.SlotMismatch;
}

test "a slot hands over what its contract's with names" {
    const Shape = struct {
        city: []const u8,
        weight: u32 = 0,
    };
    const with = comptime @import("../../../model/contract.zig").describe(Shape);
    var reason: Reason = .{};

    try check_slot("lab.pickup", "city=\"Kraków\" weight={cart.weight}", with, null);
    try check_slot("lab.pickup", "city={cart.city}", with, null);

    try std.testing.expectError(
        error.SlotMismatch,
        check_slot("lab.pickup", "town=\"x\" city=\"y\"", with, &reason),
    );
    try std.testing.expectError(
        error.SlotMismatch,
        check_slot("lab.pickup", "weight=\"3\" city=\"y\"", with, &reason),
    );
    try std.testing.expectError(
        error.SlotMismatch,
        check_slot("lab.pickup", "weight={3}", with, &reason),
    );

    try std.testing.expect(std.mem.indexOf(u8, reason.text(), "`city`") != null);
    try std.testing.expect(unknown_prop("const city = props.city;", with) == null);
    try std.testing.expectEqualStrings("town", unknown_prop("const town = props.town;", with).?);
}
