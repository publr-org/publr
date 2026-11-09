//! Reading documents in a combination of the site's dimensions (a language, a variation):
//! each field varying by them gives the combination's value, or its fallback's, under its
//! plain name, and the listed title and slug follow. Whole documents, every combination
//! beside its field, are what the admin and the API read unless they ask for one.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const site_dimensions = @import("../dimensions.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Record = store.documents.Record;
const Value = std.json.Value;
const dimension = model.dimension;
const Pair = dimension.Pair;

pub fn Of(comptime Domain: type) type {
    return struct {
        const definitions = Domain.definition;

        /// The combination a read is in, highest priority first: the one asked for (each a
        /// dimension of the site's, an empty code its main value); else, for a page drawn for
        /// a visitor or a preview, the request's. Null reads whole documents.
        pub fn wanted_of(ctx: *const Ctx, asked: sdk.Dimensions) Error!?[]const Pair {
            std.debug.assert(ctx.dimensions.len <= dimension.dimensions_max);
            std.debug.assert(!(ctx.delivery and ctx.preview));

            if (asked.pairs.len > 0) {
                return try ordered(ctx, asked.pairs);
            }

            if (ctx.delivery or ctx.preview) {
                return ctx.dimensions;
            }

            return null;
        }

        /// `pairs` checked against the site's dimensions, each named by its own name or its
        /// read option's, and put in their priority order under their own names.
        fn ordered(ctx: *const Ctx, pairs: []const Pair) Error![]const Pair {
            std.debug.assert(pairs.len > 0);

            if (pairs.len > dimension.dimensions_max) {
                return error.Invalid;
            }

            const every = site_dimensions.all(ctx);
            const named = ctx.arena.alloc(Pair, pairs.len) catch return error.OutOfMemory;
            var out: std.ArrayList(Pair) = .empty;

            for (pairs, named) |pair, *one| {
                const known = site_dimensions.read_by(ctx, pair.dimension) orelse {
                    return error.Invalid;
                };

                if (pair.code.len > 0 and !dimension.valid_code(pair.code)) {
                    return error.Invalid;
                }

                one.* = .{
                    .dimension = known.name,
                    .code = pair.code,
                };
            }

            for (every) |declared| {
                for (named) |pair| {
                    if (std.mem.eql(u8, pair.dimension, declared.name)) {
                        out.append(ctx.arena, pair) catch return error.OutOfMemory;
                    }
                }
            }

            if (out.items.len != pairs.len) {
                return error.Invalid;
            }

            return out.items;
        }

        /// The code the dimension with pages of its own is at in `wanted`; empty for its main.
        pub fn addressed_code(ctx: *const Ctx, wanted: []const Pair) []const u8 {
            std.debug.assert(wanted.len <= dimension.dimensions_max);

            const addressed = site_dimensions.setting(ctx) orelse return "";

            for (wanted) |pair| {
                if (std.mem.eql(u8, pair.dimension, addressed.name)) {
                    return pair.code;
                }
            }

            return "";
        }

        /// One document read in `wanted`, as JSON text.
        pub fn resolve_text(
            ctx: *Ctx,
            def: model.content_type.Def,
            text: []const u8,
            wanted: []const Pair,
        ) Error![]const u8 {
            std.debug.assert(text.len > 0);
            std.debug.assert(wanted.len <= dimension.dimensions_max);

            const parsed = @import("../../lib/json.zig").parse(Value, ctx.arena, text, .{}) catch {
                return error.Invalid;
            };
            const resolved = try dimension.resolve.resolve(ctx.arena, def.fields, parsed, wanted);

            return std.json.Stringify.valueAlloc(ctx.arena, resolved, .{}) catch {
                return error.OutOfMemory;
            };
        }

        /// The listed documents read in `wanted`, each record's title and slug from its own,
        /// each in what its record puts live of it (`read_as`).
        pub fn resolve_listed(
            ctx: *Ctx,
            records: []Record,
            texts: [][]const u8,
            wanted: []const Pair,
        ) Error!void {
            std.debug.assert(records.len == texts.len);
            std.debug.assert(wanted.len <= dimension.dimensions_max);

            var cached_type: []const u8 = "";
            var cached_def: model.content_type.Def = undefined;
            var out: [dimension.dimensions_max]Pair = undefined;

            for (records, texts) |*record, *text| {
                if (!std.mem.eql(u8, cached_type, record.type_id)) {
                    const row = try definitions.find(ctx, record.type_id) orelse continue;

                    cached_type = record.type_id;
                    cached_def = row.def;
                }

                const read = read_as(ctx, record.*, wanted, &out) orelse wanted;

                text.* = try resolve_text(ctx, cached_def, text.*, read);
                try retitle(ctx, cached_def, record, text.*);
            }
        }

        /// The combination `record` is read in for `wanted`: what it puts live of it
        /// (`model/dimension/live.zig`), in a preview what it will once published; null when
        /// it holds itself back at `wanted`'s address.
        pub fn read_as(
            ctx: *const Ctx,
            record: Record,
            wanted: []const Pair,
            out: *[dimension.dimensions_max]Pair,
        ) ?[]const Pair {
            std.debug.assert(wanted.len <= dimension.dimensions_max);
            std.debug.assert(record.held_back.len <= dimension.live.held_back_len_max);

            const addressed = if (site_dimensions.setting(ctx)) |found| found.name else "";

            const parked = if (ctx.preview) record.pending_held_back else null;

            return dimension.live.read_as(parked orelse record.held_back, wanted, addressed, out);
        }

        /// The listed records that show in `wanted`, and their documents, in order: on the
        /// site, the ones not held back at its address.
        pub fn kept_in(
            ctx: *Ctx,
            records: []const Record,
            texts: []const []const u8,
            wanted: []const Pair,
        ) Error!Kept {
            std.debug.assert(records.len == texts.len);
            std.debug.assert(wanted.len <= dimension.dimensions_max);

            var kept_records: std.ArrayList(Record) = .empty;
            var kept_texts: std.ArrayList([]const u8) = .empty;
            // Only the site leaves held back records out: the admin lists every one.
            const for_site = ctx.delivery or ctx.preview;
            var out: [dimension.dimensions_max]Pair = undefined;

            if (!for_site) {
                return .{
                    .records = ctx.arena.dupe(Record, records) catch return error.OutOfMemory,
                    .texts = ctx.arena.dupe([]const u8, texts) catch return error.OutOfMemory,
                };
            }

            for (records, texts) |record, text| {
                if (read_as(ctx, record, wanted, &out) != null) {
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

        /// One record's document read in `wanted`, its title and slug from it; not found
        /// where it holds itself back.
        pub fn resolve_one(
            ctx: *Ctx,
            record: *Record,
            text: *[]const u8,
            wanted: []const Pair,
        ) Error!void {
            std.debug.assert(record.type_id.len > 0);
            std.debug.assert(wanted.len <= dimension.dimensions_max);

            const row = try definitions.find(ctx, record.type_id) orelse return error.NotFound;
            var out: [dimension.dimensions_max]Pair = undefined;
            const read = read_as(ctx, record.*, wanted, &out) orelse return error.NotFound;

            text.* = try resolve_text(ctx, row.def, text.*, read);
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
