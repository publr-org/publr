//! Every part of the plugin contract, and whether the two-mode check sees it run both ways.
//! A part added to the manifest fails the build here until it is placed: exercised by a
//! fixture and a step, or named as the sandbox's own with why.
const std = @import("std");
const publr = @import("publr");

const Manifest = publr.model.sandboxed_plugin.Manifest;
const Operation = publr.model.sandboxed_plugin.Operation;
const Hook = publr.model.sandboxed_plugin.Hook;
const Field = publr.model.sandboxed_plugin.Field;

const Part = struct { name: []const u8, where: []const u8 };

/// Exercised by the fixtures and compared.
const exercised = [_]Part{
    .{ .name = "name", .where = "every plugin" },
    .{ .name = "version", .where = "every plugin" },
    .{ .name = "summary", .where = "every plugin" },
    .{ .name = "namespaces", .where = "`--help`" },
    .{ .name = "operations", .where = "every plugin" },
    .{ .name = "hooks", .where = "greeter's after, sampler's before, after and event" },
    .{ .name = "permissions", .where = "greeter people" },
    .{ .name = "content_types", .where = "salutation, sample_note, sample_log" },
    .{ .name = "custom_fields", .where = "sampler_profile" },
    .{ .name = "roles", .where = "greeter's grants to editor" },
    .{ .name = "kind", .where = "reads and writes" },
    .{ .name = "description", .where = "`--help`" },
    .{ .name = "details", .where = "`--help`" },
    .{ .name = "open", .where = "sampler hello" },
    .{ .name = "fields", .where = "sampler echo" },
    .{ .name = "stage", .where = "sampler's hooks" },
    .{ .name = "target", .where = "sampler's hooks" },
    .{ .name = "reason", .where = "every hook" },
    .{ .name = "shape", .where = "sampler echo" },
    .{ .name = "required", .where = "greeter greet's note, sampler echo's optional ones" },
    .{ .name = "doc", .where = "greeter greet --help" },
    .{ .name = "help", .where = "greeter greet --help, sampler note --help" },
    .{ .name = "label", .where = "sampler echo's refusals" },
    .{ .name = "values", .where = "sampler echo --mood angry" },
    .{ .name = "internal_records", .where = "greeter's visits, sampler's tallies" },
    .{ .name = "indexed", .where = "greeter's visits by name" },
    .{ .name = "append_only", .where = "sampler's tallies" },
    .{ .name = "input", .where = "every operation's contract, and greeter's remote" },
    .{ .name = "output", .where = "every operation's contract, and greeter's remote" },
    .{ .name = "parent", .where = "every contract node" },
    .{ .name = "optional", .where = "sampler echo's contract" },
    .{ .name = "remotes", .where = "greeter's use of sampler hello" },
    .{ .name = "operation", .where = "greeter's use of sampler hello" },
    .{ .name = "compatible_with", .where = "greeter, with sampler" },
    .{ .name = "to", .where = "greeter recall's post" },
    .{ .name = "secret", .where = "greeter greet's note, kept out of the logs" },
};

/// What only the sandbox has: a compiled-in plugin runs with everything, unlimited.
const sandbox_only = [_]Part{
    .{ .name = "format", .where = "the module's own format number" },
    .{ .name = "allowed_domains", .where = "what the sandbox lets it reach" },
    .{ .name = "depends_on", .where = "checked when an installed plugin starts" },
    .{ .name = "limits", .where = "the sandbox's CPU, memory and call limits" },
    .{ .name = "content_access", .where = "what the sandbox lets it read" },
    .{ .name = "left_out", .where = "what its sandboxed build could not carry" },
};

const stages_exercised = [_]Hook.Stage{ .before, .after, .event };
const shapes_exercised = [_]Field.Shape{ .string, .integer, .number, .boolean, .strings, .json };

pub fn check() void {
    comptime {
        @setEvalBranchQuota(20_000);
        std.debug.assert(exercised.len + sandbox_only.len > 0);
        placed(Manifest);
        placed(Operation);
        placed(Hook);
        placed(Field);
        every(Hook.Stage, &stages_exercised);
        every(Field.Shape, &shapes_exercised);
    }
}

fn placed(comptime Struct: type) void {
    comptime {
        std.debug.assert(@typeInfo(Struct) == .@"struct");

        for (std.meta.fields(Struct)) |field| {
            if (!listed(&exercised, field.name) and !listed(&sandbox_only, field.name)) {
                @compileError("two-mode: " ++ @typeName(Struct) ++ "." ++ field.name ++
                    " is neither exercised by a fixture nor named as the sandbox's own");
            }
        }
    }
}

fn listed(comptime parts: []const Part, comptime name: []const u8) bool {
    comptime {
        std.debug.assert(name.len > 0);

        for (parts) |part| {
            if (std.mem.eql(u8, part.name, name)) {
                return true;
            }
        }

        return false;
    }
}

fn every(comptime Enum: type, comptime seen: []const Enum) void {
    comptime {
        std.debug.assert(seen.len > 0);

        for (std.meta.tags(Enum)) |tag| {
            if (std.mem.indexOfScalar(Enum, seen, tag) == null) {
                @compileError("two-mode: " ++ @typeName(Enum) ++ "." ++ @tagName(tag) ++
                    " is not exercised by a fixture");
            }
        }
    }
}
