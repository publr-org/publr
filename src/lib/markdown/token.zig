//! What a run of inline text is read into before it is written: every piece that is not
//! plain text, by its place in the input.

const std = @import("std");

pub const Tag = enum {
    em,
    strong,
    del,

    pub fn name(tag: Tag) []const u8 {
        const text = switch (tag) {
            .em => "em",
            .strong => "strong",
            .del => "del",
        };

        std.debug.assert(text.len > 0);

        return text;
    }
};

/// The tags one run of `*`, `_` or `~` may open or close; a longer run's rest is text.
pub const tags_per_run_max: u32 = 4;

pub const Kind = enum {
    /// `` `code` ``: `inner_start..inner_end` is the code.
    code,
    /// An inline tag the author wrote, kept as it is.
    html,
    /// `<https://…>` or `<name@host>`: `href` is the address.
    autolink,
    /// `\*`: the character after the backslash, as text.
    escape,
    /// Two spaces or a backslash before a line's end.
    hard_break,
    /// `[` of a link whose `](href "title")` is found; its text follows as tokens.
    link_open,
    /// The `](…)` closing the link opened before it.
    link_close,
    /// `![alt](src "title")`, whole: `inner_start..inner_end` is the alt text.
    image,
    /// A run of `*`, `_` or `~~` that may open or close emphasis.
    delimiter,
};

pub const Token = struct {
    kind: Kind,
    start: u32,
    /// Exclusive: where the text after the token starts.
    end: u32,
    inner_start: u32 = 0,
    inner_end: u32 = 0,
    href: []const u8 = "",
    title: []const u8 = "",
    marker: u8 = 0,
    can_open: bool = false,
    can_close: bool = false,
    /// The run's characters not yet paired.
    remaining: u32 = 0,
    opens: [tags_per_run_max]Tag = undefined,
    opens_len: u32 = 0,
    closes: [tags_per_run_max]Tag = undefined,
    closes_len: u32 = 0,

    /// The tag this run opens, outermost first: a later pairing is nearer the text.
    pub fn open(token: *Token, tag: Tag) void {
        std.debug.assert(token.kind == .delimiter);
        std.debug.assert(token.opens_len < tags_per_run_max);

        var index = token.opens_len;

        while (index > 0) : (index -= 1) {
            token.opens[index] = token.opens[index - 1];
        }

        token.opens[0] = tag;
        token.opens_len += 1;
    }

    /// The tag this run closes, innermost first.
    pub fn close(token: *Token, tag: Tag) void {
        std.debug.assert(token.kind == .delimiter);
        std.debug.assert(token.closes_len < tags_per_run_max);

        token.closes[token.closes_len] = tag;
        token.closes_len += 1;
    }
};

test "a run opens its tags outermost first and closes them innermost first" {
    var token: Token = .{
        .kind = .delimiter,
        .start = 0,
        .end = 3,
    };

    token.open(.em);
    token.open(.strong);
    token.close(.strong);
    token.close(.em);

    try std.testing.expectEqual(Tag.strong, token.opens[0]);
    try std.testing.expectEqual(Tag.em, token.opens[1]);
    try std.testing.expectEqual(Tag.strong, token.closes[0]);
    try std.testing.expectEqualStrings("del", Tag.del.name());
}
