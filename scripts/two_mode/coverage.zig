//! Every part of the plugin contract, and whether the two-mode check sees it run both ways.
//! A part added to the manifest fails the build here until it is placed: exercised by a
//! fixture and a step, or named as the sandbox's own with why.
const std = @import("std");
const publr = @import("publr");

const Manifest = publr.model.sandboxed_plugin.Manifest;
const Operation = publr.model.sandboxed_plugin.Operation;
const Hook = publr.model.sandboxed_plugin.Hook;
const Field = publr.model.sandboxed_plugin.Field;

const Part = struct {
    name: []const u8,
    where: []const u8,
};

/// Exercised by the fixtures and compared.
const exercised = [_]Part{
    .{
        .name = "name",
        .where = "every plugin",
    },
    .{
        .name = "version",
        .where = "every plugin",
    },
    .{
        .name = "summary",
        .where = "every plugin",
    },
    .{
        .name = "namespaces",
        .where = "`--help`",
    },
    .{
        .name = "operations",
        .where = "every plugin",
    },
    .{
        .name = "hooks",
        .where = "greeter's after, sampler's before, after, event and modify",
    },
    .{
        .name = "permissions",
        .where = "greeter people",
    },
    .{
        .name = "content_types",
        .where = "greeter.salutation, sampler.sample_note, sampler.sample_log",
    },
    .{
        .name = "custom_fields",
        .where = "sampler's field group on users",
    },
    .{
        .name = "roles",
        .where = "greeter's grants to editor",
    },
    .{
        .name = "checked",
        .where = "sampler hello's and wave's `.validate` words",
    },
    .{
        .name = "who_may_call",
        .where = "sampler wave's `.authorize`, hello's untrusted callers",
    },
    .{
        .name = "deprecated",
        .where = "sampler hi",
    },
    .{
        .name = "providers",
        .where = "postcard's messaging provider",
    },
    .{
        .name = "destructive",
        .where = "prices' withdraw, destroying as an administrator",
    },
    .{
        .name = "public_api",
        .where = "greeter's operation listed in the API reference",
    },
    .{
        .name = "columns",
        .where = "sampler's columns on People and the media list",
    },
    .{
        .name = "kind",
        .where = "reads and writes",
    },
    .{
        .name = "description",
        .where = "`--help`",
    },
    .{
        .name = "details",
        .where = "`--help`",
    },
    .{
        .name = "open",
        .where = "sampler hello",
    },
    .{
        .name = "public",
        .where = "greeter hail",
    },
    .{
        .name = "columns",
        .where = "sampler's Motto and Notes on People, filled by its after hook",
    },
    .{
        .name = "field_kinds",
        .where = "sampler's place on sample visits, a refused latitude",
    },
    .{
        .name = "location_rules",
        .where = "sampler's has_motto, placing a group on an account with a motto",
    },
    .{
        .name = "jobs",
        .where = "sampler write_note (queued by later), tick (repeating)",
    },
    .{
        .name = "untrusted_callers",
        .where = "sampler wave",
    },
    .{
        .name = "answer",
        .where = "sampler wave",
    },
    .{
        .name = "limit",
        .where = "sampler wave",
    },
    .{
        .name = "fields",
        .where = "sampler echo",
    },
    .{
        .name = "stage",
        .where = "sampler's hooks",
    },
    .{
        .name = "target",
        .where = "sampler's hooks",
    },
    .{
        .name = "reason",
        .where = "every hook",
    },
    .{
        .name = "shape",
        .where = "sampler echo",
    },
    .{
        .name = "required",
        .where = "greeter greet's note, sampler echo's optional ones",
    },
    .{
        .name = "doc",
        .where = "greeter greet --help",
    },
    .{
        .name = "help",
        .where = "greeter greet --help, sampler note --help",
    },
    .{
        .name = "label",
        .where = "sampler echo's refusals",
    },
    .{
        .name = "values",
        .where = "sampler echo --mood angry",
    },
    .{
        .name = "internal_records",
        .where = "greeter's visits, sampler's tallies",
    },
    .{
        .name = "indexed",
        .where = "greeter's visits by name",
    },
    .{
        .name = "append_only",
        .where = "sampler's tallies",
    },
    .{
        .name = "shared",
        .where = "sampler's tallies, one count for every app",
    },
    .{
        .name = "input",
        .where = "every operation's contract, and greeter's remote",
    },
    .{
        .name = "output",
        .where = "every operation's contract, and greeter's remote",
    },
    .{
        .name = "parent",
        .where = "every contract node",
    },
    .{
        .name = "optional",
        .where = "sampler echo's contract",
    },
    .{
        .name = "remotes",
        .where = "greeter's use of sampler hello",
    },
    .{
        .name = "events",
        .where = "greeter's greeted event",
    },
    .{
        .name = "operation",
        .where = "greeter's use of sampler hello",
    },
    .{
        .name = "compatible_with",
        .where = "greeter, with sampler",
    },
    .{
        .name = "statuses",
        .where = "sampler's sampled status on greeter's salutations",
    },
    .{
        .name = "secrets",
        .where = "sampler's SAMPLER_KEY, listed by secret list",
    },
    .{
        .name = "to",
        .where = "greeter recall's salutation",
    },
    .{
        .name = "secret",
        .where = "greeter greet's note, kept out of the logs",
    },
    .{
        .name = "pages",
        .where = "sampler's log page, drawn by sampler page",
    },
    .{
        .name = "path",
        .where = "sampler's log page",
    },
    .{
        .name = "icon",
        .where = "sampler's log page",
    },
    .{
        .name = "menu",
        .where = "sampler's Sample notes menu item, its notes and logs under it",
    },
    .{
        .name = "icons",
        .where = "sampler's own icon on its menu item",
    },
    .{
        .name = "panels",
        .where = "sampler's panel on sample notes",
    },
    .{
        .name = "top_bar",
        .where = "sampler's top bar entry, counted by sampler count",
    },
    .{
        .name = "row_actions",
        .where = "sampler's action on the rows of a `sampler` slot",
    },
    .{
        .name = "about",
        .where = "sampler's about, on its plugin page",
    },
    .{
        .name = "webhooks",
        .where = "sampler's ping, delivered to it installed in scenarios_queued.zig",
    },
};

/// What only the sandbox has: a compiled-in plugin runs unlimited, its grants as asked.
const sandbox_only = [_]Part{
    .{
        .name = "example",
        .where = "an installed operation's `Example:` as JSON, run by its plugin build",
    },
    .{
        .name = "example_out",
        .where = "the same example's answer",
    },
    .{
        .name = "words",
        .where = "an installed form's enum values in words; compiled in they come from `///`",
    },
    .{
        .name = "default",
        .where = "an installed form's new row; compiled in it comes from the field's default",
    },
    .{
        .name = "format",
        .where = "the module's own format number",
    },
    .{
        .name = "depends_on",
        .where = "checked when an installed plugin starts",
    },
    .{
        .name = "limits",
        .where = "the sandbox's CPU, memory and call limits",
    },
    .{
        .name = "left_out",
        .where = "what its sandboxed build could not carry",
    },
};

const stages_exercised = [_]Hook.Stage{ .before, .after, .event, .modify };
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
