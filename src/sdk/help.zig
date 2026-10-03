const std = @import("std");
const operation = @import("operation.zig");
const authorize = @import("authorize.zig");

pub const Error = error{WriteFailed};

const text_len_max: u32 = 64 << 10;

/// `publr <namespace> <verb> --help`: what it does, its fields and output, how it fails,
/// an example to paste. The same text whether the operation is compiled in or installed.
pub fn command(comptime Operation: type, out: *std.Io.Writer) Error!void {
    @setEvalBranchQuota(100_000);

    const namespace = comptime operation.namespace(Operation.name);
    const verb = comptime operation.verb(Operation.name);
    const fields = std.meta.fields(Operation.In);
    const signature = if (fields.len == 0) "" else " [--field value ...]";

    comptime std.debug.assert(namespace.len > 0);
    comptime std.debug.assert(verb.len > 0);

    out.print("Usage: publr {s} {s}{s}\n\n{s}\n", .{
        namespace,
        verb,
        signature,
        Operation.description,
    }) catch return error.WriteFailed;

    if (@hasDecl(Operation, "details")) {
        out.print("\n{s}\n", .{Operation.details}) catch return error.WriteFailed;
    }

    if (fields.len > 0) {
        write(out, "\nFields:\n") catch return error.WriteFailed;
        try print_field_docs(Operation, Operation.In, "field_docs", true, out);
    }

    write(out, "\nOutput:\n") catch return error.WriteFailed;
    try print_field_docs(Operation, Operation.Out, "output_docs", false, out);
    try print_failures(Operation, out);
    try print_example(Operation, out);
}

/// The failures the operation declares beyond the core's errors, as REST names them.
fn print_failures(comptime Operation: type, out: *std.Io.Writer) Error!void {
    comptime std.debug.assert(Operation.name.len > 0);

    if (!@hasDecl(Operation, "failures") or Operation.failures.len == 0) {
        return;
    }

    write(out, "\nFails with:\n") catch return error.WriteFailed;

    for (Operation.failures) |failure| {
        out.print("\n  {s} ({d})  {s}\n", .{
            failure.name,
            failure.status,
            failure.message,
        }) catch return error.WriteFailed;
    }
}

fn print_field_docs(
    comptime Operation: type,
    comptime Shape: type,
    comptime docs_name: []const u8,
    comptime is_input: bool,
    out: *std.Io.Writer,
) Error!void {
    comptime std.debug.assert(docs_name.len > 0);
    comptime std.debug.assert(@typeInfo(Shape) == .@"struct");

    inline for (std.meta.fields(Shape)) |field| {
        const doc = comptime operation.field_doc(Operation, docs_name, field.name);
        const prefix = if (is_input) "--" else "";
        const presence = if (!is_input)
            ""
        else if (field.defaultValue() == null)
            "  (required)"
        else
            "  (optional)";

        out.print("\n  {s}{s}  {s}{s}\n", .{
            prefix,
            field.name,
            type_label(field.type),
            presence,
        }) catch return error.WriteFailed;

        if (doc.len > 0) {
            out.print("      {s}\n", .{doc}) catch return error.WriteFailed;
        }

        const rule = comptime rule_of(Operation, field.name, is_input);

        if (rule.len > 0) {
            out.print("      {s}\n", .{rule}) catch return error.WriteFailed;
        }
    }
}

/// An input field's declared rule in words: `1 to 20`, `up to 80 characters`.
fn rule_of(
    comptime Operation: type,
    comptime field: []const u8,
    comptime is_input: bool,
) []const u8 {
    comptime {
        std.debug.assert(field.len > 0);

        if (!is_input or !@hasDecl(Operation, "rules")) {
            return "";
        }

        if (!@hasField(@TypeOf(Operation.rules), field)) {
            return "";
        }

        const rule = @field(Operation.rules, field);
        var words: []const u8 = "";

        words = words ++ bounds("", rule.min, rule.max);
        words = words ++ bounds(" characters", rule.min_len, rule.max_len);
        words = words ++ bounds(" items", rule.items_min, rule.items_max);

        if (rule.preset != .any) {
            words = words ++ (if (words.len > 0) "; " else "") ++ @tagName(rule.preset);
        }

        if (rule.pattern.len > 0) {
            words = words ++ (if (words.len > 0) "; " else "") ++ "like " ++ rule.pattern;
        }

        return words;
    }
}

