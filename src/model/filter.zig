//! The filters of the content list: what can be asked of the content beyond its type,
//! each with the operators that make sense for it, what each operator takes after it (a
//! choice, a duration, a day), and how a clause of it constrains the list. The core set is
//! here; a plugin declares its own the same way; the app merges them into one registry
//! the admin draws its pills from and `record.list` filters by.
const std = @import("std");
const time = @import("../lib/time.zig");
const model_app = @import("app.zig");

pub const Error = error{Invalid};

/// One filter in force: `status is draft`, `updated within 7d`. An empty value is the
/// filter shown with nothing chosen yet ("any"), which constrains nothing.
pub const Clause = struct {
    key: []const u8,
    operator: []const u8,
    value: []const u8 = "",
};

/// Who asks and when: what `me` and a duration resolve against.
pub const Context = struct { user_id: ?[]const u8, now_ms: i64 };

/// Who created or last saved a record: this user, or (`exclude`) anyone but this user.
pub const Author = struct { id: []const u8, exclude: bool = false };

/// Which app's records: one app's (by its `.name`), or the project's own.
pub const App = union(enum) { none, name: []const u8 };

/// What the clauses of a list add up to: everything the store can be asked beyond the
/// types and the search. A plugin's filter sets these too; a constraint the store cannot
/// take yet is a constraint to add here first.
pub const Constraints = struct {
    status: ?[]const u8 = null,
    status_exclude: bool = false,
    changed: ?bool = null,
    created_by: ?Author = null,
    updated_by: ?Author = null,
    created_after_ms: ?i64 = null,
    created_before_ms: ?i64 = null,
    updated_after_ms: ?i64 = null,
    updated_before_ms: ?i64 = null,
    app: ?App = null,
};

/// How a filter constrains the list: its clause, resolved against the context, written
/// into the constraints. `Invalid` for a value the operator cannot take.
pub const Apply = *const fn (clause: Clause, context: Context, out: *Constraints) Error!void;

pub const key_len_max: u32 = 64;
pub const operator_len_max: u32 = 32;
pub const value_len_max: u32 = 256;
pub const filters_max: u32 = 64;
pub const operators_max: u32 = 8;

/// What an operator takes after it.
pub const Takes = enum { choice, duration, day, nothing };

/// Where a `choice` operator's choices come from.
pub const Source = enum { none, statuses, users, changes, apps };

pub const Operator = struct {
    id: []const u8,
    label: []const u8,
    takes: Takes,
    /// What the operator settles: two clauses of one filter may stand together when their
    /// operators settle different things (`by` someone and `within` a while), and not when
    /// they settle the same one (`within` and `after` are both a lower bound).
    slot: []const u8 = "value",
};

pub const Definition = struct {
    key: []const u8,
    label: []const u8,
    /// In the order offered; the first is what a fresh pill starts with.
    operators: []const Operator,
    source: Source = .none,
    /// What a fresh pill starts with, under the first operator; empty for "any".
    default_value: []const u8 = "",
    apply: Apply,

    pub fn operator(def: Definition, id: []const u8) ?Operator {
        std.debug.assert(def.operators.len > 0);
        std.debug.assert(def.operators.len <= operators_max);

        for (def.operators) |candidate| {
            if (std.mem.eql(u8, candidate.id, id)) {
                return candidate;
            }
        }

        return null;
    }
};

pub const Choice = struct { id: []const u8, label: []const u8 };

pub const is: Operator = .{ .id = "is", .label = "is", .takes = .choice };
pub const is_not: Operator = .{ .id = "not", .label = "is not", .takes = .choice };
pub const are: Operator = .{ .id = "is", .label = "are", .takes = .choice };
pub const by: Operator = .{ .id = "by", .label = "by", .takes = .choice, .slot = "author" };
pub const within: Operator = .{
    .id = "within",
    .label = "in the last",
    .takes = .duration,
    .slot = "since",
};
pub const after: Operator = .{ .id = "after", .label = "after", .takes = .day, .slot = "since" };
pub const before: Operator = .{ .id = "before", .label = "before", .takes = .day, .slot = "until" };
pub const project_own: Operator = .{ .id = "none", .label = "is none", .takes = .nothing };

