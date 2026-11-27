//! What a built-in plugin's middleware (`host.middleware`) hears, and when: `.pre` runs
//! before any operation with its name and kind (`fn run(ctx, name, kind) publr.Error!void`,
//! a refusal stops it), `.on` hears each operation's end and each event emitted (`fn
//! run(ctx, event: publr.Host.Event) void`). `run` may take `*publr.Ctx`.

/// `modify` changes a value applied under a name (`mods.zig`), never what an operation does.
pub const Stage = enum { pre, before, after, on, modify };

/// An operation's end, refused or failed alike, or an event emitted.
pub const Event = union(enum) {
    completed: Ended,
    failed: Ended,
    emitted: Emitted,

    pub const Ended = struct {
        operation_name: []const u8,
        operation_id: u64,
    };
    /// An event emitted under its name (`<plugin>.<event>`, `role.created`, or an operation's
    /// own on success), its payload as JSON.
    pub const Emitted = struct {
        operation_id: u64,
        name: []const u8,
        subject: []const u8,
    };
};
