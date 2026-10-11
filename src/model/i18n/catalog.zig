//! One language's messages: every PO file the plugins bring for it, merged, looked up by
//! context and source text. A message's plural form for a count is chosen by the
//! language's rule (`plural.zig`). Built once when the server starts; read by every render.
const std = @import("std");
const po = @import("po.zig");
const plural = @import("plural.zig");

pub const Error = po.Error || error{PluralForms};

/// A PO file and who brings it. A first-party file (the words' owner's own translation)
/// wins over the others; among equals, the first.
pub const Source = struct {
    provider: []const u8,
    first_party: bool = false,
    po: []const u8,
};

/// A message translated as someone chose, over what precedence would pick: from Site Health.
pub const Choice = struct {
    context: []const u8 = "",
    id: []const u8,
    provider: []const u8,
};

pub const Catalog = struct {
    locale: []const u8,
    rule: plural.Rule,
    map: std.StringHashMapUnmanaged([]const []const u8) = .empty,

    /// The language's messages from `sources`, first-party ones first, then `choices` over
    /// them. A file whose header disagrees with the language on how many plural forms there
    /// are is refused: its translations would land on the wrong counts.
    pub fn init(
        arena: std.mem.Allocator,
        locale: []const u8,
        sources: []const Source,
        choices: []const Choice,
    ) Error!Catalog {
        std.debug.assert(locale.len > 0);
        std.debug.assert(sources.len <= 1024);

        var catalog: Catalog = .{
            .locale = locale,
            .rule = plural.rule_of(locale),
        };
        const passes = [_]bool{ true, false };

        for (passes) |first_party| {
            for (sources) |source| {
                if (source.first_party == first_party) {
                    try catalog.take(arena, source.po, false);
                }
            }
        }

        for (choices) |choice| {
            try catalog.choose(arena, sources, choice);
        }

        return catalog;
    }

    fn take(
        catalog: *Catalog,
        arena: std.mem.Allocator,
        po_text: []const u8,
        replace: bool,
    ) Error!void {
        std.debug.assert(catalog.locale.len > 0);

        const file = try po.parse(arena, po_text);

        if (file.plurals) |declared| {
            if (declared != plural.forms(catalog.rule)) {
                return error.PluralForms;
            }
        }

        for (file.messages) |message| {
            try catalog.add(arena, message, replace);
        }
    }

    /// The chosen provider's translation of one message, when it still has one.
    fn choose(
        catalog: *Catalog,
        arena: std.mem.Allocator,
        sources: []const Source,
        choice: Choice,
    ) Error!void {
        std.debug.assert(choice.id.len > 0);

        for (sources) |source| {
            if (!std.mem.eql(u8, source.provider, choice.provider)) {
                continue;
            }

            const file = try po.parse(arena, source.po);

            for (file.messages) |message| {
                const same = std.mem.eql(u8, message.context, choice.context) and
                    std.mem.eql(u8, message.id, choice.id);

                if (same) {
                    try catalog.add(arena, message, true);

                    return;
                }
            }
        }
    }

    fn add(
        catalog: *Catalog,
        arena: std.mem.Allocator,
        message: po.Message,
        replace: bool,
    ) Error!void {
        std.debug.assert(message.id.len > 0);
        std.debug.assert(message.forms.len > 0);

        const key = try key_of(arena, message.context, message.id);
        const entry = catalog.map.getOrPut(arena, key) catch return error.OutOfMemory;

        if (!entry.found_existing or replace) {
            entry.value_ptr.* = message.forms;
        }
    }

    /// The translated text, the form for `count` when the message has a plural (and the
    /// catalogue its forms); null when the catalogue does not have it.
    pub fn lookup(
        catalog: *const Catalog,
        context: []const u8,
        id: []const u8,
        count: ?f64,
    ) ?[]const u8 {
        std.debug.assert(id.len > 0);

        var buffer: [1024]u8 = undefined;
        const key = key_in(&buffer, context, id) orelse return null;
        const forms = catalog.map.get(key) orelse return null;
        const form = if (count) |number| plural.index(catalog.rule, number) else 0;

        return if (form < forms.len) forms[form] else null;
    }

    pub fn messages(catalog: *const Catalog) u32 {
        std.debug.assert(catalog.locale.len > 0);

        return catalog.map.count();
    }
};

const separator = "\x04";

fn key_of(arena: std.mem.Allocator, context: []const u8, id: []const u8) Error![]const u8 {
    std.debug.assert(id.len > 0);

    if (context.len == 0) {
        return id;
    }

    return std.mem.concat(arena, u8, &.{ context, separator, id }) catch error.OutOfMemory;
}

fn key_in(buffer: *[1024]u8, context: []const u8, id: []const u8) ?[]const u8 {
    std.debug.assert(id.len > 0);

    if (context.len == 0) {
        return id;
    }

    return std.fmt.bufPrint(buffer, "{s}" ++ separator ++ "{s}", .{ context, id }) catch null;
}

test "messages looked up by context and text, plural forms by the language's rule" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pack =
        \\msgid ""
        \\msgstr "Plural-Forms: nplurals=3; plural=...;\n"
        \\
        \\msgid "Save"
        \\msgstr "Zapisz"
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
    ;
    const own =
        \\msgid "Save"
        \\msgstr "Zachowaj"
        \\
        \\msgid "Trash"
        \\msgstr "Kosz"
    ;
    const catalog = try Catalog.init(arena, "pl", &.{
        .{
            .provider = "pack",
            .po = pack,
        },
        .{
            .provider = "plugin",
            .first_party = true,
            .po = own,
        },
    }, &.{});

    try std.testing.expectEqualStrings("Zachowaj", catalog.lookup("", "Save", null).?);
    try std.testing.expectEqualStrings("Kosz", catalog.lookup("", "Trash", null).?);
    try std.testing.expectEqualStrings("Opublikuj", catalog.lookup("verb", "Post", null).?);
    try std.testing.expect(catalog.lookup("", "Post", null) == null);
    try std.testing.expectEqualStrings("{count} plik", catalog.lookup("", "{count} file", 1).?);
    try std.testing.expectEqualStrings("{count} pliki", catalog.lookup("", "{count} file", 3).?);
    try std.testing.expectEqualStrings("{count} plików", catalog.lookup("", "{count} file", 12).?);

    const two_forms = "msgid \"\"\nmsgstr \"Plural-Forms: nplurals=2;\\n\"\n";

    try std.testing.expectError(error.PluralForms, Catalog.init(arena, "pl", &.{.{
        .provider = "odd",
        .po = two_forms,
    }}, &.{}));

    const chosen = try Catalog.init(arena, "pl", &.{
        .{
            .provider = "pack",
            .po = pack,
        },
        .{
            .provider = "plugin",
            .first_party = true,
            .po = own,
        },
    }, &.{.{
        .id = "Save",
        .provider = "pack",
    }});

    try std.testing.expectEqualStrings("Zapisz", chosen.lookup("", "Save", null).?);
}
