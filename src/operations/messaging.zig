//! What messaging providers report back of what they sent: a bounce or a complaint, raised as
//! core's events `messaging.bounced` and `messaging.complained` with the send's
//! reference, for whoever keeps who may be mailed.
const std = @import("std");
const sdk = @import("../sdk.zig");
const messaging = @import("../sdk/messaging.zig");
const delivery = @import("../sdk/messaging/delivery.zig");
const contract = @import("../sdk/contract.zig");
const store = @import("../store.zig");
const css_inline = @import("../model/css_inline.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace: sdk.operation.Namespace = .{
    .name = "messaging",
    .label = "Messaging",
    .area = .system,
    .summary = "What messaging providers report of the messages they sent",
    .details =
    \\Publr sends nothing itself: a plugin emits a message (`publr.messaging.Email`) and a
    \\messaging provider sends it. A provider reports later what became of one (its server
    \\refused it, the recipient marked it as spam) with `messaging feedback`, from its
    \\webhook's run; core raises `messaging.bounced` or `messaging.complained`
    \\with the sender's reference for the send.
    ,
};

pub const operations = [_]type{ Feedback, Render, SetLayout };

/// The setting the site-wide email layout is kept under: HTML with `{content}` where each
/// email goes.
pub const layout_setting = "messaging.layout";

/// The layout every plugin's email wears until the site sets its own.
pub const layout_default =
    \\<!DOCTYPE html><html><head><meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width"><style>
    \\body { margin: 0; padding: 0; background: #f4f4f5; font-family: Helvetica, Arial, sans-serif }
    \\.page { max-width: 600px; margin: 0 auto; padding: 24px; background: #ffffff }
    \\p { font-size: 16px; line-height: 24px; color: #18181b }
    \\a { color: #18181b }
    \\</style></head><body><div class="page">{content}</div></body></html>
;

/// A value merged into an email: `{name}` in its HTML becomes `value`, escaped.
pub const Value = struct {
    name: []const u8,
    value: []const u8,
};

/// A list merged into an email (an order's lines): the part between `{#name}` and `{/name}`
/// is written once for each item, its `{name}`s taking the item's values.
pub const List = struct {
    name: []const u8,
    items: []const []const Value = &.{},
};

/// The most lists one email holds, and items one list.
pub const lists_max: u32 = 16;
pub const items_max: u32 = 200;

pub const Kind = enum { bounced, complained };

pub const Feedback = struct {
    pub const name = "messaging.feedback";
    /// A plugin's alone: not listed among the commands people and agents run.
    pub const plugins_only = true;
    pub const description = "Report a message a provider sent as bounced or complained of";
    pub const details =
        \\Plugins registering a messaging provider only, for messages they sent: the message
        \\by the id their `send` answered. Raises `messaging.bounced` (`permanent` when
        \\the address will never take mail) or `messaging.complained`, naming the
        \\address, the provider, the message and the sender's `reference`. A message the
        \\site did not send through it answers not found.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        message: []const u8,
        kind: Kind,
        permanent: bool = true,
        reason: []const u8 = "",
    };
    pub const Out = struct {
        to: []const u8,
        reference: []const u8,
    };
    pub const example: In = .{
        .message = "0102018c-4f6a",
        .kind = .bounced,
        .reason = "550 5.1.1 The email account does not exist",
    };
    pub const example_out: Out = .{
        .to = "ada@example.com",
        .reference = "order 1024",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .message = "The id the provider's `send` answered for the message",
        .kind = "`bounced` or `complained`",
        .permanent = "A bounce for good (the address does not exist), not for now",
        .reason = "The provider's words for why",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .to = "The address the message was sent to",
        .reference = "The sender's reference for the send",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const provider = try provider_of(ctx);
        const sent = try delivery.sent_of(ctx, provider, in.message) orelse {
            return error.NotFound;
        };
        const said: messaging.Feedback = .{
            .to = sent.to,
            .provider = provider,
            .message = in.message,
            .reference = sent.reference,
            .permanent = in.kind == .complained or in.permanent,
            .reason = in.reason,
        };

        switch (in.kind) {
            .bounced => ctx.emit(messaging.Bounced, said),
            .complained => ctx.emit(messaging.Complained, said),
        }

        return .{
            .to = sent.to,
            .reference = sent.reference,
        };
    }
};

/// The messaging provider the calling plugin registers; refused for any other caller.
fn provider_of(ctx: *Ctx) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    const plugin = switch (ctx.caller) {
        .plugin => |caller| caller.name,
        else => ctx.plugin,
    };

    if (plugin.len == 0) {
        return error.Denied;
    }

    for (try contract.listed(ctx, messaging.contract.contract_name)) |one| {
        if (std.mem.eql(u8, one.provider.plugin, plugin)) {
            return one.provider.name;
        }
    }

    return error.Denied;
}

pub const Render = struct {
    pub const name = "messaging.render";
    pub const description = "Make an email's HTML: the site's layout, the values merged, " ++
        "CSS inlined";
    pub const details =
        \\Plugins and administrators. The email's HTML goes where the site's layout says
        \\`{content}` (Settings: `messaging set_layout`); each `{name}` takes its value,
        \\escaped; the rules of its `<style>` blocks are written into the elements they match,
        \\as mail apps want; the text version is the same words without the markup. A
        \\preheader opens it hidden. A list (an order's lines) writes the part between
        \\`{#lines}` and `{/lines}` once per item, each with its own values. For a preview, send
        \\the template's sample values.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        html: []const u8,
        values: []const Value = &.{},
        lists: []const List = &.{},
        preheader: []const u8 = "",
    };
    pub const Out = struct {
        html: []const u8,
        text: []const u8,
    };
    pub const example: In = .{
        .html = "<p>Thank you, {name}.</p>",
        .values = &.{.{
            .name = "name",
            .value = "Ada",
        }},
    };
    pub const example_out: Out = .{
        .html = "<!DOCTYPE html>…<p style=\"font-size: 16px\">Thank you, Ada.</p>…",
        .text = "Thank you, Ada.",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .html = "The email's own HTML, `{name}` where a value goes",
        .values = "The values merged in, by name",
        .lists = "Lists merged in, by name: each item's values, written once per item",
        .preheader = "The line a mail app shows after the subject",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .html = "The email as it is sent",
        .text = "Its words without markup, for mail apps that show text",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        if (in.html.len > css_inline.html_bytes_max or in.values.len > 256) {
            return error.Invalid;
        }

        if (in.lists.len > lists_max) {
            return error.Invalid;
        }

        const layout = try store.settings.get(ctx.db, ctx.arena, layout_setting) orelse
            layout_default;
        const listed = try merge_lists(ctx.arena, in.html, in.lists);
        const merged = try merge(ctx.arena, listed, in.values);
        const content = if (in.preheader.len > 0) try std.mem.concat(ctx.arena, u8, &.{
            "<div style=\"display:none;max-height:0;overflow:hidden;opacity:0\">",
            try escaped(ctx.arena, in.preheader),
            "</div>",
            merged,
        }) else merged;
        const whole = try std.mem.replaceOwned(u8, ctx.arena, layout, "{content}", content);
        const html = css_inline.inline_css(ctx.arena, whole) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => return error.Invalid,
        };

        return .{
            .html = html,
            .text = try text_of(ctx.arena, merged),
        };
    }
};

pub const SetLayout = struct {
    pub const name = "messaging.set_layout";
    pub const description = "Set the layout every email the site sends wears";
    pub const details =
        \\Administrators only. HTML with `{content}` once, where each email goes; its
        \\`<style>` is written into the elements by `messaging render`. Empty puts the
        \\built-in layout back.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        layout: []const u8,
    };
    pub const Out = struct {};
    pub const example: In = .{
        .layout = "<html><body><div class=\"page\">{content}</div></body></html>",
    };
    pub const example_out: Out = .{};
    pub const field_docs: sdk.operation.Docs(In) = .{
        .layout = "The layout's HTML, `{content}` where the email goes; empty for the built-in",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.layout.len == 0) {
            try store.settings.delete(ctx.db, layout_setting);

            return .{};
        }

        if (std.mem.count(u8, in.layout, "{content}") != 1) {
            return error.Invalid;
        }

        try store.settings.set(ctx.db, layout_setting, in.layout, ctx.now_ms);

        return .{};
    }
};

