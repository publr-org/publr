const std = @import("std");
const sanitize = @import("../sanitize.zig").sanitize;
const Profile = @import("../sanitize.zig").Profile;

const Case = struct { input: []const u8, profile: Profile = .content, wanted: []const u8 };

/// A link the sanitizer kept, its address gone: what is left of a dangerous one.
const bare_link = "<a rel=\"nofollow noopener\">go</a>";

const hostile = [_]Case{
    .{ .input = "<script>alert(1)</script>ok", .wanted = "ok" },
    .{ .input = "<SCRIPT src=x></SCRIPT>ok", .wanted = "ok" },
    .{ .input = "<script>never closed", .wanted = "" },
    .{ .input = "<scr<script>ipt>alert(1)</script>", .wanted = "&lt;scr" },
    .{ .input = "<img src=x onerror=alert(1)>", .wanted = "<img src=\"x\">" },
    .{ .input = "<IMG SRC=x ONERROR=alert(1)>", .wanted = "<img src=\"x\">" },
    .{
        .input = "<svg onload=alert(1)><circle/></svg>after",
        .wanted = "<svg><circle/></svg>after",
    },
    .{ .input = "<iframe src=\"https://evil\"></iframe>", .wanted = "" },
    .{ .input = "<style>body{}</style>text", .wanted = "text" },
    .{ .input = "<!-- <script>x</script> -->text", .wanted = "text" },
    .{ .input = "<img src=\"data:image/svg+xml,x\">", .wanted = "<img>" },
    .{ .input = "<p style=\"x\" id=\"y\" class=\"c\">t</p>", .wanted = "<p class=\"c\">t</p>" },
    .{ .input = "<a href=\"javascript:alert(1)\" onclick=\"x\">go</a>", .wanted = bare_link },
    .{ .input = "<a href=\"jav&#x61;script:alert(1)\">go</a>", .wanted = bare_link },
    .{ .input = "<a href=\" javascript:alert(1)\">go</a>", .wanted = bare_link },
    .{ .input = "<a href=\"java\tscript:alert(1)\">go</a>", .wanted = bare_link },
    .{ .input = "<a href=\"VBScript:x\">go</a>", .wanted = bare_link },
    .{ .input = "<a href=\"//evil.example\">go</a>", .wanted = bare_link },
    .{
        .input = "<b title='a\"onmouseover=\"x'>t</b>",
        .wanted = "<b title=\"a&quot;onmouseover=&quot;x\">t</b>",
    },
};

const drawings = [_]Case{
    .{
        .input = "<svg viewBox=\"0 0 24 24\"><path d=\"M0 0\"/><path d=\"M1 1\"/></svg>",
        .wanted = "<svg viewbox=\"0 0 24 24\"><path d=\"M0 0\"/><path d=\"M1 1\"/></svg>",
    },
    .{ .input = "<svg><title>Logo</title></svg>", .wanted = "<svg><title>Logo</title></svg>" },
    .{
        .input = "<svg><a><animate attributeName=\"href\" to=\"javascript:x\"/></a></svg>",
        .wanted = "<svg><a><animate to=\"javascript:x\"/></a></svg>",
    },
    .{
        .input = "<svg><animate attributeName=\"onclick\" to=\"x\"/></svg>",
        .wanted = "<svg><animate to=\"x\"/></svg>",
    },
    .{
        .input = "<svg><animate attributeName=\"opacity\" to=\"0\"/></svg>",
        .wanted = "<svg><animate attributename=\"opacity\" to=\"0\"/></svg>",
    },
    .{ .input = "<svg><use href=\"https://evil/x.svg#a\"/></svg>", .wanted = "<svg><use/></svg>" },
    .{
        .input = "<svg><linearGradient id=\"g\"/><rect fill=\"url(#g)\"/><use href=\"#g\"/></svg>",
        .wanted = "<svg><lineargradient id=\"svg-g\"/><rect fill=\"url(#svg-g)\"/>" ++
            "<use href=\"#svg-g\"/></svg>",
    },
    .{ .input = "<svg><rect fill=\"url(https://evil/p)\"/></svg>", .wanted = "<svg><rect/></svg>" },
    .{
        .input = "<svg><style>*{}</style><rect style=\"x\"/></svg>",
        .wanted = "<svg><rect/></svg>",
    },
    .{
        .input = "<svg><foreignObject><img src=x onerror=y></foreignObject></svg>",
        .wanted = "<svg></svg>",
    },
    .{ .input = "<svg><p>hi</p><script>x</script></svg>", .wanted = "<svg>hi</svg>" },
    .{ .input = "<svg><rect/></svg>x", .profile = .inline_text, .wanted = "x" },
    .{
        .input = "<svg><image href=\"data:image/svg+xml,x\"/>" ++
            "<image href=\"data:image/png;b\"/></svg>",
        .wanted = "<svg><image/><image href=\"data:image/png;b\"/></svg>",
    },
    .{
        .input = "<svg><a href=\"javascript:x\"><text>t</text></a></svg>",
        .wanted = "<svg><a><text>t</text></a></svg>",
    },
};

