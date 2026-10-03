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

pub const namespaces = [_]sdk.operation.Namespace{
    .{
        .name = "greeter",
        .summary = "Greetings, kept as records of the plugin's own type",
        .details =
        \\The plugin the sandbox is tested with: `greeter greet` records a greeting and
        \\answers how many there are, `greeter count` only counts, `greeter people` greets
        \\everyone on the site by name. That last one needs a permission, so an
        \\administrator can take it away and watch it answer denied.
        ,
    },
    .{
        .name = "app.greeter",
        .summary = "What an app's visitors may do with greeter",
        .details =
        \\`app.greeter.wave`, called from an app's pages at `/_api/greeter/wave`: each visitor's
        \\waves are counted apart.
        ,
    },
};

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

pub const operations = [_]type{ Greet, Count, People, Recall, Wave };
pub const middleware = [_]type{ Announce, Shown };

/// Takes a reference: the caller names a post, the sandbox hands greeter the stored one.
pub const Recall = struct {
    pub const name = "greeter.recall";
    pub const description = "The title of a post, read by core before greeter runs";
    pub const details = "Editors and administrators may call it. An unknown post is not found.";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { post: publr.records.Ref(struct { title: []const u8 }, "post") };
    pub const Out = struct { title: []const u8 };
    pub const example: In = .{ .post = .{ .id = "a1b2c3d4e5f60718293a4b5c" } };
    pub const example_out: Out = .{ .title = "Hello, world" };
    pub const field_docs: sdk.operation.Docs(In) = .{ .post = "The post, by id" };

    pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now_ms() >= 0);

        const post = in.post.value orelse return error.Invalid;

        return .{ .title = post.title };
    }
};

/// What an app's visitor may do (`app.`): wave, counted per visitor in greeter's internal
/// `visit` collection. Exercises `<mount>/_api/greeter/wave` and the visitor's id.
pub const Wave = struct {
    pub const name = "app.greeter.wave";
    pub const description = "Wave as a visitor, and hear how many times this visitor has";
    pub const details =
        \\Anyone may call it, from an app that lists greeter in its `.plugins`. Each wave is
        \\kept for the visitor who made it; the answer counts theirs alone.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const In = struct {};
    pub const Out = struct { visitor: []const u8, waves: u32 };
    pub const example: In = .{};
    pub const example_out: Out = .{ .visitor = "0123456789abcdef01234567", .waves = 1 };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .visitor = "The visitor's id",
        .waves = "How many times this visitor has waved",
    };

    const Visit = struct { name: []const u8 };
    const visits = publr.internal.of(Visit, "visit");

    pub fn run(ctx: *PluginCtx, _: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now_ms() >= 0);

        const visitor = ctx.visitor();

        if (visitor.len == 0) {
            return ctx.fail("NoVisitor", "Wave from an app's page: there is no visitor here.");
        }

        _ = try visits.create(ctx, .{ .name = visitor });

        const mine = try visits.find(ctx, .{ .name = visitor }, .{ .limit = 200 });

        return .{ .visitor = visitor, .waves = @intCast(mine.len) };
    }
};

pub const Greet = struct {
    pub const name = "greeter.greet";
    /// Kept out of the logs, so the sandbox carries a plugin's own secrets.
    pub const secret = .{"note"};
    pub const description = "Record a greeting and count them";
    pub const details =
        \\Editors and administrators may call it. The greeting is a record of the plugin's
        \\type `salutation`; the answer is the total so far. A greeting to `nobody` is not
        \\found: there is no one to greet.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { note: []const u8 };
    pub const Out = struct { total: u32 };
    pub const rules: sdk.operation.Rules(In) = .{ .note = .{ .max_len = 200 } };
    pub const example: In = .{ .note = "hello from the sandbox" };
    pub const example_out: Out = .{ .total = 1 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .note = "The greeting",
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

/// A hostile display hook, for the tests: it hands back markup and control characters, and
/// tries to write while it runs. What it answers is text; the write is refused.
pub const Shown = struct {
    pub const stage: sdk.middleware.Stage = .display;
    pub const point = "record.title";
    pub const content_type = "salutation";
    pub const reason = "Shows a salutation the way a test needs to see it";

    const Visit = struct { name: []const u8 };
    const visits = publr.internal.of(Visit, "visit");

    pub fn run(ctx: *PluginCtx, in: *sdk.display_hooks.Batch) sdk.Error!void {
        std.debug.assert(in.items.len <= sdk.display_hooks.batch_items_max);

        const created = visits.create(ctx, .{ .name = "display" });
        const wrote = if (created) |_| "wrote" else |err| @errorName(err);

        for (in.items) |*item| {
            const note = if (item.fields == .object) item.fields.object.get("note") else null;
            const text = if (note) |value| (if (value == .string) value.string else "") else "";

            item.value = std.fmt.allocPrint(ctx.arena(), "<script>x</script>{s}|{s}|{s}\x01", .{
                item.value,
                text,
                wrote,
            }) catch return error.OutOfMemory;
        }
    }
};
