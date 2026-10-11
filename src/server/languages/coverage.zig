//! How much of each domain's messages each language covers: the core's (`publr`) and each
//! compiled-in plugin's, as the build embedded them, against the language's catalogue.
const std = @import("std");
const model = @import("../../model.zig");
const registry = @import("../registry.zig");
const languages = @import("../languages.zig");

const Language = languages.Language;
const Coverage = @import("../../sdk/context.zig").Coverage;
const Message = @import("../../sdk/context.zig").Message;
/// Every message the admin and the compiled-in plugins mark, `domain\tcontext\tid` a line.
const messages_lines = @import("i18n_messages").lines;

const Domain = struct {
    name: []const u8,
    messages: std.ArrayList(Message) = .empty,
};

/// The embedded messages by domain, in the order the build listed them.
fn domains_of(arena: std.mem.Allocator) ![]Domain {
    std.debug.assert(messages_lines.len <= 64 << 20);

    var domains: std.ArrayList(Domain) = .empty;
    var lines = std.mem.splitScalar(u8, messages_lines, '\n');

    while (lines.next()) |line| {
        var parts = std.mem.splitScalar(u8, line, '\t');
        const name = parts.next() orelse continue;
        const context = parts.next() orelse continue;
        const id = parts.next() orelse continue;

        if (name.len == 0 or id.len == 0) {
            continue;
        }

        const domain = try domain_in(arena, &domains, name);

        try domain.messages.append(arena, .{
            .context = try unescaped(arena, context),
            .id = try unescaped(arena, id),
        });
    }

    return domains.items;
}

fn domain_in(arena: std.mem.Allocator, domains: *std.ArrayList(Domain), name: []const u8) !*Domain {
    std.debug.assert(name.len > 0);

    for (domains.items) |*domain| {
        if (std.mem.eql(u8, domain.name, name)) {
            return domain;
        }
    }

    try domains.append(arena, .{
        .name = name,
    });

    return &domains.items[domains.items.len - 1];
}

fn unescaped(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    std.debug.assert(text.len <= 1 << 20);

    if (std.mem.indexOfScalar(u8, text, '\\') == null) {
        return text;
    }

    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;

    while (index < text.len) : (index += 1) {
        if (text[index] == '\\' and index + 1 < text.len) {
            index += 1;
            try out.append(arena, switch (text[index]) {
                't' => '\t',
                'n' => '\n',
                else => text[index],
            });
        } else {
            try out.append(arena, text[index]);
        }
    }

    return out.items;
}

/// Each language over each domain: how many messages it translates, which it does not,
/// and the plugins translating any of them.
pub fn of(arena: std.mem.Allocator, list: []const Language) ![]const Coverage {
    std.debug.assert(list.len <= languages.languages_max);

    const domains = try domains_of(arena);
    var out: std.ArrayList(Coverage) = .empty;

    for (list) |language| {
        const translated = try translated_by(arena, language.locale);

        for (domains) |domain| {
            var missing: std.ArrayList(Message) = .empty;

            for (domain.messages.items) |message| {
                if (language.catalog.lookup(message.context, message.id, null) == null) {
                    try missing.append(arena, message);
                }
            }

            const total: u32 = @intCast(domain.messages.items.len);

            try out.append(arena, .{
                .locale = language.locale,
                .label = language.label,
                .domain = domain.name,
                .translated = total - @as(u32, @intCast(missing.items.len)),
                .total = total,
                .missing = missing.items,
                .providers = try providers_of(arena, translated, domain.messages.items),
            });
        }
    }

    return out.items;
}

/// One plugin's translations in a language, as the catalogue's keys.
const Translated = struct {
    provider: []const u8,
    catalog: model.i18n.Catalog,
};

fn translated_by(arena: std.mem.Allocator, locale: []const u8) ![]const Translated {
    std.debug.assert(locale.len > 0);

    const sources = try languages.sources_of(arena, registry.translations, locale);
    const out = try arena.alloc(Translated, sources.len);

    for (sources, out) |source, *translated| {
        translated.* = .{
            .provider = source.provider,
            .catalog = try model.i18n.Catalog.init(arena, locale, &.{source}, &.{}),
        };
    }

    return out;
}

/// The plugins translating at least one of `messages`, whatever domain their file says.
fn providers_of(
    arena: std.mem.Allocator,
    translated: []const Translated,
    messages: []const Message,
) ![]const []const u8 {
    std.debug.assert(translated.len <= 1024);

    var out: std.ArrayList([]const u8) = .empty;

    for (translated) |one| {
        const any = for (messages) |message| {
            if (one.catalog.lookup(message.context, message.id, null) != null) {
                break true;
            }
        } else false;

        if (any) {
            try out.append(arena, one.provider);
        }
    }

    return out.items;
}