const kept = [_]Case{
    .{ .input = "<b>bold</b> & <i>it</i>", .wanted = "<b>bold</b> &amp; <i>it</i>" },
    .{
        .input = "<a href='https://example.com/?a=1&amp;b=2'>x</a>",
        .wanted = "<a href=\"https://example.com/?a=1&amp;b=2\" rel=\"nofollow noopener\">x</a>",
    },
    .{ .input = "<h2>Title</h2>", .profile = .inline_text, .wanted = "Title" },
    .{ .input = "<h2>Title</h2>", .wanted = "<h2>Title</h2>" },
    .{ .input = "<b>open", .wanted = "<b>open</b>" },
    .{ .input = "</b>stray", .wanted = "stray" },
    .{ .input = "a < b > c", .wanted = "a &lt; b &gt; c" },
    .{ .input = "<b><i>x</b>y", .wanted = "<b><i>x</i></b>y" },
    .{ .input = "<unknown>kept text</unknown>", .wanted = "kept text" },
    .{ .input = "&copy; &#169; &bogus", .wanted = "&copy; &#169; &amp;bogus" },
    .{ .input = "<br/><hr>", .wanted = "<br><hr>" },
};

fn expect_cases(cases: []const Case) !void {
    std.debug.assert(cases.len > 0);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    for (cases) |case| {
        const out = try sanitize(arena_state.allocator(), case.input, case.profile);

        std.testing.expectEqualStrings(case.wanted, out) catch |err| {
            std.debug.print("input: {s}\n", .{case.input});
            return err;
        };
    }
}

test "sanitize: scripts, handlers and dangerous addresses never survive" {
    try expect_cases(&hostile);
}

test "sanitize: inline SVG drawn, never running, loading or styling the page" {
    try expect_cases(&drawings);
}

test "sanitize: allowed markup kept and normalised, the rest as text" {
    try expect_cases(&kept);
}

/// Pieces a hostile input is made of, mixed at random.
const pieces = [_][]const u8{
    "<",           ">",        "/",         "\"",    "'",
    "=",           " ",        "\t",        "&",     "#x6a;",
    "&#106;",      "script",   "SCRIPT",    "img",   "a",
    "svg",         "style",    "iframe",    "b",     "p",
    "onerror",     "onload",   "OnClick",   "href",  "src",
    "javascript:", "jav",      "ascript:",  "data:", "alert(1)",
    "<!--",        "-->",      "<!",        "?>",    "\x00",
    "</",          "<script>", "</script>", "x",     "https://ok/",
};

test "sanitize: random mixes of hostile pieces never yield a script, handler or bad address" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var prng = std.Random.DefaultPrng.init(0x5a417e);
    const random = prng.random();
    var input: [512]u8 = undefined;

    for (0..20_000) |_| {
        var length: u32 = 0;
        const count = random.intRangeAtMost(u32, 1, 24);

        for (0..count) |_| {
            const piece = pieces[random.uintLessThan(u32, pieces.len)];

            if (length + piece.len > input.len) {
                break;
            }

            @memcpy(input[length..][0..piece.len], piece);
            length += @intCast(piece.len);
        }

        const out = try sanitize(arena_state.allocator(), input[0..length], .content);

        try expect_safe(out, input[0..length]);
        _ = arena_state.reset(.retain_capacity);
    }
}

/// Every tag written is a kept one, with no `on…` attribute and no address that runs.
/// Text outside tags cannot open one: the sanitizer writes every other `<` as `&lt;`.
fn expect_safe(out: []const u8, input: []const u8) !void {
    std.debug.assert(out.len <= 1 << 16);

    var lowered: [4096]u8 = undefined;

    if (out.len > lowered.len) {
        return error.TestUnexpectedResult;
    }

    const text = std.ascii.lowerString(&lowered, out);
    var at: u32 = 0;

    while (std.mem.indexOfScalarPos(u8, text, at, '<')) |start| {
        const end = std.mem.indexOfScalarPos(u8, text, start, '>') orelse text.len;
        const tag = text[start..end];

        at = @intCast(end);

        if (unsafe_tag(tag)) {
            std.debug.print("input: {s}\noutput: {s}\n", .{ input, out });
            return error.TestUnexpectedResult;
        }
    }
}

fn unsafe_tag(tag: []const u8) bool {
    std.debug.assert(tag.len > 0 and tag[0] == '<');

    const banned = [_][]const u8{
        "<script",
        "<style",
        "<iframe",
        "<foreignobject",
        " on",
        "\"javascript:",
        "\"jav&",
        "<!--",
        "href=\"data:image/svg",
        "href=\"http",
        "attributename=\"h",
    };

    for (banned) |word| {
        if (std.mem.indexOf(u8, tag, word) != null) {
            return true;
        }
    }

    return false;
}
