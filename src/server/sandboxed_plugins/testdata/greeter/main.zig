const std = @import("std");
const publr = @import("publr");

const sdk = publr.sdk;
const PluginCtx = publr.plugin.PluginCtx;
const record = publr.operations.record;

pub const manifest: publr.plugin.Manifest = .{
    .name = "greeter",
    .version = "0.1.0",
    .summary = "An installed plugin core's tests and smoke install: greetings kept as records",
};

pub const namespaces = [_]sdk.operation.Namespace{.{
    .name = "greeter",
    .summary = "Greetings, kept as records of the plugin's own type",
    .details =
    \\The plugin the sandbox is tested with: `greeter greet` records a greeting and
    \\answers how many there are, `greeter count` only counts, `greeter people` greets
    \\everyone on the site by name. That last one needs a permission, so an
    \\administrator can take it away and watch it answer denied.
    ,
}};

/// Greeter works with sampler when it is there: it says hello through it.
pub const compatible_with = .{"sampler@^0.1"};
pub const remotes = [_]type{SamplerHello};
pub const SamplerHello = publr.plugin.Remote(
    "sampler.hello",
    struct { who: []const u8 },
    struct { text: []const u8 },
);

pub const internal_records = [_]publr.plugin.InternalCollection{
    .{ .kind = "visit", .indexed = &.{"name"} },
};

pub const content_types = [_]publr.plugin.ContentTypeDef{.{
    .handle = "salutation",
    .name = "Salutation",
    .title_field = "note",
    .fields = &.{.{ .name = "note", .label = "Note", .kind = "string", .required = true }},
}};

pub const permissions = [_]publr.plugin.Permission{
    .{ .key = "users.names", .reason = "Greets the people on the site by name" },
};

pub const roles = [_]publr.plugin.Role{.{
    .name = "editor",
    .label = "Editor",
    .grants = &.{"greeter.*"},
}};

pub const operations = [_]type{ Greet, Count, People };
pub const middleware = [_]type{Announce};

pub const Greet = struct {
    pub const name = "greeter.greet";
    pub const description = "Record a greeting and count them";
    pub const details =
        \\Editors and administrators may call it. The greeting is a record of the plugin's
        \\type `salutation`; the answer is the total so far. A greeting to `nobody` is not
        \\found: there is no one to greet.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { note: []const u8 };
    pub const Out = struct { total: u32 };
    pub const example: In = .{ .note = "hello from the sandbox" };
    pub const example_out: Out = .{ .total = 1 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .note = "The greeting, up to 280 characters",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .total = "How many greetings exist now" };

    pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now_ms() >= 0);

        if (in.note.len == 0 or in.note.len > 280) {
            return error.Invalid;
        }

        if (std.mem.eql(u8, in.note, "nobody")) {
            return error.NotFound;
        }

        const note = .{ .note = in.note };
        const document = std.json.Stringify.valueAlloc(ctx.arena(), note, .{}) catch {
            return error.OutOfMemory;
        };

        _ = try ctx.call(record.Create, .{ .type = "salutation", .document = document });

        return count(ctx);
    }
};

pub const Count = struct {
    pub const name = "greeter.count";
    pub const description = "Count the greetings";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = Greet.Out;
    pub const example: In = .{};
    pub const example_out: Out = .{ .total = 1 };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .total = "How many greetings exist" };

    pub fn run(ctx: *PluginCtx, _: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now_ms() >= 0);

        return count(ctx);
    }
};

pub const People = struct {
    pub const name = "greeter.people";
    pub const description = "Greet everyone on the site by name";
    pub const details =
        \\Needs `users.names`: without it, denied.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { greetings: []const []const u8 };
    pub const example: In = .{};
    pub const example_out: Out = .{ .greetings = &.{"hello, Admin"} };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .greetings = "One greeting per person" };

    pub fn run(ctx: *PluginCtx, _: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now_ms() >= 0);

        const people = try ctx.call(publr.operations.user.Options, .{});
        const count_of_people = people.users.len;
        const greetings = ctx.arena().alloc([]const u8, count_of_people) catch {
            return error.OutOfMemory;
        };

        for (people.users, greetings) |person, *greeting| {
            greeting.* = std.fmt.allocPrint(ctx.arena(), "hello, {s}", .{person.label}) catch {
                return error.OutOfMemory;
            };
        }

        return .{ .greetings = greetings };
    }
};

fn count(ctx: *PluginCtx) sdk.Error!Greet.Out {
    const all = try ctx.call(record.List, .{ .type = "salutation", .limit = 200 });

    return .{ .total = @intCast(all.records.len) };
}

pub const Announce = struct {
    pub const stage: sdk.middleware.Stage = .after;
    pub const operation = "greeter.greet";
    pub const reason = "Tells other plugins when someone was greeted";

    pub fn run(ctx: *PluginCtx, in: *Greet.In, out: *const Greet.Out) sdk.Error!void {
        std.debug.assert(out.total > 0);
        ctx.notice("greeter.greeted", in.note);
    }
};
