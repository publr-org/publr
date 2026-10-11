//! `publr --commands`: every command at once, one line each with its exact flags, for an
//! agent to read once instead of finding its way with `--help`. Built from the operations
//! themselves, the installed plugins' included, so it never says what the binary does not.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const help = @import("../../sdk/help.zig");

const Error = error{WriteFailed};

pub const header =
    \\Every command, as `publr <namespace> <verb> --flag <value>`; a flag in brackets may be
    \\left out. Values that are lists or objects are JSON. `publr <namespace> <verb> --help`
    \\explains one fully, with an example.
    \\
    \\
;

pub fn print(
    comptime SDK: type,
    sandboxed: ?*const sdk.sandboxed_plugins.SandboxedPlugins,
    out: *std.Io.Writer,
) Error!void {
    @setEvalBranchQuota(SDK.operations.len * 4096);

    comptime std.debug.assert(SDK.operations.len > 0);

    out.writeAll(header) catch return error.WriteFailed;

    inline for (SDK.operations) |Operation| {
        const operator = @hasDecl(Operation, "operator_only") and Operation.operator_only;
        const plugins = @hasDecl(Operation, "plugins_only") and Operation.plugins_only;

        if (!operator and !plugins) {
            try line(Operation, out);
        }
    }

    const installed = sandboxed orelse return;

    for (installed.manifests()) |manifest| {
        for (manifest.operations) |operation| {
            try installed_line(operation, out);
        }
    }
}

fn line(comptime Operation: type, out: *std.Io.Writer) Error!void {
    comptime std.debug.assert(Operation.name.len > 0);

    const namespace = comptime sdk.operation.namespace(Operation.name);
    const verb = comptime sdk.operation.verb(Operation.name);

    out.print("{s} {s}", .{ namespace, verb }) catch return error.WriteFailed;

    inline for (std.meta.fields(Operation.In)) |field| {
        const label = comptime help.type_label(field.type);

        if (field.default_value_ptr == null) {
            out.print(" --{s} <{s}>", .{ field.name, label }) catch return error.WriteFailed;
        } else {
            out.print(" [--{s} <{s}>]", .{ field.name, label }) catch return error.WriteFailed;
        }
    }

    out.print("  # {s}\n", .{Operation.description}) catch return error.WriteFailed;
}

fn installed_line(operation: anytype, out: *std.Io.Writer) Error!void {
    std.debug.assert(operation.name.len > 0);

    const dot = std.mem.lastIndexOfScalar(u8, operation.name, '.') orelse return;

    out.print("{s} {s}", .{ operation.name[0..dot], operation.name[dot + 1 ..] }) catch {
        return error.WriteFailed;
    };

    for (operation.fields) |field| {
        const label = if (field.label.len > 0) field.label else @tagName(field.shape);

        if (field.required) {
            out.print(" --{s} <{s}>", .{ field.name, label }) catch return error.WriteFailed;
        } else {
            out.print(" [--{s} <{s}>]", .{ field.name, label }) catch return error.WriteFailed;
        }
    }

    out.print("  # {s}\n", .{operation.description}) catch return error.WriteFailed;
}