fn merge(arena: std.mem.Allocator, html: []const u8, values: []const Value) Error![]const u8 {
    std.debug.assert(values.len <= 256);
    std.debug.assert(html.len <= css_inline.html_bytes_max);

    var out = html;

    for (values) |value| {
        if (value.name.len == 0 or value.name.len > 64) {
            return error.Invalid;
        }

        const hole = try std.mem.concat(arena, u8, &.{ "{", value.name, "}" });

        out = try std.mem.replaceOwned(u8, arena, out, hole, try escaped(arena, value.value));
    }

    return out;
}

/// Each list's `{#name}…{/name}` written once per item, the item's values merged in it.
fn merge_lists(arena: std.mem.Allocator, html: []const u8, lists: []const List) Error![]const u8 {
    std.debug.assert(lists.len <= lists_max);
    std.debug.assert(html.len <= css_inline.html_bytes_max);

    var out = html;

    for (lists) |list| {
        if (list.name.len == 0 or list.name.len > 64 or list.items.len > items_max) {
            return error.Invalid;
        }

        const open = try std.mem.concat(arena, u8, &.{ "{#", list.name, "}" });
        const close = try std.mem.concat(arena, u8, &.{ "{/", list.name, "}" });
        const start = std.mem.indexOf(u8, out, open) orelse continue;
        const inner_start = start + open.len;
        const end = std.mem.indexOfPos(u8, out, inner_start, close) orelse return error.Invalid;
        var written: std.ArrayList(u8) = .empty;

        for (list.items) |item| {
            try written.appendSlice(arena, try merge(arena, out[inner_start..end], item));
        }

        const after = out[end + close.len ..];

        out = try std.mem.concat(arena, u8, &.{ out[0..start], written.items, after });
    }

    if (out.len > css_inline.html_bytes_max) {
        return error.Invalid;
    }

    return out;
}

