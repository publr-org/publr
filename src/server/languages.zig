//! The admin's languages: one catalogue per language the plugins bring PO files for, built
//! once when the server starts from every file in that language. English is the source text
//! and needs none.
const std = @import("std");
const model = @import("../model.zig");
const registry = @import("registry.zig");
const runtime = @import("runtime");
const SdkMessage = @import("../sdk/context.zig").Message;

const Catalog = model.i18n.Catalog;
const Source = model.i18n.catalog.Source;
const Choice = model.i18n.catalog.Choice;
const OwnedTranslation = @import("../sdk/plugin.zig").OwnedTranslation;

/// A choice as Site Health keeps it, in the language it is for.
pub const Kept = struct {
    locale: []const u8,
    context: []const u8 = "",
    id: []const u8,
    provider: []const u8,
};

pub const languages_max: u32 = 64;

pub const Language = struct {
    locale: []const u8,
    label: []const u8,
    catalog: Catalog,
    /// The catalogue as the browser and the render's script engine read it:
    /// `globalThis.__publr_messages = { rule, messages }`.
    script: []const u8,
};

const LanguageDisagreements = @import("../sdk/context.zig").LanguageDisagreements;
const Coverage = @import("../sdk/context.zig").Coverage;
const coverage_of = @import("languages/coverage.zig").of;

/// A catalogue's text for a message, as `runtime.Translator.lookup` asks it; `context` is
/// the language's `*const Catalog`.
pub fn lookup(
    context: *const anyopaque,
    message_context: []const u8,
    id: []const u8,
    plural: []const u8,
    count: ?f64,
) ?[]const u8 {
    const catalog: *const Catalog = @ptrCast(@alignCast(context));

    std.debug.assert(id.len > 0);

    return catalog.lookup(message_context, id, if (plural.len > 0) count else null);
}

pub const Languages = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    list: []const Language,
    /// Each language's messages its translations render differently.
    disagreements: []const LanguageDisagreements = &.{},
    /// Each language over each domain's messages.
    coverage: []const Coverage = &.{},
    /// The choices the catalogues were built with, as stored; rebuilt when they change.
    applied: []const u8 = "",

    /// The plugins' PO files, by language. A file the language's plural rule cannot take
    /// stops the server, naming the language: its translations would land on wrong counts.
    pub fn init(languages: *Languages, gpa: std.mem.Allocator) !void {
        std.debug.assert(registry.translations.len <= 1024);

        languages.gpa = gpa;
        languages.applied = "";
        languages.arena = .init(gpa);
        errdefer languages.arena.deinit();

        languages.list = try build(languages.arena.allocator(), registry.translations, &.{});
        const arena = languages.arena.allocator();

        languages.disagreements = try disagreements_of(arena, registry.translations);
        languages.coverage = try coverage_of(languages.arena.allocator(), languages.list);
    }

    /// The view operations read the disagreements through (`Ctx.translations`).
    pub fn view(languages: *const Languages) @import("../sdk/context.zig").Translations {
        std.debug.assert(languages.list.len <= languages_max);

        return .{
            .context = languages,
            .disagreements = read_disagreements,
            .coverage = read_coverage,
            .say = say,
        };
    }

    pub fn deinit(languages: *Languages) void {
        std.debug.assert(languages.list.len <= languages_max);

        languages.arena.deinit();
        languages.* = undefined;
    }

    /// The catalogues built again with `stored` choices (Site Health's, as JSON), when they
    /// differ from the ones applied. A choice that no longer parses is left out.
    pub fn apply(languages: *Languages, stored: []const u8) !void {
        std.debug.assert(stored.len <= 16 << 20);

        if (std.mem.eql(u8, stored, languages.applied)) {
            return;
        }

        var fresh: std.heap.ArenaAllocator = .init(languages.gpa);
        errdefer fresh.deinit();

        const arena = fresh.allocator();
        const kept = std.json.parseFromSliceLeaky([]const Kept, arena, stored, .{
            .ignore_unknown_fields = true,
        }) catch &.{};
        const list = try build(arena, registry.translations, kept);

        languages.disagreements = try disagreements_of(arena, registry.translations);
        languages.coverage = try coverage_of(arena, list);
        languages.arena.deinit();
        languages.arena = fresh;
        languages.list = list;
        languages.applied = try arena.dupe(u8, stored);
    }

    /// The language, null for English and any language no plugin brings.
    pub fn find(languages: *const Languages, locale: []const u8) ?*const Language {
        std.debug.assert(languages.list.len <= languages_max);

        for (languages.list) |*language| {
            if (std.mem.eql(u8, language.locale, locale)) {
                return language;
            }
        }

        return null;
    }
};

