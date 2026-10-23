//! `publr.job.define(In, .{ .name, .run, .on_failure })`: work a plugin's code queues with
//! `ctx.enqueue(Job, in)`, run later by the server's worker, as the plugin, never in the
//! caller's request. A run that fails is tried again later; after the last attempt
//! `on_failure` hears the `publr.Error` it ended with (`ctx.failure()` names a declared
//! refusal), and the job is kept as failed.
const std = @import("std");

/// The runs a job gets before it is kept as failed.
pub const attempts_max: u32 = 8;
/// The wait after a first failure, doubling with each one after it.
pub const backoff_ms_min: i64 = 60 * 1000;
/// The longest wait between two runs.
pub const backoff_ms_max: i64 = 24 * 60 * 60 * 1000;

/// How often a repeating job runs.
pub const Every = union(enum) {
    day,
    hour,
    minutes: u32,
};

/// When in the day (`.every = .day`) or the hour (`.every = .hour`, `minute` only) it runs,
/// in UTC.
pub const At = struct {
    hour: u8 = 0,
    minute: u8 = 0,
};

const minute_ms: i64 = 60 * 1000;
const hour_ms: i64 = 60 * minute_ms;
const day_ms: i64 = 24 * hour_ms;

/// A job code queues with `ctx.enqueue(Job, in)`: `publr.job.define(In, .{ .name, .run,
/// .on_failure, .on_conflict })`.
pub fn define(comptime In: type, comptime options: anytype) type {
    comptime {
        if (@hasField(@TypeOf(options), "every") or @hasField(@TypeOf(options), "at")) {
            @compileError("a repeating job is `publr.job.define_recurring(.{ .name, .run, " ++
                ".every, .at })`");
        }
    }

    return Defined(In, options);
}

/// A job that runs on its own, again and again: `publr.job.define_recurring(.{ .name, .run,
/// .every = .day, .at = .{ .hour = 3 } })`; its `run` takes no input.
pub fn define_recurring(comptime options: anytype) type {
    comptime {
        if (!@hasField(@TypeOf(options), "every")) {
            @compileError("a recurring job says how often: `.every = .day`, `.hour` or " ++
                "`.{ .minutes = 15 }`");
        }
    }

    return Defined(void, options);
}

fn Defined(comptime In: type, comptime options: anytype) type {
    const Options = @TypeOf(options);

    comptime {
        if (!@hasField(Options, "name") or !@hasField(Options, "run")) {
            @compileError("a job takes `.name` and `.run`");
        }

        if (options.name.len == 0 or std.mem.indexOfScalar(u8, options.name, '.') != null) {
            @compileError("a job's `.name` is one word under its plugin: " ++ options.name);
        }

        for (std.meta.fieldNames(Options)) |field| {
            const known = std.mem.eql(u8, field, "name") or std.mem.eql(u8, field, "run") or
                std.mem.eql(u8, field, "on_failure") or std.mem.eql(u8, field, "every") or
                std.mem.eql(u8, field, "at") or std.mem.eql(u8, field, "on_conflict");

            if (!known) {
                @compileError("a job takes `.name`, `.run`, `.on_failure`, `.on_conflict`, " ++
                    "`.every` and `.at`, not `." ++ field ++ "`; `.due` comes with a later gate");
            }
        }
    }

    return struct {
        pub const is_job = true;
        pub const Input = In;
        pub const verb: []const u8 = options.name;
        pub const run = options.run;
        pub const on_failure = if (@hasField(Options, "on_failure")) options.on_failure else null;
        /// Heard when a run ends in `Conflict` (what it changes was changed meanwhile): the
        /// job is not run again, and keeps the record and the person's values.
        pub const on_conflict = if (@hasField(Options, "on_conflict"))
            options.on_conflict
        else
            null;
        pub const every: ?Every = if (@hasField(Options, "every"))
            every_of(options.every)
        else
            null;
        pub const at: At = if (@hasField(Options, "at")) at_of(options.at) else .{};
    };
}

fn every_of(comptime given: anytype) Every {
    const made: Every = if (@TypeOf(given) == Every)
        given
    else if (@typeInfo(@TypeOf(given)) == .enum_literal)
        @field(Every, @tagName(given))
    else
        .{
            .minutes = given.minutes,
        };

    if (made == .minutes and (made.minutes == 0 or made.minutes > 24 * 60)) {
        @compileError("`.every = .{ .minutes = n }` takes 1 to 1,440 minutes");
    }

    std.debug.assert(made != .minutes or made.minutes > 0);

    return made;
}

fn at_of(comptime given: anytype) At {
    var made: At = .{};

    inline for (std.meta.fields(@TypeOf(given))) |field| {
        @field(made, field.name) = @field(given, field.name);
    }

    if (made.hour >= 24 or made.minute >= 60) {
        @compileError("`.at` is an hour of 0 to 23 and a minute of 0 to 59");
    }

    std.debug.assert(made.hour < 24 and made.minute < 60);

    return made;
}

pub fn is_job(comptime Candidate: type) bool {
    return @typeInfo(Candidate) == .@"struct" and @hasDecl(Candidate, "is_job");
}

/// The first moment after `now_ms` a job repeating `every`, `at`, runs.
pub fn next_after(every: Every, at: At, now_ms: i64) i64 {
    std.debug.assert(now_ms >= 0);
    std.debug.assert(at.hour < 24 and at.minute < 60);

    const period: i64, const offset: i64 = switch (every) {
        .day => .{ day_ms, at.hour * hour_ms + at.minute * minute_ms },
        .hour => .{ hour_ms, at.minute * minute_ms },
        .minutes => |count| .{ @max(count, 1) * minute_ms, 0 },
    };
    const next = @divFloor(now_ms - offset, period) * period + period + offset;

    std.debug.assert(next > now_ms and next - now_ms <= period);

    return next;
}

/// When a job that has failed `attempts` times runs again: a minute, doubling, up to a day.
pub fn backoff_ms(attempts: u32) i64 {
    std.debug.assert(attempts < attempts_max);
    std.debug.assert(backoff_ms_min < backoff_ms_max);

    const doubled = backoff_ms_min << @intCast(attempts);

    return @min(doubled, backoff_ms_max);
}

test "a job's waits double from a minute and stop at a day" {
    try std.testing.expectEqual(backoff_ms_min, backoff_ms(0));
    try std.testing.expectEqual(backoff_ms_min * 4, backoff_ms(2));
    try std.testing.expect(backoff_ms(attempts_max - 1) <= backoff_ms_max);

    const Hold = struct {
        hold: []const u8,
    };
    const Release = define(Hold, .{
        .name = "release_hold",
        .run = struct {
            fn run(_: *anyopaque, _: Hold) error{Failed}!void {}
        }.run,
    });

    try std.testing.expect(is_job(Release));
    try std.testing.expect(Release.every == null);

    // 2026-10-19 10:30 UTC: the next 03:00 is tomorrow's, the next hour at :15 is 11:15.
    const now_ms: i64 = 1_792_405_800_000;

    try std.testing.expectEqual(now_ms + 16 * hour_ms + 30 * minute_ms, next_after(.day, .{
        .hour = 3,
    }, now_ms));
    try std.testing.expectEqual(now_ms + 45 * minute_ms, next_after(.hour, .{
        .minute = 15,
    }, now_ms));
    try std.testing.expectEqual(now_ms + 15 * minute_ms, next_after(.{
        .minutes = 15,
    }, .{}, now_ms));
    try std.testing.expect(!is_job(Hold));
    try std.testing.expectEqualStrings("release_hold", Release.verb);
}
