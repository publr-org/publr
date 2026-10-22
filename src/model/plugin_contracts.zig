//! Whether a plugin's remotes fit the plugins they name, as they are now: each operation it
//! calls, record it reads and event it hears against what that plugin provides, and that
//! plugin's version against the range declared. Pure data: the callers gather what is there.

const std = @import("std");
const contract = @import("contract.zig");
const depends_on = @import("version_range.zig");
const kinds = @import("kinds.zig");

pub const findings_max: u32 = 64;
/// How many fields a remote record lists.
pub const fields_max: u32 = 64;

/// One operation as its plugin provides it.
pub const Provided = struct {
    name: []const u8,
    input: []const contract.Node,
    output: []const contract.Node,
};

/// A field of a record type as its plugin declares it: its kind id and whether it holds
/// several values.
pub const ProvidedField = struct {
    name: []const u8,
    kind: []const u8,
    many: bool = false,
};

/// A record type as its plugin declares it, content or internal, with each field's kind.
pub const ProvidedRecord = struct {
    name: []const u8,
    fields: []const ProvidedField = &.{},
};

/// An event as its plugin declares it (`.events`), with its payload's shape.
pub const ProvidedEvent = struct {
    name: []const u8,
    payload: []const contract.Node,
};

/// A plugin there now, compiled in or installed and enabled.
pub const Provider = struct {
    plugin: []const u8,
    version: []const u8,
    operations: []const Provided,
    records: []const ProvidedRecord = &.{},
    events: []const ProvidedEvent = &.{},
};

/// What a remote is: `publr.remote.operation`, `publr.remote.record`, `publr.remote.event`.
pub const Remote = enum { operation, record, event };

/// The kinds of field a remote record's Zig type can read: text reads any text kind and a
/// reference's id, an `X.Ref` a reference, a list of text several values.
pub const Holds = enum {
    text,
    integer,
    number,
    boolean,
    datetime,
    money,
    reference,
    choice,
    texts,
    references,
    any,
};

/// A field of a remote record as the plugin reads it.
pub const UsedField = struct {
    name: []const u8,
    holds: Holds,
};

/// Another plugin's operation, record or event as a plugin uses it: an operation's Sends
/// (`input`) and Reads (`output`), an event's payload (`output`), a record's fields.
pub const Used = struct {
    kind: Remote = .operation,
    name: []const u8,
    input: []const contract.Node = &.{},
    output: []const contract.Node = &.{},
    fields: []const UsedField = &.{},
};

/// A plugin as a user of others: what it names and what it uses.
pub const User = struct {
    plugin: []const u8,
    depends_on: []const []const u8,
    compatible_with: []const []const u8,
    remotes: []const Used,
};

pub const Why = enum { absent, out_of_range, missing, no_field, field_kind, misfit };

/// A remote that does not fit: which, its plugin as it is (`version` empty when absent),
/// whether the user needs it, and why. A misfit says where (`problem`, in `nodes`); a
/// record's field problem names the field and the kind it has.
pub const Finding = struct {
    name: []const u8,
    kind: Remote = .operation,
    plugin: []const u8,
    version: []const u8 = "",
    range: []const u8 = "",
    required: bool,
    why: Why,
    field: []const u8 = "",
    field_kind: []const u8 = "",
    holds: Holds = .any,
    problem: ?contract.Problem = null,
    nodes: []const contract.Node = &.{},
};

/// The user's remotes that do not fit the providers, into `out`; how many. A plugin that is
/// not there is a finding too: a required one can't be enabled, an optional one is off.
pub fn check(user: User, providers: []const Provider, out: []Finding) u32 {
    std.debug.assert(out.len > 0);
    std.debug.assert(user.remotes.len <= findings_max);

    var count: u32 = 0;

    for (user.remotes) |used| {
        if (count == out.len) {
            break;
        }

        if (finding_of(user, used, providers)) |found| {
            out[count] = found;
            count += 1;
        }
    }

    return count;
}