pub const core = [_]Definition{
    .{
        .key = "status",
        .label = "Status",
        .operators = &.{ is, is_not },
        .source = .statuses,
        .apply = &apply_status,
    },
    .{
        .key = "changed",
        .label = "Changes",
        .operators = &.{are},
        .source = .changes,
        .default_value = "pending",
        .apply = &apply_changed,
    },
    .{
        .key = "created",
        .label = "Created",
        .operators = &.{ by, within, after, before },
        .source = .users,
        .default_value = "me",
        .apply = &apply_created,
    },
    .{
        .key = "updated",
        .label = "Updated",
        .operators = &.{ by, within, after, before },
        .source = .users,
        .default_value = "me",
        .apply = &apply_updated,
    },
    .{
        .key = "app",
        .label = "App",
        .operators = &.{ is, project_own },
        .source = .apps,
        .apply = &apply_app,
    },
};

fn apply_status(clause: Clause, context: Context, out: *Constraints) Error!void {
    std.debug.assert(std.mem.eql(u8, clause.key, "status"));
    std.debug.assert(context.now_ms >= 0);

    if (clause.value.len == 0) {
        return;
    }

    out.status = clause.value;
    out.status_exclude = std.mem.eql(u8, clause.operator, is_not.id);
}

fn apply_changed(clause: Clause, context: Context, out: *Constraints) Error!void {
    std.debug.assert(std.mem.eql(u8, clause.key, "changed"));
    std.debug.assert(context.now_ms >= 0);

    if (clause.value.len == 0) {
        return;
    }

    if (std.mem.eql(u8, clause.value, changes[0].id)) {
        out.changed = true;
    } else if (std.mem.eql(u8, clause.value, changes[1].id)) {
        out.changed = false;
    } else {
        return error.Invalid;
    }
}

/// Who created a record, or when: `by` someone, `within` a while, `after` or `before` a day.
fn apply_created(clause: Clause, context: Context, out: *Constraints) Error!void {
    std.debug.assert(std.mem.eql(u8, clause.key, "created"));
    std.debug.assert(context.now_ms >= 0);

    const moment = try moment_of(clause, context);

    if (moment.author) |author| {
        out.created_by = author;
    }

    if (moment.after_ms) |after_ms| {
        out.created_after_ms = after_ms;
    }

    if (moment.before_ms) |before_ms| {
        out.created_before_ms = before_ms;
    }
}

/// Who last saved a record, or when.
fn apply_updated(clause: Clause, context: Context, out: *Constraints) Error!void {
    std.debug.assert(std.mem.eql(u8, clause.key, "updated"));
    std.debug.assert(context.now_ms >= 0);

    const moment = try moment_of(clause, context);

    if (moment.author) |author| {
        out.updated_by = author;
    }

    if (moment.after_ms) |after_ms| {
        out.updated_after_ms = after_ms;
    }

    if (moment.before_ms) |before_ms| {
        out.updated_before_ms = before_ms;
    }
}

/// `app:is:www`, one app's records; `app:none`, the project's own.
fn apply_app(clause: Clause, context: Context, out: *Constraints) Error!void {
    std.debug.assert(std.mem.eql(u8, clause.key, "app"));
    std.debug.assert(context.now_ms >= 0);

    if (std.mem.eql(u8, clause.operator, project_own.id)) {
        out.app = .none;
        return;
    }

    if (clause.value.len == 0) {
        return;
    }

    if (!model_app.valid_name(clause.value)) {
        return error.Invalid;
    }

    out.app = .{ .name = clause.value };
}

const Moment = struct { author: ?Author = null, after_ms: ?i64 = null, before_ms: ?i64 = null };

