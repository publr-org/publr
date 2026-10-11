//! A gettext PO file as its messages: `msgctxt`, `msgid`, `msgid_plural`, `msgstr` and
//! `msgstr[n]`, strings continued over lines, the usual escapes. Comments are skipped; a
//! message marked `#, fuzzy` is left out, as gettext leaves it out; one with no translation
//! is left out too. The header (the empty `msgid`) gives `Plural-Forms`' `nplurals`.
const std = @import("std");

pub const forms_max: u32 = 6;
pub const messages_max: u32 = 65_536;

pub const Message = struct {
    context: []const u8 = "",
    id: []const u8,
    plural: []const u8 = "",
    /// One translation, or one per plural form in gettext's order.
    forms: []const []const u8,
};

pub const File = struct {
    messages: []const Message,
    /// `nplurals` from the header, null when it says nothing.
    plurals: ?u32 = null,
};

pub const Error = error{ Invalid, OutOfMemory };

const Field = enum { none, context, id, plural, form };

const Builder = struct {
    arena: std.mem.Allocator,
    context: std.ArrayList(u8) = .empty,
    id: std.ArrayList(u8) = .empty,
    plural: std.ArrayList(u8) = .empty,
    forms: [forms_max]std.ArrayList(u8) = @splat(.empty),
    forms_len: u32 = 0,
    field: Field = .none,
    form: u32 = 0,
    fuzzy: bool = false,
    started: bool = false,
};

/// Every message the file translates. Text is copied into `arena`.
pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!File {
    std.debug.assert(text.len <= 64 << 20);

    var builder: Builder = .{
        .arena = arena,
    };
    var messages: std.ArrayList(Message) = .empty;
    var plurals: ?u32 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");

        if (line.len == 0) {
            continue;
        }

        if (line[0] == '#') {
            if (std.mem.startsWith(u8, line, "#,") and std.mem.indexOf(u8, line, "fuzzy") != null) {
                try finish(&builder, &messages, &plurals);
                builder.fuzzy = true;
            }

            continue;
        }

        try take_line(&builder, &messages, &plurals, line);
    }

    try finish(&builder, &messages, &plurals);

    return .{
        .messages = messages.items,
        .plurals = plurals,
    };
}

fn take_line(
    builder: *Builder,
    messages: *std.ArrayList(Message),
    plurals: *?u32,
    line: []const u8,
) Error!void {
    std.debug.assert(line.len > 0);

    if (line[0] == '"') {
        if (builder.field == .none) {
            return error.Invalid;
        }

        return append(builder, current(builder), line);
    }

    const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.Invalid;
    const keyword = line[0..space];
    const rest = std.mem.trim(u8, line[space + 1 ..], " ");
    const starts = std.mem.eql(u8, keyword, "msgctxt") or
        (std.mem.eql(u8, keyword, "msgid") and builder.field != .context);

    if (starts) {
        try finish(builder, messages, plurals);
    }

    builder.started = true;
    builder.field = try field_of(builder, keyword);

    try append(builder, current(builder), rest);
}

fn field_of(builder: *Builder, keyword: []const u8) Error!Field {
    std.debug.assert(keyword.len > 0);

    if (std.mem.eql(u8, keyword, "msgctxt")) {
        return .context;
    }

    if (std.mem.eql(u8, keyword, "msgid")) {
        return .id;
    }

    if (std.mem.eql(u8, keyword, "msgid_plural")) {
        return .plural;
    }

    if (std.mem.eql(u8, keyword, "msgstr")) {
        builder.form = 0;
    } else if (std.mem.startsWith(u8, keyword, "msgstr[") and keyword[keyword.len - 1] == ']') {
        const number = keyword["msgstr[".len .. keyword.len - 1];

        builder.form = std.fmt.parseInt(u32, number, 10) catch return error.Invalid;
    } else {
        return error.Invalid;
    }

    if (builder.form >= forms_max) {
        return error.Invalid;
    }

    builder.forms_len = @max(builder.forms_len, builder.form + 1);

    return .form;
}

fn current(builder: *Builder) *std.ArrayList(u8) {
    std.debug.assert(builder.field != .none);
    std.debug.assert(builder.form < forms_max);

    return switch (builder.field) {
        .context => &builder.context,
        .id => &builder.id,
        .plural => &builder.plural,
        .form => &builder.forms[builder.form],
        .none => unreachable,
    };
}