/// Whether the user's remote `name` is on: it fits, or it is no remote of the user's
/// (nothing to check). Off when its plugin is not there or it does not fit.
pub fn remote_on(user: User, providers: []const Provider, name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(user.plugin.len > 0);

    for (user.remotes) |used| {
        if (std.mem.eql(u8, used.name, name)) {
            return finding_of(user, used, providers) == null;
        }
    }

    return true;
}

/// The remote the user declares by `name`, if any.
pub fn find_used(user: User, name: []const u8) ?Used {
    std.debug.assert(name.len > 0);

    for (user.remotes) |used| {
        if (std.mem.eql(u8, used.name, name)) {
            return used;
        }
    }

    return null;
}

fn finding_of(user: User, used: Used, providers: []const Provider) ?Finding {
    std.debug.assert(used.name.len > 0);
    std.debug.assert(user.plugin.len > 0);

    const target = plugin_of(used.name);
    const declared = range_of(user.depends_on, target);
    const range = declared orelse range_of(user.compatible_with, target) orelse "";
    var base: Finding = .{
        .name = used.name,
        .kind = used.kind,
        .plugin = target,
        .range = range,
        .required = declared != null,
        .why = .absent,
    };
    const provider = find(providers, target) orelse return base;

    base.version = provider.version;

    if (!depends_on.satisfies(provider.version, range)) {
        base.why = .out_of_range;
        return base;
    }

    base.why = .missing;

    return switch (used.kind) {
        .operation => operation_finding(base, used, provider),
        .record => record_finding(base, used, provider),
        .event => event_finding(base, used, provider),
    };
}

fn operation_finding(base: Finding, used: Used, provider: Provider) ?Finding {
    std.debug.assert(used.kind == .operation);

    for (provider.operations) |provided| {
        if (std.mem.eql(u8, provided.name, used.name)) {
            return misfit_of(base, used, provided);
        }
    }

    return base;
}

/// An event is one the plugin declares, or an operation's: every operation emits an event
/// under its own name carrying its answer.
fn event_finding(base: Finding, used: Used, provider: Provider) ?Finding {
    std.debug.assert(used.kind == .event);

    for (provider.events) |provided| {
        if (std.mem.eql(u8, provided.name, used.name)) {
            return payload_misfit(base, used.output, provided.payload);
        }
    }

    for (provider.operations) |provided| {
        if (std.mem.eql(u8, provided.name, used.name)) {
            return payload_misfit(base, used.output, provided.output);
        }
    }

    return base;
}

fn payload_misfit(
    base: Finding,
    read: []const contract.Node,
    given: []const contract.Node,
) ?Finding {
    std.debug.assert(base.name.len > 0);

    if (read.len == 0 or given.len == 0) {
        return null;
    }

    var found = base;

    found.why = .misfit;

    if (contract.check_output(read, given)) |problem| {
        found.problem = problem;
        found.nodes = read;
        return found;
    }

    return null;
}

fn record_finding(base: Finding, used: Used, provider: Provider) ?Finding {
    std.debug.assert(used.kind == .record);
    std.debug.assert(used.fields.len <= fields_max);

    const record = find_record(provider.records, used.name) orelse return base;

    for (used.fields) |wanted| {
        var found = base;

        found.field = wanted.name;
        found.holds = wanted.holds;

        const given = find_field(record.fields, wanted.name) orelse {
            found.why = .no_field;
            return found;
        };

        if (!holds_kind(wanted.holds, given.kind, given.many)) {
            found.why = .field_kind;
            found.field_kind = given.kind;
            return found;
        }
    }

    return null;
}

fn find_record(records: []const ProvidedRecord, name: []const u8) ?ProvidedRecord {
    std.debug.assert(name.len > 0);

    for (records) |record| {
        if (std.mem.eql(u8, record.name, name)) {
            return record;
        }
    }

    return null;
}

fn find_field(fields: []const ProvidedField, name: []const u8) ?ProvidedField {
    std.debug.assert(name.len > 0);

    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return field;
        }
    }

    return null;
}

