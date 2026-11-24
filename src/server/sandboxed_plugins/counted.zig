//! What plugins cost, counted for each request on the host (an HTTP request, a top-level
//! call outside one, a queued run): per installed plugin its instructions, calls into core,
//! invocations, instances made and the most memory it held; for the compiled-in ones
//! together the pieces of work begun and the most memory they held; and core's own working
//! memory at its fullest. Always counted, a few additions a call; said only where the operator
//! asked (`PUBLR_COUNTERS` in the server's or the command's environment), one line a plugin
//! on the process's own error output. Never part of an answer, and no plugin can read it.
const std = @import("std");
const Loaded = @import("loaded.zig").Loaded;
const db = @import("../../lib/db.zig");

/// The variable that turns the lines on. Any value but none and `0`.
pub const variable = "PUBLR_COUNTERS";
pub const label_len_max: u32 = 96;
/// The longest name kept of a plugin's collection.
pub const name_bytes_max: u32 = @import("../../sdk/plugin/held_note.zig").name_bytes_max;

/// One plugin's share of the request.
pub const Plugin = struct {
    /// Instructions its instances executed, work nested in its own host calls included.
    instructions: u64 = 0,
    /// Calls it made into core that count against its limit.
    host_calls: u32 = 0,
    /// Calls into its module: operations, hooks, modifiers, jobs; a batch is one.
    invocations: u32 = 0,
    instances: u32 = 0,
    /// The most linear memory one of its instances held, in 64 KiB pages.
    memory_pages: u32 = 0,

    pub fn add(total: *Plugin, one: Plugin) void {
        std.debug.assert(one.instances <= one.invocations + 1);

        total.instructions += one.instructions;
        total.host_calls += one.host_calls;
        total.invocations += one.invocations;
        total.instances += one.instances;
        total.memory_pages = @max(total.memory_pages, one.memory_pages);
    }

    pub fn idle(one: Plugin) bool {
        return one.invocations == 0 and one.instances == 0 and one.instructions == 0;
    }
};

pub const Told = @import("../../sdk/sandboxed_plugins.zig").Counted;

/// The largest of a plugin's SDK collections in a request (`publr.List`, `publr.IdMap`): what
/// an out-of-memory failure and the half-limit line name.
pub const Largest = struct {
    name_buffer: [name_bytes_max]u8 = undefined,
    name_len: u32 = 0,
    kib: u64 = 0,

    /// Kept when larger than the largest so far; a long name cut.
    pub fn note(largest: *Largest, named: []const u8, kib: u64) void {
        std.debug.assert(largest.name_len <= name_bytes_max);

        if (kib <= largest.kib or named.len == 0) {
            return;
        }

        const kept = named[0..@min(named.len, name_bytes_max)];

        @memcpy(largest.name_buffer[0..kept.len], kept);
        largest.name_len = @intCast(kept.len);
        largest.kib = kib;
    }

    pub fn name(largest: *const Largest) []const u8 {
        std.debug.assert(largest.name_len <= name_bytes_max);

        return largest.name_buffer[0..largest.name_len];
    }
};

