const std = @import("std");
const control_flow = @import("tidy/control_flow.zig");
const functions = @import("tidy/functions.zig");
const kinds = @import("tidy/kinds.zig");
const prose = @import("tidy/prose.zig");
const lines_module = @import("tidy/lines.zig");
const literals = @import("tidy/literals.zig");
const options = @import("tidy/options.zig");

const limits = @import("tidy/limits.zig");

const file_bytes_max = limits.file_bytes_max;
const files_max = limits.files_max;

pub fn main(init: std.process.Init) !u8 {
    var iterator = try init.minimal.args.iterateAllocator(init.arena.allocator());
    var violations: u32 = 0;
    var singles: u32 = 0;
    var files_seen: u32 = 0;
    const hint = init.environ_map.get(hint_variable) orelse "";

    _ = iterator.next();

    var first = iterator.next();
    const rules = rules_of(first);

    if (rules == .options) {
        first = iterator.next();
    }

    while (if (first) |root| root else iterator.next()) |root| : (first = null) {
        const cwd = std.Io.Dir.cwd();
        const stat = try cwd.statFile(init.io, root, .{});

        std.debug.assert(root.len > 0);
        std.debug.assert(files_seen <= files_max);

        if (stat.kind == .file) {
            files_seen += 1;
            if (std.mem.endsWith(u8, root, ".md")) {
                if (rules == .all) {
                    violations += try prose.check_prose(init, cwd, root, root, hint);
                }
            } else {
                violations += try check_file(init, cwd, root, root, hint, &singles, rules);
            }
            continue;
        }

        var dir = try cwd.openDir(init.io, root, .{
            .iterate = true,
        });
        defer dir.close(init.io);

        var walker = try dir.walk(init.gpa);
        defer walker.deinit();

        while (try walker.next(init.io)) |entry| {
            const cached = std.mem.indexOf(u8, entry.path, ".zig-cache") != null;

            if (entry.kind != .file or cached) {
                continue;
            }
            if (files_seen == files_max) {
                return error.TooManyFiles;
            }

            if (std.mem.endsWith(u8, entry.basename, ".zig")) {
                files_seen += 1;
                const folder = entry.dir;
                const name = entry.basename;
                violations += try check_file(init, folder, name, entry.path, hint, &singles, rules);
            } else if (rules == .all and std.mem.endsWith(u8, entry.basename, ".md")) {
                files_seen += 1;
                const path = entry.path;
                violations += try prose.check_prose(init, entry.dir, entry.basename, path, hint);
            }
        }
    }

    std.debug.assert(files_seen > 0);

    if (singles > 0) {
        std.debug.print("tidy: {d} function(s) with a single assertion (the aim is two)\n", .{
            singles,
        });
    }

    if (violations != 0) {
        std.debug.print("tidy: {d} violation(s)\n", .{violations});
        return 1;
    }

    return 0;
}

fn check_file(
    init: std.process.Init,
    dir: std.Io.Dir,
    basename: []const u8,
    path: []const u8,
    hint: []const u8,
    singles: *u32,
    rules: Rules,
) !u32 {
    const text = try dir.readFileAlloc(init.io, basename, init.gpa, .limited(file_bytes_max));
    defer init.gpa.free(text);

    if (rules == .options) {
        return check_options(init.gpa, text, path, hint);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: u32 = 1;
    var violations: u32 = 0;

    var previous: []const u8 = "";

    while (lines.next()) |line| : (line_no += 1) {
        defer previous = line;

        for (lines_module.rules) |rule| {
            if (!rule.check(line)) {
                continue;
            }
            const commented_global = rule.check == &lines_module.top_level_var and
                std.mem.startsWith(u8, previous, "// ");

            if (commented_global) {
                continue;
            }

            violations += 1;
            std.debug.print("{s}:{d}: {s}{s}\n", .{ path, line_no, rule.message, hint });
        }
    }

    violations += functions.check_assertion_density(text, path, hint, true, singles);
    violations += kinds.check(text, path, hint, true);
    violations += try control_flow.check(init.gpa, text, path, hint, true);
    violations += try check_literals(init.gpa, text, path, hint);
    violations += try check_options(init.gpa, text, path, hint);

    return violations;
}

fn check_literals(
    gpa: std.mem.Allocator,
    text: []const u8,
    path: []const u8,
    hint: []const u8,
) !u32 {
    std.debug.assert(path.len > 0);

    const source = try gpa.dupeZ(u8, text);
    defer gpa.free(source);

    const missing = try literals.find(gpa, source);
    defer gpa.free(missing);

    for (missing) |place| {
        std.debug.print("{s}:{d}: {s}{s}\n", .{ path, place.line, literals.message, hint });
    }

    return @intCast(missing.len);
}

fn check_options(
    gpa: std.mem.Allocator,
    text: []const u8,
    path: []const u8,
    hint: []const u8,
) !u32 {
    std.debug.assert(path.len > 0);

    const source = try gpa.dupeZ(u8, text);
    defer gpa.free(source);

    const found = try options.find(gpa, source);
    defer gpa.free(found);

    for (found) |place| {
        const message = options.messages.get(place.problem);
        std.debug.print("{s}:{d}: {s}{s}\n", .{ path, place.line, message, hint });
    }

    return @intCast(found.len);
}

const hint_variable = "PUBLR_TIDY_HINT";

/// The other repos in the workspace hold only the options rule so far: the first argument
/// `--only=options` runs that rule alone.
const only_options = "--only=options";

const Rules = enum {
    all,
    options,
};

fn rules_of(first: ?[]const u8) Rules {
    const argument = first orelse return .all;

    std.debug.assert(only_options.len > 0);

    return if (std.mem.eql(u8, argument, only_options)) .options else .all;
}

test {
    std.testing.refAllDecls(@This());
    _ = control_flow;
    _ = functions;
    _ = prose;
    _ = lines_module;
    _ = literals;
    _ = options;
}