/// Whether a field of kind `kind` (several values when `many`) reads as `holds`.
pub fn holds_kind(holds: Holds, kind: []const u8, many: bool) bool {
    std.debug.assert(kind.len <= kinds.string_len_max);

    if (holds == .any) {
        return true;
    }

    const found = kinds.find(&kinds.core, kind) orelse return false;
    const storage = found.storage;
    const text_like = storage == .text or storage == .long;

    if (many) {
        return switch (holds) {
            .texts => text_like or storage == .ref,
            .references => storage == .ref,
            else => false,
        };
    }

    const is = struct {
        fn is(id: []const u8, wanted: []const u8) bool {
            return std.mem.eql(u8, id, wanted);
        }
    }.is;

    return switch (holds) {
        .text => text_like or storage == .ref,
        .integer => storage == .int and !is(kind, "datetime") and !is(kind, "money"),
        .number => storage == .real or is(kind, "integer"),
        .boolean => storage == .bool,
        .datetime => is(kind, "datetime"),
        .money => is(kind, "money"),
        .reference => storage == .ref,
        .choice => is(kind, "select"),
        .texts, .references => false,
        .any => true,
    };
}

fn misfit_of(base: Finding, used: Used, provided: Provided) ?Finding {
    std.debug.assert(base.name.len > 0);

    if (used.input.len == 0 or provided.input.len == 0) {
        return null;
    }

    var found = base;

    found.why = .misfit;

    if (contract.check_input(used.input, provided.input)) |problem| {
        found.problem = problem;
        found.nodes = if (problem.on_user_side) used.input else provided.input;
        return found;
    }

    if (used.output.len > 0 and provided.output.len > 0) {
        if (contract.check_output(used.output, provided.output)) |problem| {
            found.problem = problem;
            found.nodes = used.output;
            return found;
        }
    }

    return null;
}

fn find(providers: []const Provider, plugin: []const u8) ?Provider {
    std.debug.assert(plugin.len > 0);

    for (providers) |provider| {
        if (std.mem.eql(u8, provider.plugin, plugin)) {
            return provider;
        }
    }

    return null;
}

/// The range a list gives `plugin` (`""` for any), or null when it does not name it.
fn range_of(list: []const []const u8, plugin: []const u8) ?[]const u8 {
    std.debug.assert(plugin.len > 0);

    for (list) |text| {
        if (text.len == 0) {
            continue;
        }

        const wanted = depends_on.parse(text);

        if (std.mem.eql(u8, wanted.name, plugin)) {
            return wanted.range;
        }
    }

    return null;
}

/// The plugin a remote belongs to: `inventory` for `inventory.adjust` and for
/// `app.inventory.reserve`.
pub fn plugin_of(operation: []const u8) []const u8 {
    std.debug.assert(operation.len > 0);

    const app = std.mem.startsWith(u8, operation, "app.");
    const rest = if (app) operation["app.".len..] else operation;
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;

    return rest[0..dot];
}

/// A finding in plain words: `products 0.2.0 has no sku on products.variant`.
pub fn describe(finding: Finding, buffer: []u8) []const u8 {
    std.debug.assert(buffer.len >= 64);
    std.debug.assert(finding.name.len > 0);

    var path_buffer: [128]u8 = undefined;
    const path = if (finding.problem) |problem|
        contract.path_of(finding.nodes, problem.node, &path_buffer)
    else
        "";
    const plugin = finding.plugin;
    const version = finding.version;
    const where = if (path.len > 0) path else "its shape";
    const failed = finding.problem;
    const reason = if (failed) |found| contract.reason_text(found.reason) else "differs";
    const what = switch (finding.kind) {
        .operation => "operation",
        .record => "record type",
        .event => "event",
    };
    const text = switch (finding.why) {
        .absent => std.fmt.bufPrint(buffer, "{s} isn't installed or enabled", .{plugin}),
        .out_of_range => std.fmt.bufPrint(buffer, "{s} {s} is outside {s}", .{
            plugin,
            version,
            if (finding.range.len > 0) finding.range else "the range it works with",
        }),
        .missing => std.fmt.bufPrint(buffer, "{s} {s} has no {s} {s}", .{
            plugin,
            version,
            what,
            finding.name,
        }),
        .no_field => std.fmt.bufPrint(buffer, "{s} {s} has no {s} on {s}", .{
            plugin,
            version,
            finding.field,
            finding.name,
        }),
        .field_kind => std.fmt.bufPrint(buffer, "{s} {s} keeps {s} on {s} as {s}, not {s}", .{
            plugin,
            version,
            finding.field,
            finding.name,
            finding.field_kind,
            holds_text(finding.holds),
        }),
        .misfit => std.fmt.bufPrint(buffer, "{s} {s}: {s} {s} {s}", .{
            plugin,
            version,
            finding.name,
            where,
            reason,
        }),
    };

    return text catch buffer[0..0];
}

