//! Greetings, kept as records of the plugin's own type.
//!
//! The plugin the sandbox is tested with: `greeter greet` records a greeting and answers how
//! many there are, `greeter count` only counts, `greeter people` greets everyone on the site
//! by name. That last one needs a permission, so an administrator can take it away and watch
//! it answer denied. An app's visitors may wave (`app.greeter.wave`), each visitor's waves
//! counted apart; `app.greeter.hail` is public: a page on any site may call it.
const std = @import("std");
const publr = @import("publr");

const record = publr.operations.record;

const manifest: publr.Manifest = .{
    .name = "greeter",
    .version = "0.1.0",
};

/// Greeter works with sampler when it is there: it says hello through it.
const compatible_with = .{"sampler@^0.1"};
const remotes = [_]type{SamplerHello};
pub const SamplerHello = publr.remote.operation(
    "sampler.hello",
    struct {
        who: []const u8,
    },
    struct {
        text: []const u8,
    },
);

/// A visit
///
/// One wave of an app's visitor.
pub const Visit = struct {
    /// Visitor
    name: []const u8,
};

pub const Visits = publr.record.define(Visit, .{
    .name = "greeter.visit",
    .internal = true,
    .indexed = &.{.name},
    .scope = .app,
});

/// How many times a visitor has waved.
const waves_of = publr.query.prepare(
    \\count(*[_type == "greeter.visit" && name == $name])
, .{});

/// Salutation
///
/// A greeting someone recorded.
pub const Salutation = struct {
    /// Note
    note: []const u8,
};

pub const Salutations = publr.record.define(Salutation, .{
    .name = "greeter.salutation",
    .title_field = .note,
    .fields = .{
        .note = .{
            .validation = .{
                .required = true,
            },
        },
    },
});

const permissions = .{
    .{
        .key = "users.names",
        .reason = "Greets the people on the site by name",
    },
};

const roles = [_]publr.plugin.Role{.{
    .name = "editor",
    .label = "Editor",
}};

const operations = [_]type{ Greet, Count, People, Recall, Wave, Hail };

pub const RecallIn = struct {
    /// The salutation, by id
    salutation: Salutations.Ref,
};

pub const RecallOut = struct {
    /// Its note
    note: []const u8,
};

/// The note of a salutation, read by core before greeter runs
///
/// Takes a reference: the caller names a salutation, the sandbox hands greeter the stored one.
/// Administrators and granted roles call it. An unknown salutation is not found.
///
/// Example:
///   in: { "salutation": "a1b2c3d4e5f60718293a4b5c" }
///   out: { "note": "Hello, world" }
pub const Recall = publr.operation.define(RecallIn, RecallOut, .{
    .name = "recall",
    .kind = .read,
    .run = recall,
});

fn recall(ctx: *publr.Ctx, in: RecallIn) publr.Error!RecallOut {
    std.debug.assert(ctx.now().ms >= 0);

    const salutation = in.salutation.value orelse return error.Invalid;

    return .{
        .note = salutation.note,
    };
}

pub const WaveIn = struct {};

pub const WaveOut = struct {
    /// The visitor's id
    visitor: []const u8,
    /// How many times this visitor has waved
    waves: u32,
};

/// Wave as a visitor, and hear how many times this visitor has.
///
/// Called from an app's pages that list greeter in their `.plugins`. Each wave is kept for
/// the visitor who made it; the answer counts theirs alone.
///
/// Fails:
/// - NoVisitor (409): called from somewhere with no visitor
///
/// Example:
///   in: {}
///   out: { "visitor": "0123456789abcdef01234567", "waves": 1 }
pub const Wave = publr.operation.define(WaveIn, WaveOut, .{
    .name = "wave",
    .kind = .write,
    .untrusted_callers = true,
    .run = wave,
});

fn wave(ctx: *publr.Ctx, _: WaveIn) publr.Error!WaveOut {
    std.debug.assert(ctx.now().ms >= 0);

    const visitor = ctx.caller().visitor;

    if (visitor.len == 0) {
        return ctx.fail(.NoVisitor, "Wave from an app's page: there is no visitor here.", .{});
    }

    _ = try Visits.create(ctx, .{
        .name = visitor,
    });

    return .{
        .visitor = visitor,
        .waves = try waves_of.execute(ctx, u32, .{
            .name = visitor,
        }),
    };
}

pub const GreetIn = struct {
    /// The greeting
    note: []const u8,
};

pub const GreetOut = struct {
    /// How many greetings exist now
    ///
    /// Why: a count, not money
    total: u32,
};

