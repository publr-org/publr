//! A number or a text read out of one layout for another (`transfer.zig`): an int of any
//! size, a float, a decimal's units between two numbers of places or from its exact text, a
//! text or an enum's tag by its name.
const std = @import("std");
const model_decimal = @import("../../model/decimal.zig");
const described_module = @import("described.zig");
const given_module = @import("given.zig");

const Given = given_module.Given;
const Error = given_module.Error;

pub fn int_of(given: *Given, want: described_module.Node, from: u32, bytes: []const u8) Error!i128 {
    const have = given.described.nodes[from];

    std.debug.assert(have.kind != .optional and have.kind != .free);

    // A decimal's units: as they are between two of the same places, read exactly from text.
    if (want.decimal or have.decimal) {
        return units_of(given, want, from, bytes);
    }

    switch (have.kind) {
        .int => return given.int(from, bytes),
        .bool => return @intFromBool(bytes[0] != 0),
        .float => {
            const real = given.float(from, bytes);

            if (@round(real) != real or @abs(real) >= 1 << 62) {
                return error.Invalid;
            }

            return @as(i64, @intFromFloat(real));
        },
        .text => return std.fmt.parseInt(i64, try given.text(bytes), 10) catch error.Invalid,
        else => return error.Invalid,
    }
}

fn units_of(given: *Given, want: described_module.Node, from: u32, bytes: []const u8) Error!i128 {
    const have = given.described.nodes[from];

    std.debug.assert(want.decimal or have.decimal);

    if (!want.decimal or want.places > model_decimal.places_max) {
        return error.Invalid;
    }

    switch (have.kind) {
        .int => {
            const held = given.int(from, bytes);
            const places: u8 = if (have.decimal) have.places else 0;

            if (places > want.places) {
                return error.Invalid;
            }

            const scale = std.math.powi(i128, 10, want.places - places) catch return error.Invalid;

            return std.math.mul(i128, held, scale) catch error.Invalid;
        },
        .text => return model_decimal.units_of(try given.text(bytes), want.places) catch {
            return error.Invalid;
        },
        else => return error.Invalid,
    }
}

pub fn float_of(given: *Given, from: u32, bytes: []const u8) Error!f64 {
    const have = given.described.nodes[from];

    std.debug.assert(have.kind != .optional and have.kind != .free);

    return switch (have.kind) {
        .float => given.float(from, bytes),
        .int => @floatFromInt(given.int(from, bytes)),
        .text => std.fmt.parseFloat(f64, try given.text(bytes)) catch error.Invalid,
        else => error.Invalid,
    };
}

/// A text, or an enum's tag by its name.
pub fn name_of(given: *Given, from: u32, bytes: []const u8) Error![]const u8 {
    const have = given.described.nodes[from];

    std.debug.assert(have.kind != .optional and have.kind != .free);

    switch (have.kind) {
        .text => return given.text(bytes),
        .enumeration => return given.tag(from, bytes),
        .int => {
            var buffer: [model_decimal.text_len_max]u8 = undefined;

            // A decimal read as text is its exact text.
            if (!have.decimal or have.places > model_decimal.places_max) {
                return error.Invalid;
            }

            const units: i64 = @intCast(given.int(from, bytes));
            const text = model_decimal.text_of(units, have.places, &buffer);

            return given.arena.dupe(u8, text) catch error.OutOfMemory;
        },
        else => return error.Invalid,
    }
}
