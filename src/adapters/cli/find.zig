//! `publr find <what you want to do>`: the five commands and guide entries that fit a task
//! best, for an agent to start from instead of reading every `--help`. Read here, from the
//! operations themselves (installed plugins' included), the words they declare for it
//! (`find_words`, a plugin's `Find:` line) and the guide `publr agents` prints. No model and
//! no outside call: plain matching of words, ranked by where they matched.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("../../sdk.zig");
const hint = @import("../../publr/hint.zig");

pub const Error = error{ WriteFailed, OutOfMemory };

/// How many matches it answers.
pub const matches_max: u32 = 5;
/// The longest guide entry it answers, cut at a line's end past it.
pub const entry_len_max: u32 = 900;
/// The words of a query it reads.
pub const query_words_max: u32 = 32;

/// The guide `publr agents` prints; the browser build carries none.
pub const guide = if (builtin.os.tag == .wasi) "" else @embedFile("agents_guide");

pub const usage =
    \\Usage: publr find <what you want to do>
    \\
    \\The five commands and guide entries that fit the task best, as JSON, best first:
    \\core's, the installed plugins' and the guide's (`publr agents`). Describe the action
    \\and what it is on, in plain words: `publr find "group posts into categories"`. Then run
    \\`publr <namespace> <verb> --help` on the command it found.
    \\
;

/// One thing a query can find.
pub const Document = struct {
    /// `taxonomy create`; empty for a guide entry.
    command: []const u8 = "",
    /// A guide entry's title: `Taxonomies`; empty for a command.
    guide: []const u8 = "",
    summary: []const u8 = "",
    details: []const u8 = "",
    words: []const u8 = "",
};

pub const Match = struct {
    document: Document,
    score: f32,
};

/// Every command and guide entry, the installed plugins' operations included.
pub fn documents(
    comptime SDK: type,
    arena: std.mem.Allocator,
    sandboxed: ?*const sdk.sandboxed_plugins.SandboxedPlugins,
    text: []const u8,
) Error![]const Document {
    @setEvalBranchQuota(SDK.operations.len * 4096);

    var list: std.ArrayList(Document) = .empty;

    inline for (SDK.operations) |Operation| {
        const operator = @hasDecl(Operation, "operator_only") and Operation.operator_only;
        const plugins = @hasDecl(Operation, "plugins_only") and Operation.plugins_only;

        if (!operator and !plugins) {
            try list.append(arena, .{
                .command = comptime sdk.operation.namespace(Operation.name) ++ " " ++
                    sdk.operation.verb(Operation.name),
                .summary = Operation.description,
                .details = if (@hasDecl(Operation, "details")) Operation.details else "",
                .words = comptime hint.find_words(Operation),
            });
        }
    }

    if (sandboxed) |installed| {
        for (installed.manifests()) |manifest| {
            for (manifest.operations) |operation| {
                const dot = std.mem.lastIndexOfScalar(u8, operation.name, '.') orelse continue;

                try list.append(arena, .{
                    .command = try std.fmt.allocPrint(arena, "{s} {s}", .{
                        operation.name[0..dot],
                        operation.name[dot + 1 ..],
                    }),
                    .summary = operation.description,
                    .details = operation.details,
                    .words = operation.find_words,
                });
            }
        }
    }

    try guide_entries(arena, text, &list);

    return list.items;
}