/// Record a greeting and count them
///
/// Administrators and granted roles call it. The greeting is a record of the plugin's
/// type `greeter.salutation`; the answer is the total so far. A greeting to `nobody` is not
/// found: there is no one to greet. The note is kept out of the logs, so the sandbox carries a
/// plugin's own secrets.
///
/// Example:
///   in: { "note": "hello from the sandbox" }
///   out: { "total": 1 }
pub const Greet = publr.operation.define(GreetIn, GreetOut, .{
    .name = "greet",
    .kind = .write,
    .secret = .{.note},
    .run = greet,
});

fn greet(ctx: *publr.Ctx, in: GreetIn) publr.Error!GreetOut {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.note.len == 0 or in.note.len > 200) {
        return error.Invalid;
    }

    if (std.mem.eql(u8, in.note, "nobody")) {
        ctx.log(.err, "Nobody to greet", .{});
        return error.NotFound;
    }

    ctx.log(.info, "Greeted with {s}", .{in.note});

    const note = .{
        .note = in.note,
    };
    const document = std.json.Stringify.valueAlloc(ctx.arena(), note, .{}) catch {
        return error.OutOfMemory;
    };

    _ = try ctx.call(record.Create, .{
        .type = "greeter.salutation",
        .document = document,
    });

    return count(ctx);
}

pub const CountIn = struct {};

/// Count the greetings
///
/// Example:
///   in: {}
///   out: { "total": 1 }
pub const Count = publr.operation.define(CountIn, GreetOut, .{
    .name = "count",
    .kind = .read,
    .run = count_all,
});

fn count_all(ctx: *publr.Ctx, _: CountIn) publr.Error!GreetOut {
    std.debug.assert(ctx.now().ms >= 0);

    return count(ctx);
}

pub const PeopleIn = struct {};

pub const PeopleOut = struct {
    /// One greeting per person
    greetings: []const []const u8,
};

/// Greet everyone on the site by name
///
/// Needs `users.names`: without it, denied.
///
/// Example:
///   in: {}
///   out: { "greetings": [] }
pub const People = publr.operation.define(PeopleIn, PeopleOut, .{
    .name = "people",
    .kind = .read,
    .run = people_of,
});

fn people_of(ctx: *publr.Ctx, _: PeopleIn) publr.Error!PeopleOut {
    std.debug.assert(ctx.now().ms >= 0);

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

    return .{
        .greetings = greetings,
    };
}

fn count(ctx: *publr.Ctx) publr.Error!GreetOut {
    const all = try ctx.call(record.List, .{
        .type = "greeter.salutation",
        .limit = 200,
    });

    return .{
        .total = @intCast(all.records.len),
    };
}

/// Someone was greeted.
pub const Greeted = publr.event.define(.{
    .name = "greeted",
    .payload = struct {
        /// The greeting's note
        note: []const u8,
    },
});

/// Tells other plugins when someone was greeted
fn announce(ctx: *publr.Ctx, in: *GreetIn, out: *const GreetOut) publr.Error!void {
    std.debug.assert(out.total > 0);
    std.debug.assert(in.note.len > 0);

    ctx.emit(Greeted, .{
        .note = in.note,
    });
}

/// Notes how many greetings there are, once a greeting is kept
fn tally(ctx: *publr.QueueCtx, out: GreetOut) publr.Error!void {
    std.debug.assert(out.total > 0);

    ctx.log(.info, "{d} greetings in all", .{out.total});
}

/// Refuses a sign-in from the visitors the tests name, and nobody else's
///
/// A hostile hook, for the tests: for one visitor it crashes, for another it tries to write
/// (a `before` hook only reads), for a third it refuses in its own words.
///
/// Fails:
/// - AccountSuspended (403): the account is on hold
fn refuse_named(ctx: *publr.Ctx, signed: publr.auth.SignedIn.Payload) publr.Error!void {
    std.debug.assert(signed.user.len > 0);
    std.debug.assert(signed.method.len > 0);

    if (std.mem.eql(u8, signed.visitor, refused_visitor)) {
        return error.Denied;
    }

    if (std.mem.eql(u8, signed.visitor, crashing_visitor)) {
        @trap();
    }

    if (std.mem.eql(u8, signed.visitor, writing_visitor)) {
        const created = Visits.create(ctx, .{
            .name = "before",
        });

        if (created) |_| {
            ctx.log(.info, "a before hook wrote", .{});
        } else |err| {
            ctx.log(.info, "a before hook could not write: {t}", .{err});
        }
    }

    if (std.mem.eql(u8, signed.visitor, suspended_visitor)) {
        return ctx.fail(.AccountSuspended, "This account is on hold.", .{});
    }
}

