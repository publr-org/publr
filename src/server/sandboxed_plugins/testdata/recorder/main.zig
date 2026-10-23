//! Keeps every structure change it hears, for the smoke.
//!
//! Keeps every structure change it hears, each a record of its own, and answers them back:
//! what a plugin recording deployments does, for the smoke to see each write heard `after` it
//! ran. Each as the write's name and what it changed (or the event's name and subject),
//! oldest first.
const std = @import("std");
const publr = @import("publr");

const operations = publr.operations;

const manifest: publr.Manifest = .{
    .name = "recorder",
    .version = "0.1.0",
};

pub const lines_max: u32 = 256;

/// A line heard
///
/// One change recorder heard.
pub const Line = struct {
    /// The write's name and what it changed: `content_type.create thing`
    line: []const u8,
};

pub const Lines = publr.record.define(Line, .{
    .name = "recorder.line",
    .internal = true,
});

const heard = publr.query.prepare(
    \\*[_type == "recorder.line"] | order(_createdAt asc) [0...256].line
, .{});

fn keep(ctx: anytype, name: []const u8, subject: []const u8) publr.Error!void {
    std.debug.assert(name.len > 0);

    _ = try Lines.create(ctx, .{
        .line = try std.fmt.allocPrint(ctx.arena(), "{s} {s}", .{ name, subject }),
    });
}

/// Keeps each content type made
fn type_made(
    ctx: *publr.Ctx,
    _: *operations.content_type.Create.In,
    out: *const operations.content_type.Create.Out,
) publr.Error!void {
    try keep(ctx, operations.content_type.Create.name, out.handle);
}

/// Keeps each taxonomy made
fn taxonomy_made(
    ctx: *publr.Ctx,
    _: *operations.taxonomy.Create.In,
    out: *const operations.taxonomy.Create.Out,
) publr.Error!void {
    try keep(ctx, operations.taxonomy.Create.name, out.handle);
}

/// Keeps each field group made
fn fields_made(
    ctx: *publr.Ctx,
    _: *operations.custom_fields.Create.In,
    out: *const operations.custom_fields.Create.Out,
) publr.Error!void {
    try keep(ctx, operations.custom_fields.Create.name, out.definition.handle);
}

/// Keeps each plugin added
fn plugin_added(
    ctx: *publr.Ctx,
    _: *operations.plugin.Add.In,
    out: *const operations.plugin.Add.Out,
) publr.Error!void {
    try keep(ctx, operations.plugin.Add.name, out.name);
}

/// Keeps each plugin enabled
fn plugin_enabled(
    ctx: *publr.Ctx,
    in: *operations.plugin.Enable.In,
    _: *const operations.plugin.Enable.Out,
) publr.Error!void {
    for (in.names) |name| {
        try keep(ctx, operations.plugin.Enable.name, name);
    }
}

/// Keeps the apps loaded
fn apps_loaded(ctx: *publr.QueueCtx, loaded: publr.sdk.AppsLoaded.Payload) publr.Error!void {
    try keep(ctx, publr.sdk.AppsLoaded.full_name, loaded.app);
}

pub const SeenIn = struct {};

pub const SeenOut = struct {
    /// Each change heard, oldest first
    lines: []const []const u8,
};

/// The structure changes heard
///
/// Administrators only.
///
/// Example:
///   in: {}
///   out: { "lines": ["content_type.create post"] }
pub const Seen = publr.operation.define(SeenIn, SeenOut, .{
    .name = "seen",
    .kind = .read,
    .run = seen,
});

fn seen(ctx: *publr.Ctx, _: SeenIn) publr.Error!SeenOut {
    std.debug.assert(lines_max == 256);

    return .{
        .lines = try heard.execute(ctx, []const []const u8, .{}),
    };
}

pub const plugin = publr.plugin.define(manifest, .{
    .records = &.{Lines},
    .operations = [_]type{Seen},
    .hooks = &.{
        publr.after(operations.content_type.Create, type_made),
        publr.after(operations.taxonomy.Create, taxonomy_made),
        publr.after(operations.custom_fields.Create, fields_made),
        publr.after(operations.plugin.Add, plugin_added),
        publr.after(operations.plugin.Enable, plugin_enabled),
        publr.on(publr.sdk.AppsLoaded, apps_loaded),
    },
});