/// The guide's entries: each `- **Title.**` item with the lines indented under it, and each
/// heading with the first paragraph after it. Code blocks never start one.
pub fn guide_entries(
    arena: std.mem.Allocator,
    text: []const u8,
    list: *std.ArrayList(Document),
) Error!void {
    const Reading = enum { none, item, heading, paragraph };

    var lines = std.mem.splitScalar(u8, text, '\n');
    var reading: Reading = .none;
    var title: []const u8 = "";
    var start: usize = 0;
    var fenced = false;

    while (lines.next()) |line| {
        const begins = @intFromPtr(line.ptr) - @intFromPtr(text.ptr);
        const fence = std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```");
        const inside = fenced;

        if (fence) fenced = !fenced;

        const indented = line.len > 0 and line[0] == ' ';
        const blank = std.mem.trim(u8, line, " ").len == 0;

        // What is being read ends here.
        switch (reading) {
            .item => if (!inside and !fence and !indented) {
                try add_entry(arena, list, title, text[start..begins]);
                reading = .none;
            },
            .paragraph => if (!inside and !fence and blank) {
                try add_entry(arena, list, title, text[start..begins]);
                reading = .none;
            },
            .heading => if (!blank) {
                start = begins;
                reading = .paragraph;
            },
            .none => {},
        }

        if (inside or fence or reading != .none) continue;

        if (std.mem.startsWith(u8, line, "- **")) {
            const close = std.mem.indexOfPos(u8, line, 4, "**") orelse continue;

            title = std.mem.trimEnd(u8, line[4..close], ".:");
            start = begins;
            reading = .item;
        } else if (std.mem.startsWith(u8, line, "#")) {
            title = std.mem.trim(u8, std.mem.trimStart(u8, line, "#"), " ");
            reading = .heading;
        }
    }

    if (reading == .item or reading == .paragraph) {
        try add_entry(arena, list, title, text[start..]);
    }
}

fn add_entry(
    arena: std.mem.Allocator,
    list: *std.ArrayList(Document),
    title: []const u8,
    body: []const u8,
) Error!void {
    const trimmed = std.mem.trim(u8, body, " \n");

    if (title.len == 0 or trimmed.len == 0) {
        return;
    }

    var cut = trimmed;

    if (cut.len > entry_len_max) {
        const end = std.mem.indexOfScalarPos(u8, cut, entry_len_max, '\n') orelse cut.len;

        cut = cut[0..end];
    }

    try list.append(arena, .{
        .guide = title,
        .details = cut,
    });
}

/// The best matches for a query, best first, at most `matches_max`.
pub fn rank(
    arena: std.mem.Allocator,
    all: []const Document,
    query: []const u8,
) Error![]const Match {
    var words: std.ArrayList([]const u8) = .empty;
    var each = Words.init(query);

    while (each.next()) |word| {
        if (words.items.len == query_words_max) break;
        if (stop_word(word)) continue;

        try words.append(arena, try arena.dupe(u8, stem(word)));
    }

    var found: std.ArrayList(Match) = .empty;

    if (words.items.len == 0) {
        return found.items;
    }

    for (all) |document| {
        var score: f32 = 0;

        for (words.items) |word| {
            score += best(document, word);
        }

        if (score > 0) {
            try found.append(arena, .{
                .document = document,
                .score = score,
            });
        }
    }

    std.mem.sort(Match, found.items, {}, better);

    return found.items[0..@min(found.items.len, matches_max)];
}

fn better(_: void, left: Match, right: Match) bool {
    std.debug.assert(left.score > 0 and right.score > 0);

    if (left.score != right.score) {
        return left.score > right.score;
    }

    // A command before a guide entry: it can be run.
    return left.document.command.len > right.document.command.len;
}

/// How well one query word matches one document: its best field's weight, a whole word
/// counting more than the start of one.
fn best(document: Document, word: []const u8) f32 {
    std.debug.assert(word.len > 0);

    const fields = [_]struct {
        text: []const u8,
        weight: f32,
    }{
        .{
            .text = document.command,
            .weight = 8,
        },
        .{
            .text = document.guide,
            .weight = 6,
        },
        .{
            .text = document.words,
            .weight = 6,
        },
        .{
            .text = document.summary,
            .weight = 5,
        },
        .{
            .text = document.details,
            .weight = 1,
        },
    };
    var top: f32 = 0;

    for (fields) |field| {
        const how = matches(field.text, word);

        top = @max(top, how * field.weight);
    }

    return top;
}

/// 1 when the text holds the word, 0.6 when a word of it starts with the word, else 0.
fn matches(text: []const u8, word: []const u8) f32 {
    std.debug.assert(word.len > 0);

    var each = Words.init(text);
    var how: f32 = 0;

    while (each.next()) |raw| {
        const its = stem(raw);

        if (std.mem.eql(u8, its, word)) {
            return 1;
        }

        if (word.len >= 3 and std.mem.startsWith(u8, its, word)) {
            how = 0.6;
        }
    }

    return how;
}

/// Words in lower case: letters and digits, split on everything else (`content_type` is two).
const Words = struct {
    text: []const u8,
    at: usize = 0,
    buffer: [48]u8 = undefined,

    fn init(text: []const u8) Words {
        return .{
            .text = text,
        };
    }

    fn next(words: *Words) ?[]u8 {
        std.debug.assert(words.at <= words.text.len);

        while (words.at < words.text.len and !std.ascii.isAlphanumeric(words.text[words.at])) {
            words.at += 1;
        }

        if (words.at == words.text.len) {
            return null;
        }

        var len: usize = 0;

        while (words.at < words.text.len and std.ascii.isAlphanumeric(words.text[words.at])) {
            if (len < words.buffer.len) {
                words.buffer[len] = std.ascii.toLower(words.text[words.at]);
                len += 1;
            }

            words.at += 1;
        }

        return words.buffer[0..len];
    }
};

/// A word with its plural ending taken off, in place: `categories` and `category` are one.
fn stem(word: []u8) []u8 {
    std.debug.assert(word.len <= 48);

    if (word.len > 4 and std.mem.endsWith(u8, word, "ies")) {
        word[word.len - 3] = 'y';

        return word[0 .. word.len - 2];
    }

    if (word.len > 3 and std.mem.endsWith(u8, word, "s") and !std.mem.endsWith(u8, word, "ss")) {
        return word[0 .. word.len - 1];
    }

    return word;
}

const stop_words = [_][]const u8{
    "a",    "an",   "the",  "to",   "of",    "for",  "in",   "on",    "and",   "or",
    "is",   "it",   "my",   "i",    "me",    "we",   "our",  "you",   "your",  "with",
    "how",  "do",   "can",  "want", "need",  "into", "from", "by",    "at",    "be",
    "that", "this", "some", "make", "using", "use",  "what", "which", "there", "as",
};

fn stop_word(word: []const u8) bool {
    std.debug.assert(stop_words.len > 0);

    for (stop_words) |stop| {
        if (std.mem.eql(u8, stop, word)) {
            return true;
        }
    }

    return false;
}

/// The matches as JSON, one per line: a command with its summary and how to read its help,
/// a guide entry with its text.
pub fn print(found: []const Match, out: *std.Io.Writer) Error!void {
    std.debug.assert(found.len <= matches_max);

    out.writeAll("[") catch return error.WriteFailed;

    for (found, 0..) |match, index| {
        out.writeAll(if (index == 0) "\n  " else ",\n  ") catch return error.WriteFailed;

        const document = match.document;

        if (document.command.len > 0) {
            std.json.Stringify.value(.{
                .command = document.command,
                .summary = document.summary,
            }, .{}, out) catch return error.WriteFailed;
        } else {
            std.json.Stringify.value(.{
                .guide = document.guide,
                .text = document.details,
            }, .{}, out) catch return error.WriteFailed;
        }
    }

    out.writeAll(if (found.len == 0) "]\n" else "\n]\n") catch return error.WriteFailed;
}
