//! `.extend`: what a built-in plugin adds past the plugin API, one call each.
//!
//! `fn extend(host: *publr.Host) publr.Error!void` runs once, as Publr is compiled, and
//! whatever it registers is read where the server reads it. Having it makes a plugin
//! built-in only: its sandboxed build leaves everything it registers out, and says so.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const routing = @import("route.zig");
const variant = @import("variants.zig");
const provider = @import("../provider.zig");
const db = @import("../../lib/db.zig");

pub const Error = sdk.Error;

/// SQL on the plugin's own tables, inside the call's transaction: `ctx.database()`.
pub const Database = struct {
    connection: *db.Db,

    /// Runs `sql` with each `?` taken from `values` in order: text, an integer, a bool, a
    /// `publr.Time`, or null.
    pub fn exec(database: Database, comptime sql: []const u8, values: anytype) Error!void {
        comptime std.debug.assert(sql.len > 0);

        var statement = try database.prepare(sql, values);
        defer statement.finalize();

        try statement.exec();
    }

    /// `sql` ready to step through, its `?` filled from `values`.
    pub fn prepare(
        database: Database,
        comptime sql: []const u8,
        values: anytype,
    ) Error!db.Statement {
        comptime std.debug.assert(sql.len > 0);
        comptime std.debug.assert(values.len < 1 << 15);

        var statement = try database.connection.prepare(sql);
        errdefer statement.finalize();

        inline for (values, 1..) |value, index| {
            try bind(&statement, index, value);
        }

        return statement;
    }

    fn bind(statement: *db.Statement, index: u31, value: anytype) Error!void {
        std.debug.assert(index > 0);

        const Value = @TypeOf(value);

        switch (@typeInfo(Value)) {
            .int, .comptime_int => try statement.bind_int(index, @intCast(value)),
            .bool => try statement.bind_int(index, @intFromBool(value)),
            .null => try statement.bind_null(index),
            .optional => if (value) |given| {
                try bind(statement, index, given);
            } else {
                try statement.bind_null(index);
            },
            .@"struct" => try statement.bind_int(index, value.ms),
            else => try statement.bind_text(index, value),
        }
    }
};

/// A table of the plugin's own, named under it (`shipping_shipments`): `schema` is the one
/// `CREATE TABLE` making it, with its indexes. Read and written with `ctx.database()`.
pub const Table = struct {
    name: []const u8,
    schema: []const u8,
};

/// What the server reads under one name, one value each: a type holding it as `value`.
const Given = struct {
    State: ?type = null,
    bootstrap: ?type = null,
    serving: ?type = null,
    before_command: ?type = null,
    sign_in_provider: ?type = null,
    sign_in_at: ?type = null,
    variants: ?type = null,
    admin_brand: ?type = null,
    app_picker_segment: ?type = null,
    work_start: ?type = null,
    hosted: ?type = null,
};

/// What the server reads as a list.
const Lists = struct {
    routes: void,
    operator_commands: void,
    policies: void,
    delivery_gates: void,
};