fn holds_text(holds: Holds) []const u8 {
    std.debug.assert(@intFromEnum(holds) <= @intFromEnum(Holds.any));

    return switch (holds) {
        .text => "text",
        .integer => "a whole number",
        .number => "a number",
        .boolean => "yes or no",
        .datetime => "a date and time",
        .money => "money",
        .reference => "a reference",
        .choice => "a choice",
        .texts => "a list",
        .references => "references",
        .any => "anything",
    };
}

test "contracts: fit, out of range, misfit, absent" {
    const Accepts = struct {
        sku: []const u8,
        quantity: u32,
    };
    const Answers = struct {
        held: bool,
        left: u32,
    };
    const provider: Provider = .{
        .plugin = "inventory",
        .version = "1.4.0",
        .operations = &.{.{
            .name = "app.inventory.reserve",
            .input = comptime contract.describe(Accepts),
            .output = comptime contract.describe(Answers),
        }},
    };
    const fitting: Used = .{
        .name = "app.inventory.reserve",
        .input = comptime contract.describe(struct {
            sku: []const u8,
            quantity: u32,
        }),
        .output = comptime contract.describe(struct {
            held: bool,
        }),
    };
    const misfitting: Used = .{
        .name = "app.inventory.reserve",
        .input = comptime contract.describe(struct {
            sku: []const u8,
        }),
        .output = comptime contract.describe(struct {
            held: bool,
        }),
    };
    var out: [4]Finding = undefined;

    const fits: User = .{
        .plugin = "cart",
        .depends_on = &.{"inventory@^1.2"},
        .compatible_with = &.{},
        .remotes = &.{fitting},
    };
    try std.testing.expectEqual(@as(u32, 0), check(fits, &.{provider}, &out));

    var too_new = fits;
    too_new.depends_on = &.{"inventory@^2"};
    try std.testing.expectEqual(@as(u32, 1), check(too_new, &.{provider}, &out));
    try std.testing.expectEqual(Why.out_of_range, out[0].why);

    var broken = fits;
    broken.remotes = &.{misfitting};
    try std.testing.expectEqual(@as(u32, 1), check(broken, &.{provider}, &out));
    try std.testing.expect(out[0].required);

    var text_buffer: [256]u8 = undefined;
    const text = describe(out[0], &text_buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "quantity") != null);

    var optional = broken;
    optional.depends_on = &.{};
    optional.compatible_with = &.{"inventory"};
    try std.testing.expectEqual(@as(u32, 1), check(optional, &.{provider}, &out));
    try std.testing.expect(!out[0].required);
    try std.testing.expect(!remote_on(optional, &.{provider}, "app.inventory.reserve"));
    try std.testing.expect(!remote_on(optional, &.{}, "app.inventory.reserve"));
    try std.testing.expect(remote_on(optional, &.{}, "app.other.call"));
    try std.testing.expectEqual(@as(u32, 1), check(optional, &.{}, &out));
    try std.testing.expectEqual(Why.absent, out[0].why);
}

