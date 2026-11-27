//! How a plugin's record is listed and moves, as core keeps it: the field it is listed by,
//! its indexed fields, its own statuses and its flow.
const std = @import("std");
const flow_model = @import("../../../model/flow.zig");
const status_module = @import("../../../model/status.zig");
const record_define = @import("../../../publr/plugin/record_define.zig");
const plugin_define = @import("../../../publr/plugin/define.zig");
const record_flow = @import("../../../publr/plugin/record_flow.zig");

const label_of = record_define.label_of;

/// What lists show a record by: the field `.title_field` names, else its first text field; a
/// settings record has none, nor one whose `.title_field` is `.none`.
pub fn title_field_of(comptime Document: type, comptime options: anytype) []const u8 {
    comptime {
        const Options = @TypeOf(options);

        std.debug.assert(options.name.len > 0);

        if (@hasField(Options, "title_field")) {
            return if (options.title_field == .none) "" else @tagName(options.title_field);
        }

        if (@hasField(Options, "kind") and options.kind == .settings) {
            return "";
        }

        return title_of(Document);
    }
}

pub fn indexed_of(comptime options: anytype) []const []const u8 {
    comptime {
        std.debug.assert(options.name.len > 0);

        if (!@hasField(@TypeOf(options), "indexed")) {
            return &.{};
        }

        var names: []const []const u8 = &.{};

        for (options.indexed) |field| {
            names = names ++ [_][]const u8{@tagName(field)};
        }

        const done = names;

        return done;
    }
}

/// The first text field: what a record is listed by when the type names none.
fn title_of(comptime Document: type) []const u8 {
    comptime {
        for (std.meta.fieldNames(Document), std.meta.fieldTypes(Document)) |field_name, FieldType| {
            if (FieldType == []const u8) {
                return field_name;
            }
        }

        @compileError(@typeName(Document) ++ ": give the record a text field, or `.title_field`");
    }
}

/// The statuses a record's `.status` brings beyond core's, labelled by the `///` on each
/// value of its enum.
pub fn statuses_of(comptime Definition: type, comptime Docs: type) []const status_module.Status {
    comptime {
        std.debug.assert(Definition.type_name.len > 0);

        const options = Definition.given;

        if (!@hasField(@TypeOf(options), "status")) {
            return &.{};
        }

        const Status = options.status.list;
        const live = record_flow.published_of(options);
        var list: []const status_module.Status = &.{};

        for (std.meta.fieldNames(Status)) |value| {
            if (plugin_define.listed_in(record_flow.core_status_ids, value)) {
                continue;
            }

            const label = plugin_define.first(Docs, @typeName(Status) ++ "." ++ value) orelse value;
            var shown = false;

            for (live) |published| {
                shown = shown or std.mem.eql(u8, @tagName(published), value);
            }

            list = list ++ [_]status_module.Status{.{
                .id = record_flow.status_id(options.name, value),
                .label = label_of(label),
                .live = shown,
                .alias = record_flow.alias_of(options, value),
            }};
        }

        const done = list;

        return done;
    }
}

/// The type's flow as its definition keeps it: its own statuses, every transition by name, and
/// its start.
pub fn flow_of(comptime Definition: type, comptime Docs: type) flow_model.Flow {
    comptime {
        std.debug.assert(Definition.type_name.len > 0);

        const options = Definition.given;

        if (!@hasField(@TypeOf(options), "status")) {
            return .{};
        }

        return .{
            .statuses = statuses_of(Definition, Docs),
            .transitions = @import("../flows.zig").transitions_of(options),
            .start = record_flow.start_status(options),
        };
    }
}

/// The ids of the statuses a record's type uses: its list's.
pub fn status_ids_of(comptime Definition: type) []const []const u8 {
    comptime {
        std.debug.assert(Definition.type_name.len > 0);

        const options = Definition.given;

        if (!@hasField(@TypeOf(options), "status")) {
            return &.{};
        }

        var ids: []const []const u8 = &.{};

        for (std.meta.fieldNames(options.status.list)) |value| {
            ids = ids ++ [_][]const u8{record_flow.status_id(options.name, value)};
        }

        const done = ids;

        return done;
    }
}