fn build(
    arena: std.mem.Allocator,
    translations: []const OwnedTranslation,
    kept: []const Kept,
) ![]const Language {
    std.debug.assert(translations.len <= 1024);

    var list: std.ArrayList(Language) = .empty;

    for (translations, 0..) |owned, index| {
        const translation = owned.translation;

        if (seen(translations[0..index], translation.locale)) {
            continue;
        }

        const sources = try sources_of(arena, translations[index..], translation.locale);
        const choices = try choices_in(arena, kept, translation.locale);
        const catalog = Catalog.init(arena, translation.locale, sources, choices) catch |err| {
            std.log.err("languages: the {s} translations: {t}", .{ translation.locale, err });

            return err;
        };

        try list.append(arena, .{
            .locale = translation.locale,
            .label = translation.label,
            .catalog = catalog,
            .script = try script_of(arena, &catalog),
        });
    }

    if (list.items.len > languages_max) {
        return error.TooManyLanguages;
    }

    return list.items;
}

/// `globalThis.__publr_messages = { rule, messages }`: each message under its key (its
/// context, `\u0004`, then its text, or its text alone), as its forms.
fn script_of(arena: std.mem.Allocator, catalog: *const Catalog) ![]const u8 {
    std.debug.assert(catalog.locale.len > 0);

    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    var stringify: std.json.Stringify = .{
        .writer = writer,
    };

    try writer.print("globalThis.__publr_messages={{\"rule\":\"{t}\",\"messages\":", .{
        catalog.rule,
    });
    try stringify.beginObject();

    var entries = catalog.map.iterator();

    while (entries.next()) |entry| {
        try stringify.objectField(entry.key_ptr.*);
        try stringify.write(entry.value_ptr.*);
    }

    try stringify.endObject();
    try writer.writeAll("};\n");

    return out.written();
}

fn say(
    context: *const anyopaque,
    arena: std.mem.Allocator,
    locale: []const u8,
    message: SdkMessage,
) std.mem.Allocator.Error![]const u8 {
    const languages: *const Languages = @ptrCast(@alignCast(context));

    std.debug.assert(message.id.len > 0);
    std.debug.assert(languages.list.len <= languages_max);

    const values = try arena.alloc(runtime.Placeholder, message.values.len);

    for (message.values, values) |given, *value| {
        value.* = .{
            .name = given.name,
            .value = given.value,
        };
    }

    const found = languages.find(locale);
    const translator: ?runtime.Translator = if (found) |language| .{
        .context = &language.catalog,
        .lookup = lookup,
    } else null;

    return runtime.translate(arena, if (translator) |*held| held else null, .{
        .context = message.context,
        .id = message.id,
        .plural = message.plural,
        .count = message.count,
        .values = values,
    });
}

fn read_coverage(context: *const anyopaque) []const Coverage {
    const languages: *const Languages = @ptrCast(@alignCast(context));

    std.debug.assert(languages.list.len <= languages_max);

    return languages.coverage;
}

fn read_disagreements(context: *const anyopaque) []const LanguageDisagreements {
    const languages: *const Languages = @ptrCast(@alignCast(context));

    std.debug.assert(languages.list.len <= languages_max);

    return languages.disagreements;
}

/// Each language's disagreements between the translations installed for it.
fn disagreements_of(
    arena: std.mem.Allocator,
    translations: []const OwnedTranslation,
) ![]const LanguageDisagreements {
    std.debug.assert(translations.len <= 1024);

    var out: std.ArrayList(LanguageDisagreements) = .empty;

    for (translations, 0..) |owned, index| {
        if (seen(translations[0..index], owned.translation.locale)) {
            continue;
        }

        const sources = try sources_of(arena, translations[index..], owned.translation.locale);

        try out.append(arena, .{
            .locale = owned.translation.locale,
            .label = owned.translation.label,
            .conflicts = try model.i18n.conflicts.of(arena, sources),
        });
    }

    return out.items;
}

