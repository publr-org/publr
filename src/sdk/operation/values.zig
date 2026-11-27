//! The rule that an operation's input and output hold values: a record, a list or a map is
//! declared as a value (`operation.Json` where its shape is data, a struct where it is
//! known), never as text whose content is JSON. The one exception an operation declares:
//! `pub const verbatim = .{"body"};` names text another system wrote or will read, passed
//! through as its bytes and never read here (an HTTP body).

const std = @import("std");

/// The bytes of a doc line the rule reads.
pub const doc_len_max: u32 = 200;
/// How deep the rule follows an example into its lists and structs.
const depth_max: u32 = 8;
/// The items of one list of an example the rule reads.
const items_max: u32 = 8;
/// Branches reading one value of an example takes: the value looked into, its text read for
/// JSON at its ends.
const branches_per_value: u32 = 64;
/// Branches reading one byte of an example written as JSON takes.
const branches_per_byte: u32 = 8;

/// Whether `text` is a JSON object or array, told by its ends: `{` then a key or `}`, or `[`
/// then a value or `]`. `{secret:NAME}` and `[a-z]+` are neither.
pub fn holds_json(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");

    std.debug.assert(trimmed.len <= text.len);

    if (trimmed.len < 2) {
        return false;
    }

    const last = trimmed[trimmed.len - 1];
    const spaced = std.mem.trimStart(u8, trimmed[1..], " \t\r\n");
    // Text read from inside a JSON string, as an example is written, keeps `\"` for `"`.
    const inner = if (spaced.len > 1 and spaced[0] == '\\') spaced[1..] else spaced;

    std.debug.assert(inner.len > 0);

    return switch (trimmed[0]) {
        '{' => last == '}' and (inner[0] == '"' or inner[0] == '}'),
        '[' => last == ']' and starts_value(inner),
        else => false,
    };
}

fn starts_value(text: []const u8) bool {
    std.debug.assert(text.len > 0);
    std.debug.assert(!std.ascii.isWhitespace(text[0]));

    return switch (text[0]) {
        '"', '{', '[', ']', '-', '0'...'9' => true,
        't' => std.mem.startsWith(u8, text, "true"),
        'f' => std.mem.startsWith(u8, text, "false"),
        'n' => std.mem.startsWith(u8, text, "null"),
        else => false,
    };
}

/// Whether a field's doc line says the field holds JSON: the word `JSON` in it.
pub fn says_json(doc: []const u8) bool {
    const read = doc[0..@min(doc.len, doc_len_max)];
    var from: u32 = 0;

    std.debug.assert(read.len <= doc_len_max);

    while (std.mem.indexOfScalarPos(u8, read, from, 'J')) |at| {
        const word = std.mem.startsWith(u8, read[at..], "JSON");
        const begins = at == 0 or !std.ascii.isAlphanumeric(read[at - 1]);
        const ends = at + 4 >= read.len or !std.ascii.isAlphanumeric(read[at + 4]);

        if (word and begins and ends) {
            return true;
        }

        from = @intCast(at + 1);
    }

    std.debug.assert(from <= read.len);

    return false;
}

fn is_text(comptime Type: type) bool {
    return Type == []const u8 or Type == ?[]const u8;
}

/// Whether `Operation` declares `name` as another system's text, passed through.
fn verbatim(comptime Operation: type, comptime name: []const u8) bool {
    comptime {
        std.debug.assert(name.len > 0);
        std.debug.assert(Operation.name.len > 0);

        if (!@hasDecl(Operation, "verbatim")) {
            return false;
        }

        for (Operation.verbatim) |declared| {
            if (std.mem.eql(u8, declared, name)) {
                return true;
            }
        }

        return false;
    }
}

