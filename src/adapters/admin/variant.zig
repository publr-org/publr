//! What content shows in, in the admin: the person's own choice in each dimension (the
//! content language, an A/B test's variation), each drawn top right where its plugin names
//! a picker; what lists, the editor and the visual editor open in.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const variant_operations = @import("../../operations/user/variant.zig");
const model_dimension = @import("../../model/dimension.zig");

const Session = admin.Session;
const Node = admin.render.Node;
const Pair = model_dimension.Pair;

/// The combination content shows in for this person, as a key's suffix
/// (`language=pl,variation=b`): `<html data-variant>`, read by the editors. Empty for the
/// main values, and while the site has no dimension.
pub fn chosen(session: *Session) []const u8 {
    std.debug.assert(session.signed_in());

    const pairs = chosen_pairs(session);
    const key = model_dimension.key_of(session.arena, "_", pairs) catch return "";

    std.debug.assert(key.len >= 1);

    return if (key.len > 2) key[2..] else "";
}

/// The same choice as the combination a read asks for.
pub fn chosen_pairs(session: *Session) []const Pair {
    std.debug.assert(session.signed_in());

    return variant_operations.chosen_pairs(&session.ctx) catch &.{};
}

/// A switcher for each dimension with two values or more whose plugin names a picker.
pub fn switchers(session: *Session, out: []Node) u32 {
    std.debug.assert(session.signed_in());
    std.debug.assert(out.len > 0);

    const read = registry.SDK.dispatch(&session.ctx, variant_operations.Variant, .{}) catch {
        return 0;
    };
    var count: u32 = 0;

    for (read.dimensions) |one| {
        if (count == out.len or one.picker.len == 0 or one.values.len < 2) {
            continue;
        }

        out[count] = drawn(session, one) catch continue;
        count += 1;
    }

    return count;
}

fn drawn(session: *Session, one: variant_operations.Chosen) !Node {
    std.debug.assert(one.values.len >= 2);
    std.debug.assert(one.dimension.len > 0);

    const Choice = admin.views.VariantSwitcher.ChoicesItem;
    const choices = try session.arena.alloc(Choice, one.values.len);
    var current: []const u8 = one.values[0].label;

    for (one.values, choices) |value, *choice| {
        const code = if (value.main) "" else value.code;
        const picked = std.mem.eql(u8, code, one.chosen);

        if (picked) {
            current = value.label;
        }

        choice.* = .{
            .code = code,
            .label = value.label,
            .current = picked,
        };
    }

    return admin.render.view(session.arena, admin.views.VariantSwitcher, .{
        .dimension = one.dimension,
        .title = try session.declared(one.picker),
        .current = current,
        .choices = choices,
        .back = try back_of(session),
    });
}

/// The page the switcher sends the person back to, its query kept (`?type=promo`).
fn back_of(session: *Session) ![]const u8 {
    std.debug.assert(session.signed_in());

    const path = session.request.path();
    const query = session.request.query();

    std.debug.assert(path.len > 0);

    if (query.len == 0) {
        return path;
    }

    return std.mem.concat(session.arena, u8, &.{ path, "?", query });
}

/// `POST /admin/variant`: the person's choice in a dimension, then back where they were.
pub fn choose(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, "/admin") orelse return;
    const session = &post.session;
    const back = post.form.text("back") orelse "/admin";
    const local = back.len > 0 and back[0] == '/' and !std.mem.startsWith(u8, back, "//");

    _ = registry.SDK.dispatch(&session.ctx, variant_operations.SetVariant, .{
        .dimension = post.form.text("dimension") orelse "",
        .variant = post.form.text("variant") orelse "",
    }) catch |err| return admin.fail(session, err, "/admin");

    try response.redirect(.see_other, if (local) back else "/admin");
}
