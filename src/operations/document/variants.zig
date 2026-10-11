//! Reading documents in a variant (a language, with the languages plugin): each field that
//! holds variants gives the variant's value, or its fallback's, under its plain name, and the
//! listed title and slug follow. Whole documents, every variant beside its field, are what the
//! admin and the API read unless they ask for one.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Record = store.documents.Record;
const Value = std.json.Value;
const variant = model.variant;

pub fn Of(comptime Domain: type) type {
    return struct {
        const definitions = Domain.definition;

        /// The variant a read is in: the one asked for; else, for a page drawn for a visitor
        /// or a preview, the request's (empty: the main values). Null reads whole documents.
        pub fn code_of(ctx: *const Ctx, asked: ?[]const u8) Error!?[]const u8 {
            std.debug.assert(ctx.variant.len <= variant.code_len_max);
            std.debug.assert(!(ctx.delivery and ctx.preview));

            if (asked) |code| {
                if (code.len > 0 and !variant.valid_code(code)) {
                    return error.Invalid;
                }

                return code;
            }

            if (ctx.delivery or ctx.preview) {
                return ctx.variant;
            }

            return null;
        }

        /// One document read in `code`, as JSON text.
        pub fn resolve_text(
            ctx: *Ctx,
            def: model.content_type.Def,
            text: []const u8,
            code: []const u8,
        ) Error![]const u8 {
            std.debug.assert(text.len > 0);
            std.debug.assert(code.len <= variant.code_len_max);

            const parsed = @import("../../lib/json.zig").parse(Value, ctx.arena, text, .{}) catch {
                return error.Invalid;
            };
            const resolved = try variant.resolve(ctx.arena, def.fields, parsed, code);

            return std.json.Stringify.valueAlloc(ctx.arena, resolved, .{}) catch {
                return error.OutOfMemory;
            };
        }

        /// The listed documents read in `code`, each record's title and slug from its own.
        pub fn resolve_listed(
            ctx: *Ctx,
            records: []Record,
            texts: [][]const u8,
            code: []const u8,
        ) Error!void {
            std.debug.assert(records.len == texts.len);
            std.debug.assert(code.len <= variant.code_len_max);

            var cached_type: []const u8 = "";
            var cached_def: model.content_type.Def = undefined;

            for (records, texts) |*record, *text| {
                if (!std.mem.eql(u8, cached_type, record.type_id)) {
                    const row = try definitions.find(ctx, record.type_id) orelse continue;

                    cached_type = record.type_id;
                    cached_def = row.def;
                }

                text.* = try resolve_text(ctx, cached_def, text.*, code);
                try retitle(ctx, cached_def, record, text.*);
            }
        }

        /// Whether a record shows in `code`: always where its type falls back to the main
        /// values; else only when it holds a value in the variant (or its shorter prefix).
        pub fn shown_in(
            ctx: *Ctx,
            def: model.content_type.Def,
            text: []const u8,
            code: []const u8,
        ) Error!bool {
            std.debug.assert(text.len > 0);
            std.debug.assert(code.len <= variant.code_len_max);

            if (def.variant_fallback or code.len == 0) {
                return true;
            }

            const parsed = @import("../../lib/json.zig").parse(Value, ctx.arena, text, .{}) catch {
                return error.Invalid;
            };
            const held = try variant.codes_in(ctx.arena, def.fields, parsed);
            var buffer: [variant.order_max][]const u8 = undefined;

            for (variant.order(code, &buffer)) |wanted| {
                for (held) |code_held| {
                    if (wanted.len > 0 and std.mem.eql(u8, wanted, code_held)) {
                        return true;
                    }
                }
            }

            return false;
        }

        /// The listed records that show in `code`, and their documents, in order.
        pub fn kept_in(
            ctx: *Ctx,
            records: []const Record,
            texts: []const []const u8,
            code: []const u8,
        ) Error!Kept {
            std.debug.assert(records.len == texts.len);
            std.debug.assert(code.len <= variant.code_len_max);

            var kept_records: std.ArrayList(Record) = .empty;
            var kept_texts: std.ArrayList([]const u8) = .empty;
            // Only the site leaves untranslated records out: the admin lists every one.
            const for_site = ctx.delivery or ctx.preview;

            if (!for_site) {
                return .{
                    .records = ctx.arena.dupe(Record, records) catch return error.OutOfMemory,
                    .texts = ctx.arena.dupe([]const u8, texts) catch return error.OutOfMemory,
                };
            }

            for (records, texts) |record, text| {
                const row = try definitions.find(ctx, record.type_id) orelse continue;

                if (try shown_in(ctx, row.def, text, code)) {
                    kept_records.append(ctx.arena, record) catch return error.OutOfMemory;
                    kept_texts.append(ctx.arena, text) catch return error.OutOfMemory;
                }
            }

            return .{
                .records = kept_records.items,
                .texts = kept_texts.items,
            };
        }

        pub const Kept = struct {
            records: []Record,
            texts: [][]const u8,
        };

        /// One record's document read in `code`, its title and slug from it.
        pub fn resolve_one(
            ctx: *Ctx,
            record: *Record,
            text: *[]const u8,
            code: []const u8,
        ) Error!void {
            std.debug.assert(record.type_id.len > 0);
            std.debug.assert(code.len <= variant.code_len_max);

            const row = try definitions.find(ctx, record.type_id) orelse return error.NotFound;

            if (!try shown_in(ctx, row.def, text.*, code)) {
                return error.NotFound;
            }

            text.* = try resolve_text(ctx, row.def, text.*, code);
            try retitle(ctx, row.def, record, text.*);
        }

        fn retitle(
            ctx: *Ctx,
            def: model.content_type.Def,
            record: *Record,
            text: []const u8,
        ) Error!void {
            std.debug.assert(text.len > 0);
            std.debug.assert(record.id.len > 0);

            const parsed = @import("../../lib/json.zig").parse(Value, ctx.arena, text, .{}) catch {
                return error.Invalid;
            };

            record.title = model.document.title_of(def, parsed) catch record.title;
            record.slug = model.document.slug_of(def, parsed) orelse record.slug;
        }
    };
}
