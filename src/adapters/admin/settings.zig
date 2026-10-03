//! The Settings area's door and its fixed first page: the system's own settings, the
//! site's currencies among them. Users and the modeled sections have pages of their own.
const std = @import("std");
const admin = @import("../admin.zig");
const model = @import("../../model.zig");
const registry = @import("../../server/registry.zig");
const currencies = @import("../../operations/project/currencies.zig");
const settings_nav = @import("settings_nav.zig");

const views = admin.views;
const Entry = model.money.Entry;
const page_path = "/admin/settings/system";
const currencies_path = page_path ++ "/currencies";
/// What the example column writes: 123456 minor units, `£1,234.56`.
const example_amount: i64 = 123456;

pub fn show(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    _ = try admin.require(request, response, ctx) orelse return;

    try response.redirect(.see_other, page_path);
}

pub fn system(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;

    try render(&session, .ok, .{ .tab = "general" });
}

/// The Currencies tab: the site's currencies, editable in place.
pub fn currencies_tab(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const listed = registry.SDK.dispatch(&session.ctx, currencies.Currencies, .{}) catch |err| {
        return admin.fail(&session, err, page_path);
    };
    const saved = std.mem.eql(u8, request.query(), "saved=1");

    try render(&session, .ok, .{
        .tab = "currencies",
        .entries = listed.currencies,
        .notice = if (saved) "Saved." else "",
    });
}

/// One row per currency, `currency[0].code` and its parts, the default chosen by radio;
/// a row with no code is left out.
pub fn save_currencies(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, currencies_path) orelse return;
    const session = &post.session;
    const entries = try entries_of(session.arena, &post.form);

    _ = registry.SDK.dispatch(&session.ctx, currencies.SetCurrencies, .{
        .currencies = entries,
    }) catch |err| {
        const failure = if (err == error.Failed) session.ctx.failure else null;
        const why = if (failure) |declared| declared.message else @errorName(err);

        return render(session, .unprocessable_content, .{
            .tab = "currencies",
            .entries = entries,
            .problem = why,
        });
    };

    try response.redirect(.see_other, currencies_path ++ "?saved=1");
}

fn entries_of(arena: std.mem.Allocator, form: *const admin.Form) admin.Error![]const Entry {
    std.debug.assert(form.len <= admin.form_pairs_max);

    var entries: std.ArrayList(Entry) = .empty;
    const chosen = form.text("default") orelse "0";

    for (0..currencies.currencies_max + 1) |index| {
        const code = try part(arena, form, index, "code") orelse continue;
        const decimal = try part(arena, form, index, "decimal") orelse "period";
        const thousands = try part(arena, form, index, "thousands") orelse "comma";
        const entry: Entry = .{
            .code = code,
            .symbol = try part(arena, form, index, "symbol") orelse "",
            .format = try part(arena, form, index, "format") orelse "{symbol}{amount}",
            .decimal = separator_of(decimal) orelse decimal,
            .thousands = separator_of(thousands) orelse thousands,
        };
        const index_text = try std.fmt.allocPrint(arena, "{d}", .{index});
        const first = std.mem.eql(u8, chosen, index_text);

        entries.insert(arena, if (first) 0 else entries.items.len, entry) catch {
            return error.OutOfMemory;
        };
    }

    return entries.items;
}

/// `currency[<index>].<name>`, trimmed.
fn part(
    arena: std.mem.Allocator,
    form: *const admin.Form,
    index: u64,
    comptime name: []const u8,
) admin.Error!?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(index <= currencies.currencies_max);

    const key = try std.fmt.allocPrint(arena, "currency[{d}]." ++ name, .{index});
    const value = form.text(key) orelse return null;

    return std.mem.trim(u8, value, " ");
}

/// The separators by the names the form's dropdowns post: a space or none cannot travel
/// as themselves through a trimmed form value.
const separator_names = [_][2][]const u8{
    .{ "period", "." },
    .{ "comma", "," },
    .{ "space", " " },
    .{ "apostrophe", "'" },
    .{ "none", "" },
};

fn separator_of(name: []const u8) ?[]const u8 {
    std.debug.assert(separator_names.len == model.money.thousands_separators.len);

    for (separator_names) |pair| {
        if (std.mem.eql(u8, pair[0], name)) {
            return pair[1];
        }
    }

    return null;
}

fn name_of(separator: []const u8) []const u8 {
    std.debug.assert(separator.len <= 4);

    for (separator_names) |pair| {
        if (std.mem.eql(u8, pair[1], separator)) {
            return pair[0];
        }
    }

    return separator;
}