/// The request's own figures, kept on the host between its begin and its end.
pub const Request = struct {
    on: bool = false,
    label_buffer: [label_len_max]u8 = undefined,
    label_len: u32 = 0,
    scratch_bytes: u64 = 0,
    arena_bytes: u64 = 0,
    plugin_bytes: u64 = 0,
    plugin_work: u64 = 0,
    plugin_bytes_max: u64 = 0,
    /// The largest a compiled-in plugin's SDK collection held, and which.
    largest: Largest = .{},
    /// The most SQLite held at once during the request, in bytes.
    db_bytes: u64 = 0,

    pub fn begin(request: *Request) void {
        std.debug.assert(request.label_len <= label_len_max);

        request.label_len = 0;
        request.scratch_bytes = 0;
        request.arena_bytes = 0;
        request.plugin_bytes = 0;
        request.plugin_work = 0;
        request.plugin_bytes_max = 0;
        request.largest = .{};
        request.db_bytes = 0;
        // SQLite's peak counted from here: what this request made it hold.
        _ = db.memory_peak(true);
    }

    pub fn tell(request: *Request, told: Told) void {
        std.debug.assert(request.label_len <= label_len_max);

        if (request.label_len == 0 and told.label.len > 0) {
            const kept = told.label[0..@min(told.label.len, label_len_max)];

            @memcpy(request.label_buffer[0..kept.len], kept);

            // One word on the line, whatever a path holds.
            for (request.label_buffer[0..kept.len]) |*byte| {
                if (byte.* <= ' ' or byte.* > '~') {
                    byte.* = '_';
                }
            }

            request.label_len = @intCast(kept.len);
        }

        request.scratch_bytes = @max(request.scratch_bytes, told.scratch_bytes);
        request.arena_bytes = @max(request.arena_bytes, told.arena_bytes);
        request.plugin_bytes = @max(request.plugin_bytes, told.plugin_bytes);
        request.plugin_work += told.plugin_work;
        request.plugin_bytes_max = @max(request.plugin_bytes_max, told.plugin_bytes_max);
        request.largest.note(told.largest_name, (told.largest_bytes + 1023) / 1024);
    }

    pub fn label(request: *const Request) []const u8 {
        std.debug.assert(request.label_len <= label_len_max);

        return if (request.label_len == 0) "-" else request.label_buffer[0..request.label_len];
    }
};

/// Whether the environment asks for the lines.
pub fn asked(value: ?[]const u8) bool {
    const text = value orelse return false;

    return text.len > 0 and !std.mem.eql(u8, text, "0");
}

/// One plugin's line, or the request's total under the name `*`.
pub fn write_plugin(
    writer: *std.Io.Writer,
    label: []const u8,
    name: []const u8,
    one: Plugin,
) std.Io.Writer.Error!void {
    std.debug.assert(label.len > 0);
    std.debug.assert(name.len > 0);

    try writer.print(
        "counted {s} plugin={s} instructions={d} host_calls={d} invocations={d} " ++
            "instances={d} memory_kib={d}\n",
        .{
            label,
            name,
            one.instructions,
            one.host_calls,
            one.invocations,
            one.instances,
            @as(u64, one.memory_pages) * 64,
        },
    );
}

/// Core's line: its call scratch at its fullest and the request's arena, in KiB rounded up.
pub fn write_core(writer: *std.Io.Writer, request: *const Request) std.Io.Writer.Error!void {
    std.debug.assert(request.label_len <= label_len_max);

    try writer.print("counted {s} core scratch_kib={d} arena_kib={d} db_kib={d}\n", .{
        request.label(),
        (request.scratch_bytes + 1023) / 1024,
        (request.arena_bytes + 1023) / 1024,
        (request.db_bytes + 1023) / 1024,
    });
}

/// The compiled-in plugins' line: the pieces of work begun (an operation, a hook, a
/// modifier, a job, a scope) and the most memory they held together, in KiB.
pub fn write_compiled(writer: *std.Io.Writer, request: *const Request) std.Io.Writer.Error!void {
    std.debug.assert(request.label_len <= label_len_max);

    try writer.print("counted {s} compiled_in work={d} memory_kib={d}\n", .{
        request.label(),
        request.plugin_work,
        (request.plugin_bytes + 1023) / 1024,
    });
}

/// A plugin's figures with what an instance it still holds has used so far.
pub fn of(loaded: *const Loaded) Plugin {
    std.debug.assert(loaded.bytes.len > 0);

    var one = loaded.counted;

    if (loaded.instance) |*instance| {
        one.instructions += instance.instructions_used;
        one.memory_pages = @max(one.memory_pages, instance.memory_pages());
    }

    std.debug.assert(one.instructions >= loaded.counted.instructions);

    return one;
}