fn escaped(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    std.debug.assert(text.len <= 1 << 24);

    var out: std.ArrayList(u8) = .empty;

    for (text) |char| {
        switch (char) {
            '<' => try out.appendSlice(arena, "&lt;"),
            '>' => try out.appendSlice(arena, "&gt;"),
            '&' => try out.appendSlice(arena, "&amp;"),
            '"' => try out.appendSlice(arena, "&quot;"),
            else => try out.append(arena, char),
        }
    }

    return out.items;
}

/// The words of `html` without its markup: a line for each paragraph, break, item and table
/// row, a row's cells apart by a tab (an order's line, then its amount), links written after
/// their words.
fn text_of(arena: std.mem.Allocator, html: []const u8) error{OutOfMemory}![]const u8 {
    std.debug.assert(html.len <= css_inline.html_bytes_max);

    var out: std.ArrayList(u8) = .empty;
    var at: u32 = 0;
    var cells: u32 = 0;

    while (std.mem.indexOfScalarPos(u8, html, at, '<')) |open| {
        const close = std.mem.indexOfScalarPos(u8, html, open, '>') orelse break;
        const tag = html[open + 1 .. close];

        try out.appendSlice(arena, html[at..open]);

        if (named(tag, "tr")) {
            cells = 0;
        }

        if (named(tag, "td") or named(tag, "th")) {
            if (cells > 0) {
                try out.append(arena, '\t');
            }

            cells += 1;
        }

        const ends_line = std.mem.startsWith(u8, tag, "/p") or
            std.mem.startsWith(u8, tag, "br") or std.mem.startsWith(u8, tag, "/li") or
            std.mem.startsWith(u8, tag, "/h") or std.mem.startsWith(u8, tag, "/tr");

        if (ends_line) {
            try out.append(arena, '\n');
        }

        at = @intCast(close + 1);
    }

    try out.appendSlice(arena, html[at..]);

    const entities = [_][2][]const u8{
        .{ "&lt;", "<" },
        .{ "&gt;", ">" },
        .{ "&quot;", "\"" },
        .{ "&amp;", "&" },
    };
    var text: []const u8 = out.items;

    for (entities) |pair| {
        text = try std.mem.replaceOwned(u8, arena, text, pair[0], pair[1]);
    }

    return std.mem.trim(u8, text, " \n");
}

/// Whether `tag` (what is between `<` and `>`) opens the element `name`.
fn named(tag: []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    if (!std.mem.startsWith(u8, tag, name)) {
        return false;
    }

    if (tag.len == name.len) {
        return true;
    }

    return std.mem.indexOfScalar(u8, " /\t\n", tag[name.len]) != null;
}

test "an email: the layout around it, values merged and escaped, CSS inlined, its text" {
    const TestSDK = sdk.SDK(.{
        .operations = &operations,
    });
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const rendered = try TestSDK.dispatch(&ctx, Render, .{
        .html = "<p>Thank you, {name}.</p><p>Order {order}</p>",
        .values = &.{
            .{
                .name = "name",
                .value = "Ada <3",
            },
            .{
                .name = "order",
                .value = "1024",
            },
        },
        .preheader = "Your order is in",
    });

    try std.testing.expect(std.mem.indexOf(u8, rendered.html, "Thank you, Ada &lt;3.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.html, "<p style=\"font-size") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.html, "Your order is in") != null);
    try std.testing.expectEqualStrings("Thank you, Ada <3.\nOrder 1024", rendered.text);

    _ = try TestSDK.dispatch(&ctx, SetLayout, .{
        .layout = "<main>{content}</main>",
    });

    const plain = try TestSDK.dispatch(&ctx, Render, .{
        .html = "<b>Hi</b>",
    });

    try std.testing.expectEqualStrings("<main><b>Hi</b></main>", plain.html);

    const lines = try TestSDK.dispatch(&ctx, Render, .{
        .html = "<ul>{#lines}<li>{title} x {quantity}</li>{/lines}</ul>",
        .lists = &.{.{
            .name = "lines",
            .items = &.{
                &.{
                    .{
                        .name = "title",
                        .value = "Tea & honey",
                    },
                    .{
                        .name = "quantity",
                        .value = "2",
                    },
                },
                &.{
                    .{
                        .name = "title",
                        .value = "Cup",
                    },
                    .{
                        .name = "quantity",
                        .value = "1",
                    },
                },
            },
        }},
    });

    try std.testing.expectEqualStrings(
        "<main><ul><li>Tea &amp; honey x 2</li><li>Cup x 1</li></ul></main>",
        lines.html,
    );

    const table = try TestSDK.dispatch(&ctx, Render, .{
        .html = "<table><tr><td style=\"a\">Tea × 1</td><td>65,00 zł</td></tr>" ++
            "<tr><td><strong>Total</strong></td><td><strong>116,99 zł</strong></td></tr></table>",
    });

    try std.testing.expectEqualStrings("Tea × 1\t65,00 zł\nTotal\t116,99 zł", table.text);
    try std.testing.expectError(error.Invalid, TestSDK.dispatch(&ctx, SetLayout, .{
        .layout = "<main></main>",
    }));
}