pub const refused_visitor = "0000000000000000000000ff";
pub const crashing_visitor = "0000000000000000000000fe";
pub const writing_visitor = "0000000000000000000000fd";
pub const suspended_visitor = "0000000000000000000000fc";

/// Keeps a salutation saying "keep" out of the archive
fn keep_out_of_archive(ctx: *publr.Ctx, moved: publr.record.Transitioned) publr.Error!void {
    std.debug.assert(std.mem.eql(u8, moved.transition, "archive"));
    std.debug.assert(moved.record.len > 0);

    const held = try Salutations.get(ctx, moved.record, .{});

    if (std.mem.eql(u8, held.value.note, "keep")) {
        return error.Denied;
    }
}

/// Keeps a salutation saying "keep" out of the trash; every other transition goes on
fn keep_kept(ctx: *publr.Ctx, moved: publr.record.Transitioned) publr.Error!void {
    std.debug.assert(moved.record.len > 0);
    std.debug.assert(moved.to.len > 0);

    if (!std.mem.eql(u8, moved.transition, "trash")) {
        return;
    }

    const held = try Salutations.get(ctx, moved.record, .{});

    if (std.mem.eql(u8, held.value.note, "keep")) {
        return error.Denied;
    }
}

/// Notes every sign-in as a visit of its own, inside the sign-in's write
fn note_sign_in(ctx: *publr.Ctx, signed: publr.auth.SignedIn.Payload) publr.Error!void {
    std.debug.assert(signed.user.len > 0);

    _ = try Visits.create(ctx, .{
        .name = try ctx.print("signed:{s}:{s}", .{ signed.method, signed.visitor }),
    });
}

/// Notes every sign-out
fn note_sign_out(ctx: *publr.Ctx, left: publr.auth.SignedOut.Payload) publr.Error!void {
    std.debug.assert(left.user.len > 0);

    _ = try Visits.create(ctx, .{
        .name = "left",
    });
}

/// Adds one to every number greeter's names carry, for the tests
fn add_one(ctx: *publr.Ctx, value: *u32) publr.Error!void {
    std.debug.assert(ctx.now().ms >= 0);

    value.* += 1;
}

/// Shows a salutation the way a test needs to see it
///
/// A hostile modifier, for the tests: it hands back markup and control characters, and tries to
/// write while it runs. What it answers is text; the write is refused.
fn shown(ctx: *publr.Ctx, item: *publr.Title(Salutation)) publr.Error!void {
    std.debug.assert(item.id.len > 0);

    const created = Visits.create(ctx, .{
        .name = "display",
    });
    const wrote = if (created) |_| "wrote" else |err| switch (err) {
        error.NotYet => return error.NotYet,
        else => @errorName(err),
    };

    // Read back through the batch: every item's record in one read.
    const stored = Salutations.get(ctx, item.id, .{}) catch |err| switch (err) {
        error.NotYet => return error.NotYet,
        else => null,
    };
    const note = if (stored) |held| held.value.note else @errorName(error.NotFound);

    item.title = try ctx.print("<script>x</script>{s}|{s}|{s}\x01", .{
        item.title,
        note,
        wrote,
    });
}

pub const HailIn = struct {};

pub const HailOut = struct {
    /// The visitor's id, "" none
    visitor: []const u8,
};

/// Answer the visitor who called, from any site.
///
/// A page elsewhere names its visitor in the `publr-visitor` header, and the answer says who
/// that was.
///
/// Example:
///   in: {}
///   out: { "visitor": "0123456789abcdef01234567" }
pub const Hail = publr.operation.define(HailIn, HailOut, .{
    .name = "hail",
    .kind = .read,
    .untrusted_callers = true,
    .public_api = true,
    .run = hail,
});

fn hail(ctx: *publr.Ctx, _: HailIn) publr.Error!HailOut {
    std.debug.assert(ctx.now().ms >= 0);

    return .{
        .visitor = ctx.caller().visitor,
    };
}

pub const plugin = publr.plugin.define(manifest, .{
    .compatible_with = compatible_with,
    .remotes = remotes,
    .records = &.{ Visits, Salutations },
    .permissions = permissions,
    .roles = roles,
    .operations = operations,
    .events = &.{Greeted},
    .hooks = &.{
        publr.after(Greet, announce),
        publr.on(Greet, tally),
        publr.before(publr.auth.SignedIn, refuse_named),
        publr.after(publr.auth.SignedIn, note_sign_in),
        publr.after(publr.auth.SignedOut, note_sign_out),
        publr.before(Salutations.any_transition, keep_kept),
        publr.before(Salutations.transitions.archive, keep_out_of_archive),
        publr.modify("greeter.salutation.title", shown),
        publr.modify("greeter.*", add_one),
    },
});