/// A quoted string, unescaped, onto `out`.
fn append(builder: *Builder, out: *std.ArrayList(u8), quoted: []const u8) Error!void {
    std.debug.assert(quoted.len <= 64 << 20);

    if (quoted.len < 2 or quoted[0] != '"' or quoted[quoted.len - 1] != '"') {
        return error.Invalid;
    }

    const inner = quoted[1 .. quoted.len - 1];
    var index: usize = 0;

    while (index < inner.len) : (index += 1) {
        var char = inner[index];

        if (char == '\\') {
            index += 1;

            if (index == inner.len) {
                return error.Invalid;
            }

            char = switch (inner[index]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '"' => '"',
                '\\' => '\\',
                else => return error.Invalid,
            };
        }

        out.append(builder.arena, char) catch return error.OutOfMemory;
    }
}

/// The message gathered so far, kept when it is translated and not fuzzy.
fn finish(builder: *Builder, messages: *std.ArrayList(Message), plurals: *?u32) Error!void {
    std.debug.assert(builder.forms_len <= forms_max);

    // A `#, fuzzy` before a message marks the one to come: nothing to reset yet.
    if (!builder.started) {
        return;
    }

    defer reset(builder);

    if (builder.id.items.len == 0) {
        plurals.* = plurals_of(builder.forms[0].items) orelse plurals.*;

        return;
    }

    if (builder.fuzzy or builder.forms_len == 0 or messages.items.len == messages_max) {
        return;
    }

    const forms = builder.arena.alloc([]const u8, builder.forms_len) catch return error.OutOfMemory;

    for (forms, builder.forms[0..builder.forms_len]) |*form, text| {
        if (text.items.len == 0) {
            return;
        }

        form.* = text.items;
    }

    messages.append(builder.arena, .{
        .context = builder.context.items,
        .id = builder.id.items,
        .plural = builder.plural.items,
        .forms = forms,
    }) catch return error.OutOfMemory;
}

fn reset(builder: *Builder) void {
    std.debug.assert(builder.forms_len <= forms_max);

    builder.* = .{
        .arena = builder.arena,
    };
}

/// `nplurals=3` out of the header's `Plural-Forms:` line.
fn plurals_of(header: []const u8) ?u32 {
    std.debug.assert(header.len <= 64 << 20);

    const at = std.mem.indexOf(u8, header, "nplurals=") orelse return null;
    const digits = header[at + "nplurals=".len ..];
    var end: usize = 0;

    while (end < digits.len and std.ascii.isDigit(digits[end])) : (end += 1) {}

    return std.fmt.parseInt(u32, digits[0..end], 10) catch null;
}

test "messages, plurals, contexts, continued strings, escapes; fuzzy and empty left out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\msgid ""
        \\msgstr ""
        \\"Language: pl\n"
        \\"Plural-Forms: nplurals=3; plural=(n==1 ? 0 : n%10>=2 && n%10<=4 && "
        \\"(n%100<12 || n%100>14) ? 1 : 2);\n"
        \\
        \\#: ui/pages/Trash.ptsx:46
        \\msgid "Empty trash"
        \\msgstr "Opróżnij kosz"
        \\
        \\msgctxt "verb"
        \\msgid "Post"
        \\msgstr "Opublikuj"
        \\
        \\msgid "{count} file"
        \\msgid_plural "{count} files"
        \\msgstr[0] "{count} plik"
        \\msgstr[1] "{count} pliki"
        \\msgstr[2] "{count} plików"
        \\
        \\msgid "Say \"hi\"\nthere"
        \\msgstr ""
        \\"Powiedz \"cześć\"\n"
        \\"tam"
        \\
        \\#, fuzzy
        \\msgid "Draft"
        \\msgstr "Szkic"
        \\
        \\msgid "Untranslated"
        \\msgstr ""
    ;
    const file = try parse(arena, text);

    try std.testing.expectEqual(@as(?u32, 3), file.plurals);
    try std.testing.expectEqual(@as(usize, 4), file.messages.len);
    try std.testing.expectEqualStrings("Opróżnij kosz", file.messages[0].forms[0]);
    try std.testing.expectEqualStrings("verb", file.messages[1].context);
    try std.testing.expectEqualStrings("{count} plików", file.messages[2].forms[2]);
    try std.testing.expectEqualStrings("{count} files", file.messages[2].plural);
    try std.testing.expectEqualStrings("Say \"hi\"\nthere", file.messages[3].id);
    try std.testing.expectEqualStrings("Powiedz \"cześć\"\ntam", file.messages[3].forms[0]);
    try std.testing.expectError(error.Invalid, parse(arena, "msgid \"x\nmsgstr \"y\""));
    try std.testing.expectError(error.Invalid, parse(arena, "msgstr[9] \"y\""));
}