test "contracts: a remote record's fields by kind, an event's payload by shape" {
    const products: Provider = .{
        .plugin = "products",
        .version = "0.2.0",
        .operations = &.{},
        .records = &.{.{
            .name = "products.variant",
            .fields = &.{
                .{
                    .name = "title",
                    .kind = "string",
                },
                .{
                    .name = "slug",
                    .kind = "slug",
                },
                .{
                    .name = "product",
                    .kind = "reference",
                },
                .{
                    .name = "stock",
                    .kind = "integer",
                },
            },
        }},
        .events = &.{.{
            .name = "products.renamed",
            .payload = comptime contract.describe(struct {
                title: []const u8,
            }),
        }},
    };
    const fits: Used = .{
        .kind = .record,
        .name = "products.variant",
        .fields = &.{
            .{
                .name = "title",
                .holds = .text,
            },
            .{
                .name = "slug",
                .holds = .text,
            },
            .{
                .name = "product",
                .holds = .text,
            },
        },
    };
    var user: User = .{
        .plugin = "cart",
        .depends_on = &.{"products@^0.2"},
        .compatible_with = &.{},
        .remotes = &.{fits},
    };
    var out: [4]Finding = undefined;

    try std.testing.expectEqual(@as(u32, 0), check(user, &.{products}, &out));

    var no_sku = fits;
    no_sku.fields = &.{.{
        .name = "sku",
        .holds = .text,
    }};
    user.remotes = &.{no_sku};
    try std.testing.expectEqual(@as(u32, 1), check(user, &.{products}, &out));
    try std.testing.expectEqual(Why.no_field, out[0].why);

    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "products 0.2.0 has no sku on products.variant",
        describe(out[0], &buffer),
    );

    var stock_as_text = fits;
    stock_as_text.fields = &.{.{
        .name = "stock",
        .holds = .text,
    }};
    user.remotes = &.{stock_as_text};
    try std.testing.expectEqual(@as(u32, 1), check(user, &.{products}, &out));
    try std.testing.expectEqual(Why.field_kind, out[0].why);

    const heard: Used = .{
        .kind = .event,
        .name = "products.renamed",
        .output = comptime contract.describe(struct {
            title: []const u8,
        }),
    };
    const misheard: Used = .{
        .kind = .event,
        .name = "products.renamed",
        .output = comptime contract.describe(struct {
            title: u32,
        }),
    };
    user.remotes = &.{heard};
    try std.testing.expectEqual(@as(u32, 0), check(user, &.{products}, &out));
    user.remotes = &.{misheard};
    try std.testing.expectEqual(@as(u32, 1), check(user, &.{products}, &out));
    try std.testing.expectEqual(Why.misfit, out[0].why);

    try std.testing.expect(holds_kind(.texts, "media", true));
    try std.testing.expect(!holds_kind(.text, "media", true));
    try std.testing.expect(holds_kind(.money, "money", false));
    try std.testing.expect(!holds_kind(.integer, "money", false));
}

test "contracts: an internal record's fields are checked by kind like a content record's" {
    const inventory: Provider = .{
        .plugin = "inventory",
        .version = "0.2.0",
        .operations = &.{},
        .records = &.{.{
            .name = "inventory.stock",
            .fields = &.{
                .{
                    .name = "variant",
                    .kind = "string",
                },
                .{
                    .name = "on_hand",
                    .kind = "string",
                },
            },
        }},
    };
    const counted: Used = .{
        .kind = .record,
        .name = "inventory.stock",
        .fields = &.{
            .{
                .name = "variant",
                .holds = .text,
            },
            .{
                .name = "on_hand",
                .holds = .integer,
            },
        },
    };
    const user: User = .{
        .plugin = "restock",
        .depends_on = &.{},
        .compatible_with = &.{"inventory"},
        .remotes = &.{counted},
    };
    var out: [2]Finding = undefined;
    var buffer: [256]u8 = undefined;

    try std.testing.expectEqual(@as(u32, 1), check(user, &.{inventory}, &out));
    try std.testing.expectEqual(Why.field_kind, out[0].why);
    try std.testing.expectEqualStrings(
        "inventory 0.2.0 keeps on_hand on inventory.stock as string, not a whole number",
        describe(out[0], &buffer),
    );

    var missing = counted;
    missing.fields = &.{.{
        .name = "reserved",
        .holds = .integer,
    }};
    var without: User = user;
    without.remotes = &.{missing};
    try std.testing.expectEqual(@as(u32, 1), check(without, &.{inventory}, &out));
    try std.testing.expectEqual(Why.no_field, out[0].why);

    var reads_text = counted;
    reads_text.fields = &.{counted.fields[0]};
    var fitting: User = user;
    fitting.remotes = &.{reads_text};
    try std.testing.expectEqual(@as(u32, 0), check(fitting, &.{inventory}, &out));
}
