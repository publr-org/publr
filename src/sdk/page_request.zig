//! Request hooks: plugins seeing a page request before it is drawn
//! (`publr.hook.request(run)` in `.hooks`). A hook reads the path, headers and cookies, may
//! set a response header, choose a dimension's value for the page (an A/B test's
//! variation), and answers by going on (`request.next()`), redirecting or refusing. It reads
//! only, never calls out: a page waits on it. Hooks run in plugin order; the first redirect
//! or refusal ends the rest. Pages stay static: what a hook chooses is only how they are
//! read.

const std = @import("std");
const model_dimension = @import("../model/dimension.zig");
const context = @import("context.zig");
const operation = @import("operation.zig");

const Pair = model_dimension.Pair;

pub const hooks_max: u32 = 16;
pub const headers_max: u32 = 8;

/// What every hook answers, made only by `next`, `redirect` and `refuse`: a hook cannot end
/// without saying which.
pub const Answered = struct {
    said: Said,

    const Said = enum {
        next,
        ended,
    };
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Ending = union(enum) {
    /// Draw the page.
    next,
    /// Send the visitor elsewhere: 301, 302 or 303.
    redirect: struct {
        to: []const u8,
        status: u16,
    },
    /// Answer this status instead of the page: 403, or 503 for maintenance.
    refuse: u16,
};

pub const PageRequest = struct {
    path_text: []const u8,
    /// The address's query, after `?`.
    query_text: []const u8 = "",
    /// Reads a request header by name, case-insensitively.
    header_of: *const fn (source: *const anyopaque, name: []const u8) ?[]const u8,
    source: *const anyopaque,
    chosen: [model_dimension.dimensions_max]Pair = undefined,
    chosen_len: u32 = 0,
    headers: [headers_max]Header = undefined,
    headers_len: u32 = 0,
    ending: Ending = .next,

    /// The path asked for, under the language's address taken off: `/about`.
    pub fn path(request: *const PageRequest) []const u8 {
        std.debug.assert(request.path_text.len > 0);

        return request.path_text;
    }

    pub fn header(request: *const PageRequest, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);

        return request.header_of(request.source, name);
    }

    /// A cookie the visitor sent, by name.
    pub fn cookie(request: *const PageRequest, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);

        const sent = request.header("cookie") orelse return null;
        var parts = std.mem.splitScalar(u8, sent, ';');

        while (parts.next()) |part| {
            const pair = std.mem.trim(u8, part, " ");
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;

            if (std.mem.eql(u8, pair[0..equals], name)) {
                return pair[equals + 1 ..];
            }
        }

        return null;
    }

    /// A value of the address's query as sent, not decoded: `?variation=b` gives `b`.
    pub fn query(request: *const PageRequest, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(request.query_text.len <= 64 << 10);

        var parts = std.mem.splitScalar(u8, request.query_text, '&');

        while (parts.next()) |part| {
            const equals = std.mem.indexOfScalar(u8, part, '=') orelse continue;

            if (std.mem.eql(u8, part[0..equals], name)) {
                return part[equals + 1 ..];
            }
        }

        return null;
    }

    /// Reads the page in `dimension` at `code` (empty: its main value). A dimension chosen
    /// twice keeps the later code; the core checks both against the site's dimensions.
    pub fn choose(request: *PageRequest, dimension: []const u8, code: []const u8) void {
        std.debug.assert(dimension.len > 0);
        std.debug.assert(request.chosen_len <= model_dimension.dimensions_max);

        for (request.chosen[0..request.chosen_len]) |*pair| {
            if (std.mem.eql(u8, pair.dimension, dimension)) {
                pair.code = code;

                return;
            }
        }

        if (request.chosen_len == model_dimension.dimensions_max) {
            return;
        }

        request.chosen[request.chosen_len] = .{
            .dimension = dimension,
            .code = code,
        };
        request.chosen_len += 1;
    }

    /// A header on the answer, whatever ends it: a cookie that keeps a visitor's variation.
    pub fn set_header(request: *PageRequest, name: []const u8, value: []const u8) void {
        std.debug.assert(name.len > 0);
        std.debug.assert(request.headers_len <= headers_max);

        if (request.headers_len == headers_max) {
            return;
        }

        request.headers[request.headers_len] = .{
            .name = name,
            .value = value,
        };
        request.headers_len += 1;
    }

    pub fn next(request: *PageRequest) Answered {
        std.debug.assert(request.ending == .next);
        std.debug.assert(request.path_text.len > 0);

        return .{
            .said = .next,
        };
    }

    pub fn redirect(request: *PageRequest, to: []const u8, status: u16) Answered {
        std.debug.assert(to.len > 0);

        const known = status == 301 or status == 302 or status == 303;

        request.ending = .{
            .redirect = .{
                .to = to,
                .status = if (known) status else 302,
            },
        };

        return .{
            .said = .ended,
        };
    }

    pub fn refuse(request: *PageRequest, status: u16) Answered {
        std.debug.assert(request.path_text.len > 0);

        const known = status == 403 or status == 503;

        request.ending = .{
            .refuse = if (known) status else 403,
        };

        return .{
            .said = .ended,
        };
    }

    pub fn chosen_pairs(request: *const PageRequest) []const Pair {
        std.debug.assert(request.chosen_len <= model_dimension.dimensions_max);

        return request.chosen[0..request.chosen_len];
    }
};

/// One plugin's hook, as the server runs it: on the system's context, as the plugin.
pub const Hook = struct {
    plugin: []const u8,
    run: *const fn (ctx: *context.Ctx, request: *PageRequest) operation.Error!Answered,
};

/// Every hook in turn until one redirects or refuses. A hook that fails is logged and
/// skipped: a page never fails on a plugin's hook.
pub fn run_all(hooks: []const Hook, ctx: *context.Ctx, request: *PageRequest) void {
    std.debug.assert(hooks.len <= hooks_max);
    std.debug.assert(request.ending == .next);

    for (hooks) |hook| {
        const saved = ctx.plugin;

        ctx.plugin = hook.plugin;
        defer ctx.plugin = saved;

        const answered = hook.run(ctx, request) catch |err| {
            std.log.warn("a request hook of {s} failed: {t}", .{ hook.plugin, err });

            continue;
        };

        if (answered.said == .ended) {
            return;
        }
    }
}

test "a request hook's request: cookies read, a dimension chosen, an ending kept" {
    const Headers = struct {
        fn of(_: *const anyopaque, name: []const u8) ?[]const u8 {
            std.debug.assert(name.len > 0);

            return if (std.ascii.eqlIgnoreCase(name, "cookie"))
                "a=1; publr_variation=b"
            else
                null;
        }
    };
    const source: u8 = 0;
    var request: PageRequest = .{
        .path_text = "/about",
        .header_of = Headers.of,
        .source = &source,
        .query_text = "x=1&variation=c",
    };

    try std.testing.expectEqualStrings("b", request.cookie("publr_variation").?);
    try std.testing.expect(request.cookie("none") == null);
    try std.testing.expectEqualStrings("c", request.query("variation").?);

    request.choose("variation", "a");
    request.choose("variation", "b");

    try std.testing.expectEqual(@as(usize, 1), request.chosen_pairs().len);
    try std.testing.expectEqualStrings("b", request.chosen_pairs()[0].code);

    const answered = request.redirect("/elsewhere", 999);

    try std.testing.expectEqual(Answered.Said.ended, answered.said);
    try std.testing.expectEqual(@as(u16, 302), request.ending.redirect.status);
}