pub const Host = struct {
    tables: []const Table = &.{},
    routes: []const routing.Route = &.{},
    operator_commands: []const routing.OperatorCommand = &.{},
    policies: []const sdk.Policy = &.{},
    delivery_gates: []const sdk.delivery.Gate = &.{},
    middlewares: []const type = &.{},
    given: Given = .{},

    /// A table of the plugin's own.
    pub fn table(host: *Host, comptime made: Table) Error!void {
        // The schema searched twice: a table of each byte, then a pass over the schema.
        @setEvalBranchQuota(2000 + made.schema.len * 16);

        const one = std.mem.count(u8, made.schema, "CREATE TABLE") == 1 and
            std.mem.indexOf(u8, made.schema, made.name) != null;

        if (!one) {
            @compileError("host.table " ++ made.name ++ ": its schema is one `CREATE TABLE " ++
                made.name ++ "`, with its indexes");
        }

        host.tables = host.tables ++ &[_]Table{made};
    }

    /// An HTTP route under `/admin/<own>`, `/api/<own>` or `/auth/<own>`.
    pub fn route(host: *Host, comptime answered: routing.Route) Error!void {
        host.routes = host.routes ++ &[_]routing.Route{answered};
    }

    /// The state the plugin keeps for the life of the process: a struct, with `init` and
    /// `deinit` when it has them.
    pub fn state(host: *Host, comptime State: type) Error!void {
        host.give("State", State);
    }

    /// What the CLI beside a running server asks it with the operator key.
    pub fn operator_command(host: *Host, comptime command: routing.OperatorCommand) Error!void {
        host.operator_commands = host.operator_commands ++ &[_]routing.OperatorCommand{command};
    }

    /// Runs once, as the system, when the database opens.
    pub fn bootstrap(host: *Host, comptime run: fn (*sdk.Ctx) sdk.Error!void) Error!void {
        host.give("bootstrap", run);
    }

    /// Runs as `serve` starts listening: `fn (publr.plugin_hooks.Serving) anyerror!void`.
    pub fn serving(host: *Host, comptime run: anytype) Error!void {
        host.give("serving", run);
    }

    /// Runs before every command: `fn (*publr.plugin_hooks.Command) anyerror!void`.
    pub fn before_command(host: *Host, comptime run: anytype) Error!void {
        host.give("before_command", run);
    }

    /// A "Continue with X" button on the login pages.
    pub fn sign_in_provider(host: *Host, comptime declared: provider.SignInProvider) Error!void {
        host.give("sign_in_provider", declared);
    }

    /// Where someone who must sign in is sent instead of the form.
    pub fn sign_in_at(host: *Host, comptime run: anytype) Error!void {
        host.give("sign_in_at", run);
    }

    /// The variant dimension: what makes a field hold a value per variant.
    pub fn variants(host: *Host, comptime dimension: variant.Dimension) Error!void {
        host.give("variants", dimension);
    }

    /// Whose admin it is: its name and mark.
    pub fn admin_brand(host: *Host, comptime run: anytype) Error!void {
        host.give("admin_brand", run);
    }

    /// A segment of the admin's app picker.
    pub fn app_picker_segment(host: *Host, comptime run: anytype) Error!void {
        host.give("app_picker_segment", run);
    }

    /// The operation `publr work start` calls: one of the plugin's own, by its definition.
    pub fn work_start(host: *Host, comptime Operation: type) Error!void {
        host.give("work_start", Operation);
    }

    /// The site runs on Publr Cloud.
    pub fn hosted(host: *Host) Error!void {
        host.give("hosted", true);
    }

    /// A gate every page and asset passes before it is served.
    pub fn delivery_gate(host: *Host, comptime gate: sdk.delivery.Gate) Error!void {
        host.delivery_gates = host.delivery_gates ++ &[_]sdk.delivery.Gate{gate};
    }

    /// A rule on who may call operations, beside each operation's own.
    pub fn policy(host: *Host, comptime given: sdk.Policy) Error!void {
        host.policies = host.policies ++ &[_]sdk.Policy{given};
    }

    /// What no hook says: a hook on every operation before it runs (`.pre`), or on every
    /// event inside the write (`.on` naming no `event`).
    pub fn middleware(host: *Host, comptime Middleware: type) Error!void {
        const every_operation = Middleware.stage == .pre;
        const every_event = Middleware.stage == .on and !@hasDecl(Middleware, "event");

        if (!every_operation and !every_event) {
            @compileError("`" ++ @typeName(Middleware) ++ "` belongs in `.hooks`: " ++
                "`publr.before`, `publr.after`, `publr.on` or `publr.modify`");
        }

        host.middlewares = host.middlewares ++ &[_]type{Middleware};
    }

    fn give(host: *Host, comptime name: []const u8, comptime registered: anytype) void {
        if (@field(host.given, name) != null) {
            @compileError("host." ++ name ++ " is given once");
        }

        @field(host.given, name) = struct {
            pub const value = registered;
        };
    }

    /// Whether `.extend` registered what the server reads as `name`.
    pub fn has(comptime host: Host, comptime name: []const u8) bool {
        comptime {
            std.debug.assert(seam(name));

            if (std.mem.eql(u8, name, "schema_sql")) {
                return host.tables.len > 0;
            }

            if (@hasField(Lists, name)) {
                return @field(host, name).len > 0;
            }

            return @field(host.given, name) != null;
        }
    }

    /// What `.extend` registered as `name`.
    pub fn get(comptime host: Host, comptime name: []const u8) Got(host, name) {
        comptime {
            std.debug.assert(host.has(name));

            if (std.mem.eql(u8, name, "schema_sql")) {
                var sql: []const u8 = "";

                for (host.tables) |made| {
                    sql = sql ++ made.schema ++ "\n";
                }

                const ended = sql ++ "\x00";

                return ended[0 .. ended.len - 1 :0];
            }

            if (@hasField(Lists, name)) {
                return @field(host, name);
            }

            return @field(host.given, name).?.value;
        }
    }

    pub fn Got(comptime host: Host, comptime name: []const u8) type {
        if (std.mem.eql(u8, name, "schema_sql")) {
            return [:0]const u8;
        }

        if (@hasField(Lists, name)) {
            return @TypeOf(@field(host, name));
        }

        return @TypeOf(@field(host.given, name).?.value);
    }
};

