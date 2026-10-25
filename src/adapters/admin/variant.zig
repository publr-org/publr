//! The content language in the admin (generally, the variant): the person's own choice,
//! drawn top right where the plugin declaring variants names the picker; what lists, the
//! editor and the visual editor open in.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const variant_operations = @import("../../operations/user/variant.zig");
const variants = @import("../../operations/variants.zig");

const Session = admin.Session;
const Node = admin.render.Node;

/// The code content shows in for this person; empty for the main variant, and while the
/// site has no variants.
pub fn chosen(session: *Session) []const u8 {
    std.debug.assert(session.signed_in());

    const read = registry.SDK.dispatch(&session.ctx, variant_operations.Variant, .{}) catch {
        return "";
    };

    return read.chosen;
}

/// The switcher, where the site has two variants or more and the dimension names a picker.
pub fn switcher(session: *Session) ?Node {
    std.debug.assert(session.signed_in());

    const dimension = variants.setting(&session.ctx) orelse return null;

    if (dimension.picker.len == 0) {
        return null;
    }

    const read = registry.SDK.dispatch(&session.ctx, variant_operations.Variant, .{}) catch {
        return null;
    };

    if (read.variants.len < 2) {
        return null;
    }

    return drawn(session, dimension.picker, read) catch null;
}

fn drawn(session: *Session, picker: []const u8, read: variant_operations.Variant.Out) !Node {
    std.debug.assert(read.variants.len >= 2);

    const Choice = admin.views.VariantSwitcher.ChoicesItem;
    const choices = try session.arena.alloc(Choice, read.variants.len);
    var current: []const u8 = read.variants[0].label;

    for (read.variants, choices) |variant, *choice| {
        const code = if (variant.main) "" else variant.code;
        const picked = std.mem.eql(u8, code, read.chosen);

        if (picked) {
            current = variant.label;
        }

        choice.* = .{
            .code = code,
            .label = variant.label,
            .current = picked,
        };
    }

    return admin.render.view(session.arena, admin.views.VariantSwitcher, .{
        .title = try session.declared(picker),
        .current = current,
        .choices = choices,
        .back = session.request.path(),
    });
}

/// `POST /admin/variant`: the person's choice, then back where they were.
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
        .variant = post.form.text("variant") orelse "",
    }) catch |err| return admin.fail(session, err, "/admin");

    try response.redirect(.see_other, if (local) back else "/admin");
}
