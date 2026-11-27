//! `.extend`: what a built-in plugin adds past the plugin API, one call each.
//!
//! `fn extend(host: *publr.Host) publr.Error!void` runs once, as Publr is compiled, and
//! whatever it registers is read where the server reads it. Having it makes a plugin
//! built-in only: its sandboxed build leaves everything it registers out, and says so.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const routing = @import("route.zig");
const Ctx = @import("../ctx.zig").Ctx;
const policy_module = @import("policy.zig");
const delivery = @import("delivery.zig");
const sign_in = @import("sign_in.zig");
const admin = @import("admin.zig");

pub const Error = @import("../operation.zig").Error;

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
    admin_brand: ?type = null,
    app_picker_segment: ?type = null,
    copies: ?type = null,
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
    /// A built-in plugin's own request out that gives up after a time limit.
    pub const timed = @import("timed.zig");
    /// Unix milliseconds now, for code outside any call (a route, a process hook); inside
    /// one, `ctx.now()`.
    pub const wall_clock_ms = @import("clock.zig").wall_clock_ms;
    /// What `before_command` and `serving` are given.
    pub const Command = @import("process.zig").Command;
    pub const Serving = @import("process.zig").Serving;
    pub const Process = @import("process.zig").Process;
    pub const Server = @import("process.zig").Server;
    /// What `route` and `operator_command` take, and what their handlers are given.
    pub const Route = routing.Route;
    pub const OperatorCommand = routing.OperatorCommand;
    pub const Handler = routing.Handler;
    pub const Stream = routing.Stream;
    pub const Request = routing.Request;
    pub const Response = routing.Response;
    pub const Context = routing.Context;
    pub const Status = routing.Status;
    pub const HttpError = routing.Error;
    /// What `policy`, `delivery_gate` and `sign_in_provider` take.
    pub const Policy = policy_module.Policy;
    pub const PolicyView = policy_module.View;
    pub const PolicyRequest = policy_module.Request;
    pub const PolicyGrant = policy_module.Grant;
    pub const Gate = delivery.Gate;
    pub const Delivery = delivery.Delivery;
    pub const Verdict = delivery.Verdict;
    pub const Refusal = delivery.Refusal;
    pub const SignInProvider = sign_in.SignInProvider;
    pub const Claims = sign_in.Claims;
    pub const Callback = sign_in.Callback;
    pub const Authorize = sign_in.Authorize;
    pub const FromRequest = sign_in.FromRequest;
    /// `ctx.database()`: SQL on the plugin's own tables.
    pub const Database = @import("database.zig").Database;
    pub const Statement = @import("database.zig").Statement;
    pub const Databases = @import("database.zig").Databases;
    /// A built-in plugin's own admin screens, in the admin's chrome.
    pub const admin_pages = @import("admin_page.zig");
    /// What `admin_brand` answers.
    pub const AdminBrand = admin.AdminBrand;

    tables: []const Table = &.{},
    routes: []const routing.Route = &.{},
    operator_commands: []const routing.OperatorCommand = &.{},
    policies: []const policy_module.Policy = &.{},
    delivery_gates: []const delivery.Gate = &.{},
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
    pub fn bootstrap(host: *Host, comptime run: fn (*Ctx) Error!void) Error!void {
        host.give("bootstrap", run);
    }

    /// Runs as `serve` starts listening: `fn (publr.Host.Serving) anyerror!void`.
    pub fn serving(host: *Host, comptime run: anytype) Error!void {
        host.give("serving", run);
    }

    /// Runs before every command: `fn (*publr.Host.Command) anyerror!void`.
    pub fn before_command(host: *Host, comptime run: anytype) Error!void {
        host.give("before_command", run);
    }

    /// A "Continue with X" button on the login pages.
    pub fn sign_in_provider(host: *Host, comptime declared: sign_in.SignInProvider) Error!void {
        host.give("sign_in_provider", declared);
    }

    /// Where someone who must sign in is sent instead of the form.
    pub fn sign_in_at(host: *Host, comptime run: admin.SignInAt) Error!void {
        host.give("sign_in_at", run);
    }

    /// Whose admin it is: its name and mark.
    pub fn admin_brand(host: *Host, comptime run: admin.Brand) Error!void {
        host.give("admin_brand", run);
    }

    /// A segment of the admin's app picker: the plugin's view `View` (one of
    /// `publr.views.all`), drawn with what `props` answers for the person signed in (null:
    /// no segment for them). Core fills what the picker knows itself, when `View.Props` has
    /// it: `attached` (joined to the app picker), `apps` (on a phone, the list of apps the
    /// segment stands in for) and `csrf` (the session's token for a form it posts).
    pub fn app_picker_segment(
        host: *Host,
        comptime View: type,
        comptime props: fn (ctx: *Ctx, attached: bool) anyerror!?View.Props,
    ) Error!void {
        comptime std.debug.assert(@hasDecl(View, "render"));

        host.give("app_picker_segment", struct {
            pub const Drawn = View;
            pub const props_of = props;
        });
    }

    /// This site keeps copies of itself, listed by this operation of the plugin's own.
    pub fn copies(host: *Host, comptime Operation: type) Error!void {
        host.give("copies", Operation);
    }

    /// The site runs on Publr Cloud.
    pub fn hosted(host: *Host) Error!void {
        host.give("hosted", true);
    }

    /// A gate every page and asset passes before it is served.
    pub fn delivery_gate(host: *Host, comptime gate: delivery.Gate) Error!void {
        host.delivery_gates = host.delivery_gates ++ &[_]delivery.Gate{gate};
    }

    /// A rule on who may call operations, beside each operation's own.
    pub fn policy(host: *Host, comptime given: policy_module.Policy) Error!void {
        host.policies = host.policies ++ &[_]policy_module.Policy{given};
    }

    /// What no hook says: a hook on every operation before it runs (`.pre`), or on every
    /// operation's end, nested ones too, in the process that ran it (`.on` naming no
    /// `event`: a deployment closes once the write committed).
    pub fn middleware(host: *Host, comptime Middleware: type) Error!void {
        const every_operation = Middleware.stage == .pre;
        const every_end = Middleware.stage == .on and !@hasDecl(Middleware, "event");

        if (!every_operation and !every_end) {
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

/// Whether `name` is a list `.extend` registers.
pub fn listed(comptime name: []const u8) bool {
    return @hasField(Lists, name);
}

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
    const Database = @import("database.zig").Database;
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

test "every admin page call compiles" {
    const pages = Host.admin_pages;

    _ = &pages.require;
    _ = &pages.accept;
    _ = &pages.query_value;
    _ = &pages.time_text;
    _ = &pages.Page.ctx;
    _ = &pages.Page.arena;
    _ = &pages.Page.csrf_token;
    _ = &pages.Page.param;
    _ = &pages.Page.query_param;
    _ = &pages.Page.fail;
    _ = &pages.Page.message;
    _ = &pages.Form.text;
    _ = &Host.Server.system;
    _ = &Host.Server.reload_apps;
    _ = &Host.Server.set_session_cookie;
    _ = &Host.Databases.open;
    _ = &Host.Database.close;
    _ = &Host.Database.run;

    try std.testing.expect(@hasDecl(pages, "require"));
}