fn bounds(comptime unit: []const u8, comptime low: anytype, comptime high: anytype) []const u8 {
    comptime {
        std.debug.assert(unit.len < 16);

        if (low != null and high != null) {
            return std.fmt.comptimePrint("{d} to {d}{s}", .{ low.?, high.?, unit });
        }

        if (low) |least| {
            return std.fmt.comptimePrint("at least {d}{s}", .{ least, unit });
        }

        if (high) |most| {
            return std.fmt.comptimePrint("up to {d}{s}", .{ most, unit });
        }

        return "";
    }
}

fn print_example(comptime Operation: type, out: *std.Io.Writer) Error!void {
    @setEvalBranchQuota(100_000);

    const namespace = comptime operation.namespace(Operation.name);
    const verb = comptime operation.verb(Operation.name);
    const declared_open = @hasDecl(Operation, "open") and Operation.open;
    const anonymous_ok = declared_open or authorize.is_open_operation(Operation.name) or
        (Operation.kind == .read and
            authorize.is_public_read_namespace(Operation.name));
    const operator = @hasDecl(Operation, "operator_only") and Operation.operator_only;
    const as: []const u8 = if (operator)
        "--as-admin "
    else if (anonymous_ok)
        ""
    else
        "--as ada@example.com ";

    comptime std.debug.assert(namespace.len > 0);
    comptime std.debug.assert(verb.len > 0);

    out.print("\nExample:\n\n  $ publr {s}{s} {s}", .{ as, namespace, verb }) catch
        return error.WriteFailed;

    inline for (std.meta.fields(Operation.In)) |field| {
        const value = @field(Operation.example, field.name);
        const is_default = comptime blk: {
            const default = field.defaultValue() orelse break :blk false;
            break :blk std.meta.eql(default, value);
        };

        if (!is_default and !is_null(value)) {
            out.print(" --{s} ", .{field.name}) catch return error.WriteFailed;
            try print_example_value(value, out);
        }
    }

    write(out, "\n") catch return error.WriteFailed;

    var buffer: [8 << 10]u8 = undefined;
    var json: std.Io.Writer = .fixed(&buffer);
    const options: std.json.Stringify.Options = .{ .whitespace = .indent_2 };

    std.json.Stringify.value(Operation.example_out, options, &json) catch
        return error.WriteFailed;

    var lines = std.mem.splitScalar(u8, json.buffered(), '\n');

    while (lines.next()) |line| {
        out.print("  {s}\n", .{line}) catch return error.WriteFailed;
    }
}

/// A value as you would type it: JSON and anything with a space or a quote in it
/// goes on one line inside single quotes, so the printed line can be pasted; text
/// with an apostrophe (`Ada's App`) goes inside double quotes instead. An example
/// with both an apostrophe and a character double quotes would expand is refused.
fn print_example_text(text: []const u8, out: *std.Io.Writer) Error!void {
    std.debug.assert(text.len <= text_len_max);

    if (std.mem.indexOfScalar(u8, text, '\'') != null) {
        std.debug.assert(std.mem.indexOfAny(u8, text, "\"$`\\\n") == null);

        out.print("\"{s}\"", .{text}) catch return error.WriteFailed;

        return;
    }

    if (std.mem.indexOfAny(u8, text, " \"\n") == null) {
        write(out, text) catch return error.WriteFailed;

        return;
    }

    write(out, "'") catch return error.WriteFailed;

    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |line| {
        write(out, line) catch return error.WriteFailed;
    }

    write(out, "'") catch return error.WriteFailed;
}