/// Every PO file in `locale`, each with who brings it and whether it is first-party.
pub fn sources_of(
    arena: std.mem.Allocator,
    translations: []const OwnedTranslation,
    locale: []const u8,
) ![]const Source {
    std.debug.assert(locale.len > 0);

    var sources: std.ArrayList(Source) = .empty;

    for (translations) |owned| {
        if (std.mem.eql(u8, owned.translation.locale, locale)) {
            try sources.append(arena, .{
                .provider = owned.plugin,
                .first_party = owned.first_party(),
                .po = owned.translation.po,
            });
        }
    }

    return sources.items;
}

fn choices_in(arena: std.mem.Allocator, kept: []const Kept, locale: []const u8) ![]const Choice {
    std.debug.assert(locale.len > 0);

    var choices: std.ArrayList(Choice) = .empty;

    for (kept) |choice| {
        if (std.mem.eql(u8, choice.locale, locale) and choice.id.len > 0) {
            try choices.append(arena, .{
                .context = choice.context,
                .id = choice.id,
                .provider = choice.provider,
            });
        }
    }

    return choices.items;
}

fn seen(earlier: []const OwnedTranslation, locale: []const u8) bool {
    std.debug.assert(locale.len > 0);

    for (earlier) |owned| {
        if (std.mem.eql(u8, owned.translation.locale, locale)) {
            return true;
        }
    }

    return false;
}

test "a language's files merged into one catalogue, the first file winning" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const files = [_]OwnedTranslation{
        .{
            .plugin = "language_pl",
            .translation = .{
                .locale = "pl",
                .label = "Polski",
                .domain = "publr",
                .official = true,
                .po = "msgid \"Save\"\nmsgstr \"Zapisz\"\n",
            },
        },
        .{
            .plugin = "language_de",
            .translation = .{
                .locale = "de",
                .label = "Deutsch",
                .domain = "publr",
                .po = "msgid \"Save\"\nmsgstr \"Speichern\"\n",
            },
        },
        .{
            .plugin = "pl_extra",
            .translation = .{
                .locale = "pl",
                .label = "Polski",
                .domain = "publr",
                .po = "msgid \"Save\"\nmsgstr \"Zachowaj\"\nmsgid \"Trash\"\nmsgstr \"Kosz\"\n",
            },
        },
    };
    const list = try build(arena_state.allocator(), &files, &.{});

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("Zapisz", list[0].catalog.lookup("", "Save", null).?);
    try std.testing.expect(std.mem.indexOf(u8, list[0].script, "\"Save\":[\"Zapisz\"]") != null);
    try std.testing.expectEqualStrings("Kosz", list[0].catalog.lookup("", "Trash", null).?);
    try std.testing.expectEqualStrings("Speichern", list[1].catalog.lookup("", "Save", null).?);
}

test "queued work speaks the language it was queued in: a job about a Polish record, in Polish" {
    const sdk = @import("../sdk.zig");
    const job_define = @import("../sdk/plugin/job_define.zig");
    const HostApi = @import("../sdk/plugin/context.zig").HostApi;
    const QueueCtx = @import("../sdk/plugin/queue.zig").Queue(HostApi);
    const Probe = struct {
        const In = struct {
            title: []const u8,
        };

        var said: [64]u8 = undefined;
        var said_len: usize = 0;

        fn run(ctx: *QueueCtx, in: In) sdk.Error!void {
            std.debug.assert(in.title.len > 0);

            const text = ctx.t("{title} is ready", .{
                .title = in.title,
            });

            @memcpy(said[0..text.len], text);
            said_len = text.len;
        }
    };
    const Announce = job_define.define(Probe.In, .{
        .name = "announce",
        .run = Probe.run,
    });
    const Runner = sdk.SDK(.{
        .operations = &.{},
        .jobs = &.{Announce},
        .job_owners = &.{"probe"},
    }).jobs;

    // The compiled-in plugin's own words in Polish.
    const files = [_]OwnedTranslation{.{
        .plugin = "probe",
        .translation = .{
            .locale = "pl",
            .label = "Polski",
            .po = "msgid \"{title} is ready\"\nmsgstr \"Gotowe: {title}\"\n",
        },
    }};
    var languages: Languages = .{
        .gpa = std.testing.allocator,
        .arena = .init(std.testing.allocator),
        .list = &.{},
    };
    defer languages.arena.deinit();
    languages.list = try build(languages.arena.allocator(), &files, &.{});

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    // A visitor's request on the Polish page queues it; nobody signed in.
    var request = harness.ctx(.anonymous);

    request.variant = "pl";
    request.plugin = "probe";

    var asking: HostApi = .{
        .inner = &request,
    };

    try asking.enqueue(Announce, .{
        .title = "Zamówienie",
    });

    // The worker runs it later, as the system, knowing nothing of the request.
    var worker = harness.ctx(.system);

    worker.translations = languages.view();

    try std.testing.expectEqual(1, try Runner.drain(&worker, 8));
    try std.testing.expectEqualStrings("Gotowe: Zamówienie", Probe.said[0..Probe.said_len]);

    // Queued with no language, it speaks the site's: English here.
    var english = harness.ctx(.system);

    english.plugin = "probe";
    asking.inner = &english;

    try asking.enqueue(Announce, .{
        .title = "Order",
    });
    try std.testing.expectEqual(1, try Runner.drain(&worker, 8));
    try std.testing.expectEqualStrings("Order is ready", Probe.said[0..Probe.said_len]);
}