/// The field of `value` holding JSON as text, as `items.document`, or null. `value` is an
/// operation's `example` or `example_out`; `spent` is the quota so far, raised by each value
/// read, so the walk spends what the example holds.
fn json_text_in(
    comptime Operation: type,
    comptime value: anytype,
    comptime depth: u32,
    spent: *u32,
) ?[]const u8 {
    comptime {
        const Type = @TypeOf(value);

        spent.* +|= branches_per_value;
        @setEvalBranchQuota(spent.*);

        if (depth > depth_max) {
            return null;
        }

        switch (@typeInfo(Type)) {
            .optional => {
                const inner = value orelse return null;

                return json_text_in(Operation, inner, depth + 1, spent);
            },
            .pointer => |pointer| {
                if (pointer.size != .slice or pointer.child == u8) {
                    return null;
                }

                for (value[0..@min(value.len, items_max)]) |item| {
                    if (json_text_in(Operation, item, depth + 1, spent)) |found| {
                        return found;
                    }
                }

                return null;
            },
            .@"struct" => |structure| {
                if (@hasDecl(Type, "reference") or @hasDecl(Type, "json_object")) {
                    return null;
                }

                spent.* +|= structure.field_names.len * branches_per_value;
                @setEvalBranchQuota(spent.*);

                for (structure.field_names, structure.field_types) |name, Field| {
                    const field = @field(value, name);

                    if (depth == 0 and verbatim(Operation, name)) {
                        continue;
                    }

                    if (is_text(Field)) {
                        const text: ?[]const u8 = field;

                        if (text != null and holds_json(text.?)) {
                            return name;
                        }
                    } else if (json_text_in(Operation, field, depth + 1, spent)) |found| {
                        return name ++ "." ++ found;
                    }
                }

                return null;
            },
            else => return null,
        }
    }
}

/// The key of the first text in `json` that holds JSON, or null. `json` is an example as
/// its operation's words write it: read once, a byte at a time.
pub fn json_text_written(json: []const u8) ?[]const u8 {
    var key: []const u8 = "";
    var at: usize = 0;

    while (std.mem.indexOfScalarPos(u8, json, at, '"')) |opening| {
        var closing = opening + 1;

        while (closing < json.len and json[closing] != '"') {
            closing += if (json[closing] == '\\') 2 else 1;
        }

        const text = json[opening + 1 .. @min(closing, json.len)];
        const rest = std.mem.trimStart(u8, json[@min(closing + 1, json.len)..], " \t\r\n");

        if (rest.len > 0 and rest[0] == ':') {
            key = text;
        } else if (holds_json(text)) {
            return key;
        }

        at = @min(closing + 1, json.len);
    }

    std.debug.assert(at <= json.len);

    return null;
}

/// The text field of `Shape` whose doc line says it holds JSON, or null.
pub fn json_text_said(
    comptime Operation: type,
    comptime Shape: type,
    comptime docs: anytype,
) ?[]const u8 {
    comptime {
        const structure = @typeInfo(Shape).@"struct";

        for (structure.field_names, structure.field_types) |name, Field| {
            const said = is_text(Field) and says_json(@field(docs, name));

            if (said and !verbatim(Operation, name)) {
                return name;
            }
        }

        return null;
    }
}

/// The text holding JSON in an operation's example and in its answer's, each read in an
/// evaluation of its own that spends what the example holds.
fn Examples(comptime Operation: type) type {
    return struct {
        const in: ?[]const u8 = example_text(Operation, "example_json", "example");
        const out: ?[]const u8 = example_text(Operation, "example_out_json", "example_out");
    };
}

/// A plugin's operation writes its examples as JSON: read as written, a byte at a time,
/// never built. Core's are values, read a value at a time.
fn example_text(
    comptime Operation: type,
    comptime written_name: []const u8,
    comptime value_name: []const u8,
) ?[]const u8 {
    comptime {
        std.debug.assert(written_name.len > value_name.len);

        if (@hasDecl(Operation, "example_json")) {
            const written: []const u8 = @field(Operation, written_name);

            @setEvalBranchQuota(1000 + written.len * branches_per_byte);

            return json_text_written(written);
        }

        var spent: u32 = 1000;
        const found = json_text_in(Operation, @field(Operation, value_name), 0, &spent);

        std.debug.assert(spent > 1000);

        return found;
    }
}

