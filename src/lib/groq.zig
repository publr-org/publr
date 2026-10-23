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
