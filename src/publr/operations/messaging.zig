//! What messaging providers report back of what they sent: a bounce or a complaint, raised as
//! core's events `messaging.bounced` and `messaging.complained` with the send's
//! reference, for whoever keeps who may be mailed.
const operation = @import("../operation.zig");

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

/// What became of a message: its server refused it, or the recipient marked it as spam.
pub const Kind = enum { bounced, complained };

pub const namespace: operation.Namespace = .{
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
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .message = "The id the provider's `send` answered for the message",
        .kind = "`bounced` or `complained`",
        .permanent = "A bounce for good (the address does not exist), not for now",
        .reason = "The provider's words for why",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .to = "The address the message was sent to",
        .reference = "The sender's reference for the send",
    };
};

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
    pub const kind: operation.Kind = .read;
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
    pub const field_docs: operation.Docs(In) = .{
        .html = "The email's own HTML, `{name}` where a value goes",
        .values = "The values merged in, by name",
        .lists = "Lists merged in, by name: each item's values, written once per item",
        .preheader = "The line a mail app shows after the subject",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .html = "The email as it is sent",
        .text = "Its words without markup, for mail apps that show text",
    };
};

pub const SetLayout = struct {
    pub const name = "messaging.set_layout";
    pub const description = "Set the layout every email the site sends wears";
    pub const details =
        \\Administrators only. HTML with `{content}` once, where each email goes; its
        \\`<style>` is written into the elements by `messaging render`. Empty puts the
        \\built-in layout back.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        layout: []const u8,
    };
    pub const Out = struct {};
    pub const example: In = .{
        .layout = "<html><body><div class=\"page\">{content}</div></body></html>",
    };
    pub const example_out: Out = .{};
    pub const field_docs: operation.Docs(In) = .{
        .layout = "The layout's HTML, `{content}` where the email goes; empty for the built-in",
    };
};