/// What breaks the rule in `Operation`, for the compiler to say, or null.
pub fn problem(comptime Operation: type) ?[]const u8 {
    comptime {
        std.debug.assert(Operation.name.len > 0);

        const said_in = if (@hasDecl(Operation, "field_docs"))
            json_text_said(Operation, Operation.In, Operation.field_docs)
        else
            null;
        const said_out = if (@hasDecl(Operation, "output_docs"))
            json_text_said(Operation, Operation.Out, Operation.output_docs)
        else
            null;
        const held_in: ?[]const u8 = Examples(Operation).in;
        const held_out: ?[]const u8 = Examples(Operation).out;
        const in: ?[]const u8 = held_in orelse said_in;
        const out: ?[]const u8 = held_out orelse said_out;
        const side = if (in != null) "input" else "output";
        const either: ?[]const u8 = if (in != null) in else out;
        const found = either orelse return null;

        std.debug.assert(found.len > 0);

        return Operation.name ++ ": `" ++ found ++ "` of its " ++ side ++ " is text holding " ++
            "JSON; declare a value (`operation.Json` where the shape is data, a struct " ++
            "where it is known)";
    }
}

test "text holds JSON when it opens and closes as an object or an array" {
    const holding = [_][]const u8{
        "{}",
        " {\"a\":1} ",
        "[]",
        "[1,2]",
        "[\"a\"]",
        "[{\"a\":1}]",
        "[true]",
    };
    const plain = [_][]const u8{
        "",
        "{",
        "plain",
        "{secret:SMTP_PASSWORD}",
        "[a-z][a-z0-9_]*",
        "12",
    };

    for (holding) |text| {
        try std.testing.expect(holds_json(text));
    }

    for (plain) |text| {
        try std.testing.expect(!holds_json(text));
    }
}

test "an example as written names the key whose text holds JSON" {
    const held = "{ \"id\": \"a\", \"request\": \"{\\\"messages\\\":[]}\" }";
    const listed = "{ \"rows\": [\"[1,2]\"] }";
    const plain = "{ \"note\": \"{secret:KEY}\", \"request\": { \"messages\": [] }, " ++
        "\"tags\": [\"a\"] }";

    try std.testing.expectEqualStrings("request", json_text_written(held).?);
    try std.testing.expectEqualStrings("rows", json_text_written(listed).?);
    try std.testing.expect(json_text_written(plain) == null);
    try std.testing.expect(json_text_written("") == null);
    try std.testing.expect(json_text_written("{ \"cut\": \"off") == null);
}

test "a doc line says JSON by the word alone" {
    try std.testing.expect(says_json("The record, a JSON object"));
    try std.testing.expect(says_json("JSON"));
    try std.testing.expect(!says_json("The record's id"));
    try std.testing.expect(!says_json("A JSONPath to the value"));
    try std.testing.expect(!says_json(""));
}

test "an operation with JSON in a text field is named with the field" {
    const Item = struct {
        id: []const u8,
        document: []const u8,
    };
    const Listed = struct {
        pub const name = "note.list";
        pub const In = struct {
            filter: ?[]const u8 = null,
        };
        pub const Out = struct {
            items: []const Item,
        };
        pub const example: In = .{};
        pub const example_out: Out = .{
            .items = &.{.{
                .id = "a",
                .document = "{\"title\":\"Hello\"}",
            }},
        };
    };
    const Said = struct {
        pub const name = "note.find";
        pub const In = struct {
            filter: ?[]const u8 = null,
        };
        pub const Out = struct {
            count: u32,
        };
        pub const example: In = .{};
        pub const example_out: Out = .{
            .count = 1,
        };
        pub const field_docs = .{
            .filter = "What to match, a JSON object",
        };
    };
    const Plain = struct {
        pub const name = "note.count";
        pub const In = Said.In;
        pub const Out = Said.Out;
        pub const example: In = .{
            .filter = "status = draft",
        };
        pub const example_out: Out = Said.example_out;
    };

    const listed = comptime problem(Listed).?;
    const said = comptime problem(Said).?;

    try std.testing.expect(std.mem.indexOf(u8, listed, "`items.document` of its output") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "note.find: `filter` of its input") != null);
    try std.testing.expect(comptime problem(Plain) == null);
}