/// What the request open now cost in every plugin, the instances still held included.
pub fn total_of(loaded: []const Loaded) Plugin {
    std.debug.assert(loaded.len <= 1 << 16);

    var sum: Plugin = .{};

    for (loaded) |*one| {
        sum.add(of(one));
    }

    return sum;
}

/// The request's lines on the process's error output: a line for each installed plugin
/// that ran and their total, a line for the compiled-in plugins when they worked, and
/// core's own memory. Only what this host's own request did; a request that reached no
/// plugin says nothing.
pub fn say(request: *const Request, loaded: []const Loaded) void {
    std.debug.assert(request.on);
    std.debug.assert(loaded.len <= 1 << 16);

    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const label = request.label();
    const sum = total_of(loaded);

    if (sum.idle() and request.plugin_work == 0) {
        return;
    }

    for (loaded) |*plugin| {
        const one = of(plugin);

        if (!one.idle()) {
            write_plugin(&writer, label, plugin.name(), one) catch break;
        }
    }

    var told = request.*;

    told.db_bytes = db.memory_peak(false);

    const whole = written(&writer, &told, sum);

    whole catch {
        std.debug.print("{s}counted {s} cut\n", .{ writer.buffered(), label });
        return;
    };

    std.debug.print("{s}", .{writer.buffered()});
}

/// The totals: the installed plugins' when any ran, the compiled-in ones' when any
/// worked, then core's.
fn written(
    writer: *std.Io.Writer,
    request: *const Request,
    sum: Plugin,
) std.Io.Writer.Error!void {
    std.debug.assert(!sum.idle() or request.plugin_work > 0);

    if (!sum.idle()) {
        try write_plugin(writer, request.label(), "*", sum);
    }

    if (request.plugin_work > 0) {
        try write_compiled(writer, request);
    }

    return write_core(writer, request);
}

test "a request is named by the first label told and keeps the fullest memory" {
    var request: Request = .{};

    request.begin();
    try std.testing.expectEqualStrings("-", request.label());

    request.tell(.{
        .scratch_bytes = 2048,
    });
    request.tell(.{
        .label = "GET /a b",
        .arena_bytes = 10,
    });
    request.tell(.{
        .label = "later",
        .scratch_bytes = 1,
    });

    try std.testing.expectEqualStrings("GET_/a_b", request.label());

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_core(&writer, &request);
    try std.testing.expectEqualStrings(
        "counted GET_/a_b core scratch_kib=2 arena_kib=1 db_kib=0\n",
        writer.buffered(),
    );

    request.tell(.{
        .plugin_bytes = 65536,
        .plugin_work = 2,
    });
    request.tell(.{
        .plugin_bytes = 100,
        .plugin_work = 3,
    });
    writer = .fixed(&buffer);
    try written(&writer, &request, .{});
    try std.testing.expectEqualStrings(
        "counted GET_/a_b compiled_in work=5 memory_kib=64\n" ++
            "counted GET_/a_b core scratch_kib=2 arena_kib=1 db_kib=0\n",
        writer.buffered(),
    );

    request.begin();
    try std.testing.expectEqual(@as(u64, 0), request.scratch_bytes);
    try std.testing.expectEqual(@as(u64, 0), request.plugin_work);
}

test "a plugin's line says each measure, memory in KiB" {
    var total: Plugin = .{};
    const one: Plugin = .{
        .instructions = 1200,
        .host_calls = 3,
        .invocations = 2,
        .instances = 1,
        .memory_pages = 17,
    };

    try std.testing.expect(total.idle());
    total.add(one);
    total.add(.{
        .invocations = 1,
        .memory_pages = 4,
    });
    try std.testing.expect(!total.idle());

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_plugin(&writer, "orders.place", "*", total);
    try std.testing.expectEqualStrings(
        "counted orders.place plugin=* instructions=1200 host_calls=3 invocations=3 " ++
            "instances=1 memory_kib=1088\n",
        writer.buffered(),
    );
    try std.testing.expect(asked("1"));
    try std.testing.expect(!asked("0"));
    try std.testing.expect(!asked(null));
}