/// Whether the server reads `name` from `.extend`.
pub fn seam(comptime name: []const u8) bool {
    return @hasField(Given, name) or @hasField(Lists, name) or
        std.mem.eql(u8, name, "schema_sql");
}

/// Runs a plugin's `extend` and keeps what it registered.
pub fn extended(comptime plugin: []const u8, comptime extend: anytype) Host {
    comptime {
        std.debug.assert(plugin.len > 0);

        var host: Host = .{};

        extend(&host) catch |err| {
            @compileError("plugin " ++ plugin ++ ": `.extend` failed: " ++ @errorName(err));
        };

        for (host.tables) |made| {
            const own = std.mem.eql(u8, made.name, plugin) or
                std.mem.startsWith(u8, made.name, plugin ++ "_");

            if (!own) {
                @compileError("plugin " ++ plugin ++ ": table " ++ made.name ++
                    " is named under its plugin: `" ++ plugin ++ "` or `" ++ plugin ++ "_...`");
            }
        }

        const done = host;

        return done;
    }
}

test "what extend registers is read under the server's names" {
    const Plugin = struct {
        fn extend(host: *Host) Error!void {
            std.debug.assert(host.tables.len == 0);

            try host.table(.{
                .name = "shipping_shipments",
                .schema = "CREATE TABLE shipping_shipments (id INTEGER PRIMARY KEY) STRICT;",
            });
            try host.state(struct {
                count: u32 = 0,
            });
            try host.hosted();
        }
    };
    const host = comptime extended("shipping", Plugin.extend);

    try std.testing.expect(comptime host.has("schema_sql"));
    try std.testing.expect(comptime host.has("State"));
    try std.testing.expect(comptime host.get("hosted"));
    try std.testing.expect(comptime !host.has("routes"));
    try std.testing.expect(comptime !host.has("sign_in_at"));

    const sql = comptime host.get("schema_sql");

    try std.testing.expect(std.mem.startsWith(u8, sql, "CREATE TABLE shipping_shipments"));
}

test "ctx.database() runs SQL on the plugin's own table, values bound in order" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const database: Database = .{
        .connection = ctx.db,
    };

    try ctx.db.exec("CREATE TABLE shipping_shipments (carrier TEXT, sent_at INTEGER, note TEXT)");
    try database.exec(
        "INSERT INTO shipping_shipments (carrier, sent_at, note) VALUES (?, ?, ?)",
        .{ "inpost", @as(i64, 42), null },
    );

    var select = try database.prepare(
        "SELECT sent_at FROM shipping_shipments WHERE carrier = ?",
        .{"inpost"},
    );
    defer select.finalize();

    try std.testing.expect(try select.step());
    try std.testing.expectEqual(@as(i64, 42), select.read_int());
}
