//! What a page's reads named, kept as `adapters/apps/context.zig`'s `Deps` keeps them (each
//! key copied), for tests that draw nothing but read as a page would.

const std = @import("std");
const context = @import("context.zig");

pub const keys_max: u32 = 16;
pub const key_len_max: u32 = 128;

pub const Named = struct {
    bytes: [keys_max][key_len_max]u8 = undefined,
    keys: [keys_max][]const u8 = undefined,
    count: u32 = 0,

    pub fn reads(named: *Named) context.Reads {
        std.debug.assert(named.count <= keys_max);

        return .{
            .context = named,
            .read = read_into,
        };
    }

    fn read_into(any: *anyopaque, key: []const u8) void {
        const named: *Named = @ptrCast(@alignCast(any));

        std.debug.assert(named.count < keys_max);
        std.debug.assert(key.len <= key_len_max);

        const kept = named.bytes[named.count][0..key.len];

        @memcpy(kept, key);
        named.keys[named.count] = kept;
        named.count += 1;
    }

    pub fn has(named: *const Named, key: []const u8) bool {
        std.debug.assert(key.len > 0);

        for (named.keys[0..named.count]) |each| {
            if (std.mem.eql(u8, each, key)) {
                return true;
            }
        }

        return false;
    }
};