/// `by me` is whoever asks (nobody asking means nobody to be); `within 7d` is since seven
/// days ago; `after` and `before` name a day, the day itself counted in for `after` and
/// out for `before`.
fn moment_of(clause: Clause, context: Context) Error!Moment {
    std.debug.assert(clause.key.len > 0);
    std.debug.assert(context.now_ms >= 0);

    if (clause.value.len == 0) {
        return .{};
    }

    if (std.mem.eql(u8, clause.operator, by.id)) {
        const id = if (std.mem.eql(u8, clause.value, me.id))
            context.user_id orelse return error.Invalid
        else
            clause.value;

        return .{ .author = .{ .id = id } };
    }

    if (std.mem.eql(u8, clause.operator, within.id)) {
        const span = duration_ms(clause.value) orelse return error.Invalid;

        return .{ .after_ms = @max(0, context.now_ms - span) };
    }

    const day = day_ms(clause.value) orelse return error.Invalid;

    if (std.mem.eql(u8, clause.operator, after.id)) {
        return .{ .after_ms = day };
    }

    if (std.mem.eql(u8, clause.operator, before.id)) {
        return .{ .before_ms = day };
    }

    return error.Invalid;
}

/// `key:operator:value`, as a clause travels on a command line; the value may be empty.
pub fn parse_clause(text: []const u8) ?Clause {
    std.debug.assert(value_len_max > 0);

    const first = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const rest = text[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
    const clause: Clause = .{
        .key = text[0..first],
        .operator = rest[0..second],
        .value = if (second < rest.len) rest[second + 1 ..] else "",
    };

    if (clause.key.len == 0 or clause.key.len > key_len_max) {
        return null;
    }

    if (clause.operator.len == 0 or clause.operator.len > operator_len_max) {
        return null;
    }

    return if (clause.value.len <= value_len_max) clause else null;
}

/// The choices of the `changes` source.
pub const changes = [_]Choice{
    .{ .id = "pending", .label = "Pending" },
    .{ .id = "none", .label = "None" },
};

/// The durations offered to an operator that takes one.
pub const durations = [_]Choice{
    .{ .id = "24h", .label = "24 hours" },
    .{ .id = "7d", .label = "7 days" },
    .{ .id = "30d", .label = "30 days" },
    .{ .id = "90d", .label = "90 days" },
};

/// The user who asks, as a choice of the `users` source.
pub const me: Choice = .{ .id = "me", .label = "Me" };

/// `24h` or `7d` as milliseconds; null when it is neither.
pub fn duration_ms(text: []const u8) ?i64 {
    std.debug.assert(value_len_max > 0);

    if (text.len < 2 or text.len > 8) {
        return null;
    }

    const count = std.fmt.parseInt(i64, text[0 .. text.len - 1], 10) catch return null;

    if (count <= 0) {
        return null;
    }

    return switch (text[text.len - 1]) {
        'h' => count * 3_600_000,
        'd' => count * 86_400_000,
        else => null,
    };
}

/// `YYYY-MM-DD` as the milliseconds its UTC day starts at; null when it is not a day.
pub fn day_ms(text: []const u8) ?i64 {
    std.debug.assert(value_len_max > 0);

    return time.parse_date(text);
}

/// Whether a value is one the operator takes; the empty value is "any" for a choice and
/// "not yet given" for a duration or a day.
pub fn fits(operator: Operator, value: []const u8) bool {
    std.debug.assert(operator.id.len > 0);

    if (value.len > value_len_max) {
        return false;
    }

    if (value.len == 0) {
        return true;
    }

    return switch (operator.takes) {
        .choice => true,
        .duration => duration_ms(value) != null,
        .day => day_ms(value) != null,
        .nothing => false,
    };
}

pub fn Registry(comptime filters: []const Definition) type {
    comptime validate(filters);

    return struct {
        pub const all = filters;

        pub fn find(key: []const u8) ?Definition {
            comptime std.debug.assert(filters.len > 0);

            for (filters) |def| {
                if (std.mem.eql(u8, def.key, key)) {
                    return def;
                }
            }

            return null;
        }

        /// A clause checked against its filter (known key, known operator, a value the
        /// operator takes) and applied to the constraints.
        pub fn apply(clause: Clause, context: Context, out: *Constraints) Error!void {
            comptime std.debug.assert(filters.len > 0);
            std.debug.assert(context.now_ms >= 0);

            const def = find(clause.key) orelse return error.Invalid;
            const operator = def.operator(clause.operator) orelse return error.Invalid;

            if (!fits(operator, clause.value)) {
                return error.Invalid;
            }

            try def.apply(clause, context, out);
        }

        /// Every clause checked and applied; two clauses of one filter settling the same
        /// thing are refused.
        pub fn apply_all(clauses: []const Clause, context: Context, out: *Constraints) Error!void {
            comptime std.debug.assert(filters.len > 0);
            std.debug.assert(context.now_ms >= 0);

            if (clauses.len > filters_max) {
                return error.Invalid;
            }

            for (clauses, 0..) |clause, index| {
                for (clauses[index + 1 ..]) |other| {
                    if (clash(clause, other)) {
                        return error.Invalid;
                    }
                }

                try apply(clause, context, out);
            }
        }

        /// Whether two clauses cannot stand together: one filter, operators settling the
        /// same thing. A clause of a filter or an operator unknown clashes with nothing;
        /// `apply` refuses it on its own.
        pub fn clash(left: Clause, right: Clause) bool {
            comptime std.debug.assert(filters.len > 0);

            if (!std.mem.eql(u8, left.key, right.key)) {
                return false;
            }

            const def = find(left.key) orelse return false;
            const first = def.operator(left.operator) orelse return false;
            const second = def.operator(right.operator) orelse return false;

            return std.mem.eql(u8, first.slot, second.slot);
        }
    };
}

fn validate(comptime filters: []const Definition) void {
    comptime {
        if (filters.len == 0 or filters.len > filters_max) {
            @compileError("the filter registry needs between 1 and 64 filters");
        }

        for (filters, 0..) |def, index| {
            if (def.key.len == 0 or def.key.len > key_len_max or def.label.len == 0) {
                @compileError("a filter needs a key and a label: " ++ def.key);
            }

            if (def.operators.len == 0 or def.operators.len > operators_max) {
                @compileError("a filter needs between 1 and 8 operators: " ++ def.key);
            }

            if (!fits(def.operators[0], def.default_value)) {
                @compileError("a filter's default must fit its first operator: " ++ def.key);
            }

            for (filters[index + 1 ..]) |other| {
                if (std.mem.eql(u8, def.key, other.key)) {
                    @compileError("two filters share the key " ++ def.key);
                }
            }

            for (def.operators, 0..) |operator, operator_index| {
                for (def.operators[operator_index + 1 ..]) |other| {
                    if (std.mem.eql(u8, operator.id, other.id)) {
                        @compileError("a filter lists the operator twice: " ++ operator.id);
                    }
                }
            }
        }
    }
}

test "the core registry finds its filters and their operators" {
    const Core = Registry(&core);
    const status = Core.find("status").?;
    try std.testing.expectEqualStrings("Status", status.label);
    try std.testing.expectEqual(Takes.choice, status.operator("not").?.takes);
    try std.testing.expect(status.operator("within") == null);
    try std.testing.expect(Core.find("nope") == null);
    const updated = Core.find("updated").?;
    try std.testing.expectEqual(Takes.choice, updated.operators[0].takes);
    try std.testing.expectEqual(Takes.duration, updated.operator("within").?.takes);
    try std.testing.expectEqualStrings("me", updated.default_value);
}

test "clauses parse from text and constrain the list through the registry" {
    const Core = Registry(&core);
    const day: i64 = 86_400_000;
    const context: Context = .{ .user_id = "u_1", .now_ms = 10 * day };
    var out: Constraints = .{};

    try Core.apply(parse_clause("status:not:draft").?, context, &out);
    try Core.apply(parse_clause("changed:is:pending").?, context, &out);
    try Core.apply(parse_clause("created:by:me").?, context, &out);
    try Core.apply(parse_clause("updated:within:7d").?, context, &out);
    try std.testing.expectEqualStrings("draft", out.status.?);
    try std.testing.expect(out.status_exclude);
    try std.testing.expectEqual(@as(?bool, true), out.changed);
    try std.testing.expectEqualStrings("u_1", out.created_by.?.id);
    try std.testing.expect(!out.created_by.?.exclude);
    try std.testing.expectEqual(@as(?i64, 3 * day), out.updated_after_ms);
    try Core.apply(parse_clause("created:before:1970-01-03").?, context, &out);
    try std.testing.expectEqualStrings("u_1", out.created_by.?.id);
    try std.testing.expectEqual(@as(?i64, 2 * day), out.created_before_ms);

    var both: Constraints = .{};
    try Core.apply_all(&.{
        parse_clause("created:by:me").?,
        parse_clause("created:within:7d").?,
        parse_clause("created:before:1970-01-09").?,
    }, context, &both);
    try std.testing.expectEqualStrings("u_1", both.created_by.?.id);
    try std.testing.expectEqual(@as(?i64, 3 * day), both.created_after_ms);
    try std.testing.expectEqual(@as(?i64, 8 * day), both.created_before_ms);
    const twice_since = Core.apply_all(&.{
        parse_clause("created:within:7d").?,
        parse_clause("created:after:1970-01-02").?,
    }, context, &both);
    try std.testing.expectError(error.Invalid, twice_since);
    const is_draft = parse_clause("status:is:draft").?;
    try std.testing.expect(Core.clash(is_draft, parse_clause("status:not:x").?));
    const created_by_me = parse_clause("created:by:me").?;
    try std.testing.expect(!Core.clash(created_by_me, parse_clause("updated:by:me").?));

    var untouched: Constraints = .{};
    try Core.apply(parse_clause("status:is:").?, context, &untouched);
    try Core.apply(.{ .key = "updated", .operator = "after" }, context, &untouched);
    try std.testing.expect(untouched.status == null and untouched.updated_after_ms == null);

    const nobody: Context = .{ .user_id = null, .now_ms = 0 };
    const refused = [_][]const u8{
        "status:within:7d", "nope:is:x", "updated:within:soon", "changed:is:maybe",
    };

    for (refused) |text| {
        const attempt = Core.apply(parse_clause(text).?, context, &out);
        try std.testing.expectError(error.Invalid, attempt);
    }

    const me_alone = Core.apply(parse_clause("created:by:me").?, nobody, &out);
    try std.testing.expectError(error.Invalid, me_alone);
    try std.testing.expect(parse_clause("status") == null);
    try std.testing.expect(parse_clause(":is:x") == null);
    const dated = parse_clause("created:after:2026-01-01").?;
    try std.testing.expectEqualStrings("2026-01-01", dated.value);
}

test "app: one app's records by name, or the project's own" {
    const Core = Registry(&core);
    const context: Context = .{ .user_id = "u_1", .now_ms = 0 };
    var out: Constraints = .{};

    try Core.apply(parse_clause("app:is:").?, context, &out);
    try std.testing.expect(out.app == null);
    try Core.apply(parse_clause("app:is:www").?, context, &out);
    try std.testing.expectEqualStrings("www", out.app.?.name);
    try Core.apply(parse_clause("app:none").?, context, &out);
    try std.testing.expect(out.app.? == .none);
    try std.testing.expect(Core.clash(parse_clause("app:is:www").?, parse_clause("app:none").?));
    const capital = Core.apply(parse_clause("app:is:No").?, context, &out);
    try std.testing.expectError(error.Invalid, capital);
}

test "durations, days, and what fits an operator" {
    try std.testing.expectEqual(@as(?i64, 86_400_000), duration_ms("24h"));
    try std.testing.expectEqual(@as(?i64, 7 * 86_400_000), duration_ms("7d"));
    try std.testing.expectEqual(@as(?i64, null), duration_ms("7"));
    try std.testing.expectEqual(@as(?i64, null), duration_ms("0d"));
    try std.testing.expectEqual(@as(?i64, null), duration_ms("soon"));
    try std.testing.expectEqual(@as(?i64, 0), day_ms("1970-01-01"));
    try std.testing.expect(fits(is, "draft") and fits(is, ""));
    try std.testing.expect(fits(within, "30d") and !fits(within, "2026-01-01"));
    try std.testing.expect(fits(before, "2026-01-01") and !fits(before, "7d"));
    try std.testing.expect(!fits(.{ .id = "x", .label = "x", .takes = .nothing }, "y"));
}
