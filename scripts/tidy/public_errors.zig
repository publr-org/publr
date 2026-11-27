//! A public file's `pub fn`s answer the public error set (`publr.Error`): never core's,
//! which carries the database's own names. A file under `src/publr/` that names core's set
//! (`sdk.Error`, `db.Error`, an alias of `sdk/operation.zig`'s `Error`, or `.Error` of a
//! module that is `sdk/operation.zig` or `sdk.zig`) in a `pub fn`'s signature is refused;
//! a private helper may, when the `pub fn` calling it maps its error (`public_of`).

const std = @import("std");

const names_max: u32 = 16;
const name_len_max: u32 = 64;

/// The names a file gives core's error set (`Error`), and the modules whose `.Error` is
/// core's (`operation`).
const Names = struct {
    items: [names_max][]const u8 = undefined,
    modules: [names_max]bool = undefined,
    len: u32 = 0,

    fn add(names: *Names, name: []const u8, module: bool) void {
        std.debug.assert(name.len > 0);

        if (names.len < names_max and name.len <= name_len_max) {
            names.items[names.len] = name;
            names.modules[names.len] = module;
            names.len += 1;
        }
    }

    fn named(names: *const Names, line: []const u8) bool {
        std.debug.assert(names.len <= names_max);

        for (names.items[0..names.len], names.modules[0..names.len]) |name, module| {
            if (names_before(line, name, if (module) ".Error!" else "!")) {
                return true;
            }
        }

        return false;
    }
};

const core_sources = [_][]const u8{
    "sdk/operation.zig\")",
    "/sdk.zig\")",
    "lib/db.zig\")",
};

pub fn check(text: []const u8, path: []const u8, hint: []const u8, report: bool) u32 {
    std.debug.assert(path.len > 0);
    std.debug.assert(core_sources.len > 0);

    if (!is_public(path) or text.len == 0) {
        return 0;
    }

    const names = names_of(text);
    var violations: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: u32 = 1;
    var in_signature = false;

    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " ");

        if (std.mem.startsWith(u8, trimmed, "pub fn ")) {
            in_signature = true;
        }

        if (in_signature and names.named(line)) {
            violations += 1;

            if (report) {
                std.debug.print("{s}:{d}: a public function answers core's error set; " ++
                    "answer `publr.Error`, mapping with `public_of`{s}\n", .{
                    path,
                    line_no,
                    hint,
                });
            }
        }

        if (in_signature and std.mem.endsWith(u8, std.mem.trimEnd(u8, line, " "), "{")) {
            in_signature = false;
        }
    }

    return violations;
}

fn is_public(path: []const u8) bool {
    std.debug.assert(path.len > 0);

    const at = std.mem.indexOf(u8, path, "publr/") orelse return false;

    return at == 0 or path[at - 1] == '/';
}

/// `sdk.Error` and `db.Error` always; `module.Error` for each module imported from core's
/// sources; `name` for each `const name = ...Error;` taken from them.
fn names_of(text: []const u8) Names {
    std.debug.assert(text.len > 0);

    var names: Names = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');

    names.add("sdk", true);
    names.add("db", true);

    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " ");

        if (!std.mem.startsWith(u8, trimmed, "const ")) {
            continue;
        }

        const declared = trimmed["const ".len..];
        const name_end = std.mem.indexOf(u8, declared, " = ") orelse continue;
        const name = declared[0..name_end];
        const value = declared[name_end + " = ".len ..];
        const aliased = std.mem.eql(u8, value, "sdk.Error;");

        if (!from_core(value) and !aliased) {
            continue;
        }

        if (std.mem.endsWith(u8, value, ".Error;")) {
            names.add(name, false);
        } else if (std.mem.endsWith(u8, value, "\");")) {
            names.add(name, true);
        }
    }

    return names;
}

fn from_core(value: []const u8) bool {
    std.debug.assert(core_sources.len > 0);

    for (core_sources) |source| {
        if (std.mem.indexOf(u8, value, source) != null) {
            return true;
        }
    }

    return false;
}

/// Whether `line` names `name` as an error set: the whole word, then `after` (`!`, or
/// `.Error!` for a module).
fn names_before(line: []const u8, name: []const u8, after: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(after.len > 0);

    var start: u32 = 0;

    while (std.mem.indexOfPos(u8, line, start, name)) |at| {
        const end = at + name.len;
        const whole = at == 0 or !is_word(line[at - 1]);

        if (whole and std.mem.startsWith(u8, line[end..], after)) {
            return true;
        }

        start = @intCast(end);
    }

    return false;
}

fn is_word(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_' or char == '.';
}

test "public errors: a public file's pub fn may not answer core's set" {
    const aliased = "const Error = @import(\"../sdk/operation.zig\").Error;\n" ++
        "pub fn run(ctx: *Ctx) Error!void {\n}\n";
    const module = "const operation = @import(\"../sdk/operation.zig\");\n" ++
        "pub fn describe(\n    ctx: *Ctx,\n) operation.Error!void {\n}\n";
    const private = "const CoreError = @import(\"../sdk/operation.zig\").Error;\n" ++
        "fn kept(ctx: *Ctx) CoreError!void {\n}\n";
    const public = "const Error = @import(\"operation.zig\").Error;\n" ++
        "pub fn run(ctx: *Ctx) Error!void {\n}\n";

    try std.testing.expectEqual(@as(u32, 1), check(aliased, "publr/x.zig", "", false));
    try std.testing.expectEqual(@as(u32, 1), check(module, "publr/x.zig", "", false));
    try std.testing.expectEqual(@as(u32, 0), check(private, "publr/x.zig", "", false));
    try std.testing.expectEqual(@as(u32, 0), check(public, "publr/x.zig", "", false));
    try std.testing.expectEqual(@as(u32, 0), check(aliased, "sdk/x.zig", "", false));
}