/// A list as you would type it: its items with commas between, no spaces.
fn print_example_list(items: anytype, out: *std.Io.Writer) Error!void {
    std.debug.assert(items.len <= 64);
    std.debug.assert(items.len > 0);

    for (items, 0..) |item, index| {
        if (index > 0) {
            write(out, ",") catch return error.WriteFailed;
        }

        try print_example_value(item, out);
    }
}

fn print_example_value(value: anytype, out: *std.Io.Writer) Error!void {
    const Value = @TypeOf(value);

    comptime std.debug.assert(@typeInfo(Value) != .void);

    switch (@typeInfo(Value)) {
        .bool => write(out, if (value) "true" else "false") catch return error.WriteFailed,
        .int, .float => out.print("{d}", .{value}) catch return error.WriteFailed,
        .@"enum" => write(out, @tagName(value)) catch return error.WriteFailed,
        .optional => try print_example_value(value.?, out),
        .pointer => |pointer| if (pointer.child == u8)
            try print_example_text(value, out)
        else if (comptime listable(pointer.child))
            try print_example_list(value, out)
        else
            try print_example_json(value, out),
        .@"struct", .@"union" => try print_example_json(value, out),
        else => @compileError("example value: unsupported"),
    }
}

fn print_example_json(value: anytype, out: *std.Io.Writer) Error!void {
    std.debug.assert(out.buffer.len > 0 or out.end == 0);

    write(out, "'") catch return error.WriteFailed;
    std.json.Stringify.value(value, .{}, out) catch return error.WriteFailed;
    write(out, "'") catch return error.WriteFailed;
}

/// Whether a list of it is written comma-separated (`a,b`): text and names. Any other list,
/// as any structure, is written as JSON.
pub fn listable(comptime Value: type) bool {
    comptime std.debug.assert(@typeInfo(Value) != .@"fn");

    return switch (@typeInfo(Value)) {
        .@"enum" => true,
        .pointer => |pointer| pointer.child == u8,
        else => false,
    };
}

fn is_null(value: anytype) bool {
    const Value = @TypeOf(value);

    comptime std.debug.assert(@typeInfo(Value) != .void);

    return switch (@typeInfo(Value)) {
        .optional => value == null,
        else => false,
    };
}

pub fn type_label(comptime Type: type) []const u8 {
    return type_label_depth(Type, 0);
}

fn type_label_depth(comptime Type: type, comptime depth: u32) []const u8 {
    @setEvalBranchQuota(100_000);

    if (depth > 3) {
        return "object";
    }

    const label: []const u8 = comptime switch (@typeInfo(Type)) {
        .bool => "true|false",
        .int => "integer",
        .float => "number",
        .@"enum" => |info| blk: {
            var joined: []const u8 = "";

            for (info.fields, 0..) |field, index| {
                joined = joined ++ (if (index == 0) "" else "|") ++ field.name;
            }

            break :blk joined;
        },
        .optional => |optional| type_label_depth(optional.child, depth + 1) ++ "|null",
        .pointer => |pointer| if (pointer.child == u8)
            "text"
        else
            "list of " ++ type_label_depth(pointer.child, depth + 1),
        .@"struct" => |info| if (@hasDecl(Type, "reference")) "id of " ++ Type.handle else blk: {
            var joined: []const u8 = "{ ";

            for (info.fields, 0..) |field, index| {
                const separator = if (index == 0) "" else ", ";
                joined = joined ++ separator ++ field.name ++ ": " ++ type_label_depth(
                    field.type,
                    depth + 1,
                );
            }

            break :blk joined ++ " }";
        },
        else => "value",
    };

    comptime std.debug.assert(label.len > 0);
    comptime std.debug.assert(label.len < 4096);

    return label;
}

fn write(out: *std.Io.Writer, text: []const u8) !void {
    try out.writeAll(text);
}

test "an example value prints the way a shell reads it, apostrophes inside double quotes" {
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    try print_example_text("plain", &out);
    try out.writeByte(' ');
    try print_example_text("two words", &out);
    try out.writeByte(' ');
    try print_example_text("Ada's App", &out);
    try std.testing.expectEqualStrings("plain 'two words' \"Ada's App\"", out.buffered());
}
