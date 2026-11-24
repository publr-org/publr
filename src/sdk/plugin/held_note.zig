//! What a plugin's SDK collections hold, as they grow: the largest of a request names what
//! filled the plugin's memory when it runs out, or holds more than half of it. Compiled in,
//! the plugins' memory keeps it (`plugin_memory.zig`); installed, the host hears it
//! (`publr_held`) whenever a collection grows past the largest so far.
const std = @import("std");
const guest = @import("guest.zig");
const plugin_memory = @import("../plugin_memory.zig");
const PluginCtx = @import("context.zig").PluginCtx;

/// The longest name of a collection the host keeps.
pub const name_bytes_max: u32 = 96;

extern "env" fn publr_held(name_ptr: [*]const u8, name_len: u32, kib: u32) void;

// A wasm module is one instance behind a C ABI, one a request: the largest of its request.
var largest_kib: u32 = 0;

/// Where a collection tells what it holds, taken when it is made.
pub const Note = struct {
    memory: if (guest.mode == .native) ?*plugin_memory.Memory else void,

    pub fn of(ctx: *PluginCtx) Note {
        std.debug.assert(ctx.now().ms >= 0);

        return .{
            .memory = if (comptime guest.mode == .native) ctx.inner.plugins_set_aside else {},
        };
    }

    /// The collection named `name` holds `bytes` now.
    pub fn grew(note: Note, comptime name: []const u8, bytes: u64) void {
        comptime std.debug.assert(name.len > 0);

        if (comptime guest.mode == .native) {
            const memory = note.memory orelse return;

            memory.note_largest(name, bytes);

            return;
        }

        const kib: u32 = @intCast(@min((bytes + 1023) / 1024, std.math.maxInt(u32)));

        if (kib > largest_kib) {
            largest_kib = kib;
            publr_held(name.ptr, name.len, kib);
        }
    }
};
