//! `publr.Decimal(places)`: an exact number with a set number of decimal places (`1.25`
//! kg at 3 places), kept as whole units of its last place, never a binary fraction. Written
//! as text in JSON and in a `decimal` field; read from text or a whole number.
const std = @import("std");
const decimal = @import("../../model/decimal.zig");
const contract = @import("../model/contract.zig");

pub fn Decimal(comptime places: u8) type {
    comptime {
        if (places > decimal.places_max) {
            @compileError(std.fmt.comptimePrint("a decimal keeps at most {d} places", .{
                decimal.places_max,
            }));
        }
    }

    return struct {
        /// The value in units of its last place: 1.25 at 3 places is 1250.
        units: i64,

        const Self = @This();

        pub const decimal_places = places;
        /// Handed over as its units; JSON writes its exact text.
        pub const publr_form = .decimal;
        pub const json_scalar: contract.Kind = .string;
        pub const json_label = std.fmt.comptimePrint(
            "a number with up to {d} decimal places, as text: \"1.25\"",
            .{places},
        );
        /// One whole: 1 at 3 places is 1000 units.
        pub const scale: i64 = std.math.powi(i64, 10, places) catch unreachable;

        /// `written` read exactly: `"1.25"`; more places than it keeps are refused.
        pub fn parse(written: []const u8) error{Invalid}!Self {
            std.debug.assert(places <= decimal.places_max);

            const units = decimal.units_of(written, places) catch return error.Invalid;

            return .{
                .units = units,
            };
        }

        /// A whole number of it: `of(2)` is 2.000 at 3 places.
        pub fn of(whole: i64) Self {
            std.debug.assert(whole > std.math.minInt(i64) / scale);
            std.debug.assert(whole < std.math.maxInt(i64) / scale);

            return .{
                .units = whole * scale,
            };
        }

        /// It as text, every place shown: `1.250`.
        pub fn text(value: Self, buffer: *[decimal.text_len_max]u8) []const u8 {
            std.debug.assert(places <= decimal.places_max);

            return decimal.text_of(value.units, places, buffer);
        }

        pub fn jsonStringify(value: Self, writer: anytype) !void {
            var buffer: [decimal.text_len_max]u8 = undefined;

            std.debug.assert(places <= decimal.places_max);

            try writer.write(value.text(&buffer));
        }

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Self {
            var exact = options;

            exact.parse_numbers = false;

            const read = try std.json.innerParse(std.json.Value, allocator, source, exact);
            const written = switch (read) {
                .string => |string| string,
                .number_string => |number| number,
                else => return error.UnexpectedToken,
            };

            return parse(written) catch error.InvalidNumber;
        }

        pub fn jsonParseFromValue(
            allocator: std.mem.Allocator,
            source: std.json.Value,
            options: std.json.ParseOptions,
        ) !Self {
            _ = allocator;
            _ = options;

            return switch (source) {
                .string, .number_string => |written| parse(written) catch error.InvalidNumber,
                .integer => |whole| of(whole),
                else => error.UnexpectedToken,
            };
        }
    };
}

test "a decimal reads and writes its exact text" {
    const Weight = Decimal(3);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Line = struct {
        weight: Weight,
    };

    const read = try std.json.parseFromSliceLeaky(Line, arena, "{\"weight\":\"1.25\"}", .{});

    try std.testing.expectEqual(@as(i64, 1250), read.weight.units);

    const number = try std.json.parseFromSliceLeaky(Line, arena, "{\"weight\":2.5}", .{});

    try std.testing.expectEqual(@as(i64, 2500), number.weight.units);

    const written = try std.json.Stringify.valueAlloc(arena, read, .{});

    try std.testing.expectEqualStrings("{\"weight\":\"1.250\"}", written);
    try std.testing.expectError(
        error.InvalidNumber,
        std.json.parseFromSliceLeaky(Line, arena, "{\"weight\":\"1.2345\"}", .{}),
    );
}
