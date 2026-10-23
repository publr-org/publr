//! GROQ as Publr reads it: `publr_groq`, the language; what a query reads comes from the
//! dataset `operations/record/query_dataset.zig` gives it.

const std = @import("std");
const groq = @import("publr_groq");

pub const execute = groq.execute;
pub const run = groq.run;
pub const Options = groq.Options;
pub const Error = groq.Error;
pub const Problem = groq.Problem;
pub const Value = groq.Value;
pub const Dataset = groq.Dataset;
pub const DatasetError = groq.DatasetError;
pub const Hint = groq.Hint;
pub const Keep = groq.Keep;
pub const Found = groq.Found;
pub const values = groq.values;
pub const evaluation = groq.evaluation;
pub const datetimes = groq.datetimes;

/// Why a prepared query is refused, read before any parameter has a value: its syntax and
/// the rules GROQ checks before a query runs (functions known, `asc` inside `order()`);
/// null when it reads. Which fields a type has, GROQ cannot tell from the text.
pub fn problem_of(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?[]const u8 {
    std.debug.assert(text.len > 0);

    var problem: Problem = .{};
    const query = groq.parse(arena, text, &problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return try std.fmt.allocPrint(arena, "{s} (at {d})", .{
            problem.message,
            problem.at,
        }),
    };
    var params: groq.values.ObjectBuilder = .{};

    for (query.nodes) |node| {
        if (node == .param) {
            try params.put(arena, node.param, .null);
        }
    }

    groq.validate(arena, &query, params.object(), &problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return problem.message,
    };

    return null;
}

test "a prepared query's problem, read without its parameters" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fine = "*[_type == $type][$from...$to]{ title }";

    try std.testing.expect(try problem_of(arena, fine) == null);
    try std.testing.expect(try problem_of(arena, "*[_type == ") != null);
    try std.testing.expect(try problem_of(arena, "count(1, 2)") != null);
    try std.testing.expect(try problem_of(arena, "nope(1)") != null);
}

/// A query parsed once and kept for the life of the process: `publr.query.prepare`'s, bound
/// to each call's parameters by `run`.
pub const Prepared = struct {
    text: []const u8,
    query: groq.tree.Query,
    kept: std.heap.ArenaAllocator,

    /// The query parsed into memory of its own; null when it does not parse, so the call
    /// that runs it reports why.
    pub fn parse(text: []const u8) ?*Prepared {
        std.debug.assert(text.len > 0);

        var kept = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        var problem: Problem = .{};
        const query = groq.parse(kept.allocator(), text, &problem) catch {
            kept.deinit();
            return null;
        };
        const prepared = kept.allocator().create(Prepared) catch {
            kept.deinit();
            return null;
        };

        prepared.* = .{
            .text = text,
            .query = query,
            .kept = kept,
        };

        return prepared;
    }

    pub fn free(prepared: *Prepared) void {
        std.debug.assert(prepared.text.len > 0);

        var kept = prepared.kept;

        kept.deinit();
    }
};