test "queued work tells each in their own words: the admin in English, the visitor in Polish" {
    const sdk = @import("../sdk.zig");
    const job_define = @import("../sdk/plugin/job_define.zig");
    const HostApi = @import("../sdk/plugin/context.zig").HostApi;
    const QueueCtx = @import("../sdk/plugin/queue.zig").Queue(HostApi);
    const Probe = struct {
        const In = struct {
            title: []const u8,
            admin: []const u8,
        };

        var said: [3][64]u8 = undefined;
        var said_len: [3]u32 = @splat(0);

        fn keep(slot: u32, text: []const u8) void {
            std.debug.assert(slot < said.len);
            std.debug.assert(text.len <= said[slot].len);

            @memcpy(said[slot][0..text.len], text);
            said_len[slot] = @intCast(text.len);
        }

        fn run(ctx: *QueueCtx, in: In) sdk.Error!void {
            std.debug.assert(in.title.len > 0);
            std.debug.assert(in.admin.len > 0);

            const values = .{
                .title = in.title,
            };

            keep(0, ctx.t("{title} is ready", values));
            keep(1, ctx.locale(in.admin).t("{title} is ready", values));
            // A guest with no account: the language the work was queued in.
            keep(2, ctx.locale("").t("{title} is ready", values));
        }

        fn kept(slot: u32) []const u8 {
            std.debug.assert(slot < said.len);

            return said[slot][0..said_len[slot]];
        }
    };
    const Tell = job_define.define(Probe.In, .{
        .name = "tell",
        .run = Probe.run,
    });
    const Runner = sdk.SDK(.{
        .operations = &.{},
        .jobs = &.{Tell},
        .job_owners = &.{"probe"},
    }).jobs;

    const files = [_]OwnedTranslation{.{
        .plugin = "probe",
        .translation = .{
            .locale = "pl",
            .label = "Polski",
            .po = "msgid \"{title} is ready\"\nmsgstr \"Gotowe: {title}\"\n",
        },
    }};
    var languages: Languages = .{
        .gpa = std.testing.allocator,
        .arena = .init(std.testing.allocator),
        .list = &.{},
    };
    defer languages.arena.deinit();
    languages.list = try build(languages.arena.allocator(), &files, &.{});

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var request = harness.ctx(.anonymous);

    // The administrator chose English for themselves.
    try @import("../store.zig").settings.set(request.db, "admin_language:u_admin", "en", 1);

    // A visitor's request on the Polish page queues it.
    request.variant = "pl";
    request.plugin = "probe";

    var asking: HostApi = .{
        .inner = &request,
    };

    try asking.enqueue(Tell, .{
        .title = "Zamówienie",
        .admin = "u_admin",
    });

    var worker = harness.ctx(.system);

    worker.translations = languages.view();

    try std.testing.expectEqual(1, try Runner.drain(&worker, 8));
    try std.testing.expectEqualStrings("Gotowe: Zamówienie", Probe.kept(0));
    try std.testing.expectEqualStrings("Zamówienie is ready", Probe.kept(1));
    try std.testing.expectEqualStrings("Gotowe: Zamówienie", Probe.kept(2));
}