const Shown = struct {
    tab: []const u8,
    entries: []const Entry = &.{},
    notice: []const u8 = "",
    problem: []const u8 = "",
};

fn render(session: *admin.Session, status: admin.Status, shown: Shown) admin.Error!void {
    std.debug.assert(shown.entries.len <= currencies.currencies_max + 1);
    std.debug.assert(session.signed_in());

    const shell = admin.shell_of(session);
    const arena = session.arena;
    const rows = try arena.alloc(views.SettingsSystem.CurrenciesItem, shown.entries.len);
    const digits = try arena.alloc(views.SettingsSystem.DigitsItem, model.currency.all.len);

    for (rows, shown.entries, 0..) |*row, entry, index| {
        row.* = try row_of(arena, entry, @intCast(index));
    }

    for (digits, model.currency.all) |*item, currency| {
        item.* = .{ .code = currency.code, .digits = @floatFromInt(currency.digits) };
    }

    try admin.render.page(session.response, arena, status, views.SettingsSystem, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .can_structure = shell.can_structure,
        .can_settings = shell.can_settings,
        .top_bar = shell.top_bar,
        .csrf = shell.csrf,
        .nav = try settings_nav.node(session, "system"),
        .tab = shown.tab,
        .can_logs = registry.SDK.may(&session.ctx, @import("../../operations/activity.zig").List),
        .action = currencies_path,
        .currencies = rows,
        .digits = if (std.mem.eql(u8, shown.tab, "currencies")) digits else &.{},
        .notice = shown.notice,
        .problem = shown.problem,
    });
}

fn row_of(
    arena: std.mem.Allocator,
    entry: Entry,
    index: u32,
) admin.Error!views.SettingsSystem.CurrenciesItem {
    std.debug.assert(index <= currencies.currencies_max + 1);

    const known = model.currency.find(entry.code) != null;
    const valid = known and model.money.entry_problem(entry) == null;
    var buffer: [96]u8 = undefined;
    const example = if (valid)
        try arena.dupe(u8, model.money.format(&buffer, example_amount, entry))
    else
        "";

    return .{
        .index = @floatFromInt(index),
        .code = entry.code,
        .symbol = entry.symbol,
        .format = entry.format,
        .decimal = name_of(entry.decimal),
        .thousands = name_of(entry.thousands),
        .example = example,
    };
}

test "currencies under system settings: shown, saved with a new default, refused in words" {
    const sdk = @import("../../sdk.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var flow: admin.Flow = .{ .inner = undefined };
    flow.inner.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena);

    var system_ctx = harness.ctx(.system);
    try registry.SDK.bootstrap(&system_ctx);
    const setup_body = "email=ada%40example.com&display_name=Ada&password=correct+horse+battery";
    _ = try flow.call("POST", "/admin/setup", setup_body);

    const empty = try flow.call("GET", currencies_path, "");
    try std.testing.expectEqual(.ok, empty.status);
    try std.testing.expect(std.mem.indexOf(u8, empty.body, "Add currency") != null);
    const csrf = flow.csrf_of(empty.body);

    const body = try std.fmt.allocPrint(arena, "csrf={s}&default=1" ++
        "&currency%5B0%5D.code=GBP&currency%5B0%5D.symbol=%C2%A3" ++
        "&currency%5B1%5D.code=EUR&currency%5B1%5D.symbol=%E2%82%AC" ++
        "&currency%5B1%5D.format=%7Bamount%7D+%7Bsymbol%7D" ++
        "&currency%5B1%5D.decimal=comma&currency%5B1%5D.thousands=space", .{csrf});
    const saved = try flow.call("POST", currencies_path, body);
    try std.testing.expectEqualStrings(currencies_path ++ "?saved=1", saved.header("Location").?);

    const listed = try registry.SDK.dispatch(&system_ctx, currencies.Currencies, .{});
    try std.testing.expectEqualStrings("EUR", listed.currencies[0].code);
    try std.testing.expectEqualStrings(" ", listed.currencies[0].thousands);

    const shown = try flow.call("GET", currencies_path ++ "?saved=1", "");
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "1 234,56 €") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "£1,234.56") != null);

    const odd = try std.fmt.allocPrint(arena, "csrf={s}&currency%5B0%5D.code=ZZZ", .{csrf});
    const refused = try flow.call("POST", currencies_path, odd);
    try std.testing.expectEqual(.unprocessable_content, refused.status);
    try std.testing.expect(std.mem.indexOf(u8, refused.body, "ZZZ: a currency is") != null);
}
