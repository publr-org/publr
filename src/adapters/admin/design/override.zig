//! `POST /admin/design/override`: what the block editor saves (a template, a part, a
//! pattern) and what Reset and Remove take away, as override records in the app. The
//! editor asks for JSON (`Publr-Fragment: json`); a form on the Design pages is sent back.
const std = @import("std");
const admin = @import("../../admin.zig");
const design = @import("../../../model/design.zig");
const engine = @import("../../../template.zig");
const files = @import("files.zig");
const records = @import("records.zig");
const App = @import("../../apps/state.zig").App;
const pattern_settings = design.pattern_settings;

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;
const Form = admin.Form;
const regions = engine.regions;
const Problem = struct {
    path: []const u8,
    message: []const u8,
};

pub const path = "/admin/design/override";

pub const Kind = enum {
    template,
    part,
    pattern,
    @"reset-template",
    @"reset-part",
    @"remove-pattern",

    fn handle(kind: Kind) []const u8 {
        const found = switch (kind) {
            .template, .@"reset-template" => design.template_handle,
            .part, .@"reset-part" => design.part_handle,
            .pattern, .@"remove-pattern" => design.pattern_handle,
        };

        std.debug.assert(design.is_design(found));

        return found;
    }

    fn back(kind: Kind) []const u8 {
        const patterns = kind == .pattern or kind == .@"remove-pattern";

        std.debug.assert(patterns or kind.handle().len > 0);

        return if (patterns) "/admin/design/patterns" else "/admin/design/templates";
    }
};

pub fn save(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const form = Form.parse(session.arena, request.body) orelse {
        return answer(&session, null, try session.translated("Not saved: the form did not parse."));
    };

    if (!session.guard(&form)) {
        const reason = try session.translated(
            "Not saved: the request did not come from this site.",
        );

        return answer(&session, null, reason);
    }

    const kind_text = field(&session, &form, "kind");
    const kind = std.meta.stringToEnum(Kind, kind_text) orelse {
        const reason = try session.translated("Not saved: nothing to save by that kind.");

        return answer(&session, null, reason);
    };
    const app = files.app_of(&session, field(&session, &form, "app")) orelse {
        return answer(&session, kind, try session.translated("Not saved: no app to save it in."));
    };
    const name = field(&session, &form, "name");

    if (try refused(&session, app, kind, name, &form)) |reason| {
        return answer(&session, kind, reason);
    }

    const settings: pattern_settings.Settings = if (kind == .pattern)
        try settings_of(session.arena, &form)
    else
        .{};

    if (pattern_settings.problem(settings)) |why| {
        const reason = try session.translated_with("Not saved: {reason}.", &.{.{
            .name = "reason",
            .value = why,
        }});

        return answer(&session, kind, reason);
    }

    const done = switch (kind) {
        .template, .part, .pattern => records.save(&session, kind.handle(), app.spec.name, .{
            .route = if (kind == .template) name else "",
            .name = if (kind == .template) "" else name,
            .label = field(&session, &form, "label"),
            .category = field(&session, &form, "category"),
            .description = field(&session, &form, "description"),
            .html = field(&session, &form, "html"),
            .output = if (kind == .pattern) "" else field(&session, &form, "output"),
            .variants = settings.variants,
            .default_variant = settings.default_variant,
            .default_color_context = settings.default_color_context,
            .disabled_color_contexts = settings.disabled_color_contexts,
        }),
        else => removed(&session, kind, app, name),
    };

    done catch |err| {
        const reason = try session.translated_with("Not saved: {reason}", &.{.{
            .name = "reason",
            .value = @errorName(err),
        }});

        return answer(&session, kind, reason);
    };

    try answer(&session, kind, null);
}

/// A pattern's variants and color settings as the editor sends them: `variant_<n>_name`,
/// `_label`, `_description` and `_html` from 0 up, `disabled_color_context_<n>`, and
/// `default_variant` and `default_color_context`. One past the limit is read, so too many
/// is refused rather than cut.
fn settings_of(arena: std.mem.Allocator, form: *const Form) !pattern_settings.Settings {
    std.debug.assert(form.len <= admin.form_pairs_max);
    std.debug.assert(pattern_settings.variants_max * 4 < admin.form_pairs_max);

    var variants: std.ArrayList(records.Variant) = .empty;
    var index: u32 = 0;

    while (index <= pattern_settings.variants_max) : (index += 1) {
        const variant_name = form.text(try key_of(arena, "variant", index, "_name")) orelse break;

        try variants.append(arena, .{
            .name = variant_name,
            .label = form.text(try key_of(arena, "variant", index, "_label")) orelse "",
            .description = form.text(try key_of(arena, "variant", index, "_description")) orelse "",
            .html = form.text(try key_of(arena, "variant", index, "_html")) orelse "",
        });
    }

    var contexts: std.ArrayList([]const u8) = .empty;

    index = 0;

    while (index <= pattern_settings.contexts_max) : (index += 1) {
        const key = try key_of(arena, "disabled_color_context", index, "");
        const context = form.text(key) orelse break;

        try contexts.append(arena, context);
    }

    return .{
        .variants = variants.items,
        .default_variant = form.text("default_variant") orelse "",
        .default_color_context = form.text("default_color_context") orelse "",
        .disabled_color_contexts = contexts.items,
    };
}

fn key_of(arena: std.mem.Allocator, lead: []const u8, index: u32, part: []const u8) ![]const u8 {
    std.debug.assert(lead.len > 0);
    std.debug.assert(index <= pattern_settings.variants_max + pattern_settings.contexts_max);

    return std.fmt.allocPrint(arena, "{s}_{d}{s}", .{ lead, index, part });
}

fn removed(session: *Session, kind: Kind, app: *const App, name: []const u8) !void {
    std.debug.assert(name.len > 0);
    std.debug.assert(app.spec.name.len > 0);

    _ = try records.remove(session, kind.handle(), app.spec.name, name);
}

/// A form field, else the same parameter in the address: the editor names the app there.
fn field(session: *const Session, form: *const Form, name: []const u8) []const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(form.len <= admin.form_pairs_max);

    return form.text(name) orelse admin.query_param(session, name) orelse "";
}

/// Why the server will not save it: a route the app has no template region for, a part
/// its files do not place, a name that is no name, a template without its content slot.
fn refused(
    session: *const Session,
    app: *const App,
    kind: Kind,
    name: []const u8,
    form: *const Form,
) !?[]const u8 {
    std.debug.assert(app.spec.name.len > 0);
    std.debug.assert(form.len <= admin.form_pairs_max);

    switch (kind) {
        .template => {
            const routes = try files.templated_routes(session.arena, app);

            if (!files.contains(routes, name)) {
                return try session.translated("Not saved: that route has no template region.");
            }

            const output = field(session, form, "output");
            const whole: regions.Range = .{
                .start = 0,
                .end = @intCast(output.len),
            };

            if (regions.find(output, whole, regions.slot_attribute, "content") == null) {
                return try session.translated("A template needs a content slot.");
            }
        },
        .part => {
            if (!files.contains(try files.part_names(session.arena, app), name)) {
                return try session.translated("Not saved: no file places that part.");
            }
        },
        .pattern, .@"reset-part", .@"remove-pattern" => {
            if (!design.valid_name(name)) {
                return try session.translated("Not saved: a name is letters, digits, - and _.");
            }
        },
        .@"reset-template" => {
            if (name.len == 0 or name.len > 1024) {
                return try session.translated("Not saved: no route named.");
            }
        },
    }

    return null;
}

/// JSON for the editor (`{ saved }` or `{ saved: false, reason }`); a form goes back to the
/// Design page it came from, or to the page that says why not.
fn answer(session: *Session, kind: ?Kind, reason: ?[]const u8) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(reason == null or reason.?.len > 0);

    const wanted = session.request.header("publr-fragment") orelse "";
    const back = if (kind) |known| known.back() else "/admin/design/templates";

    if (std.mem.eql(u8, wanted, "json")) {
        const verdict = if (reason) |why|
            session.response.json(.ok, .{
                .saved = false,
                .reason = why,
            })
        else
            session.response.json(.ok, .{
                .saved = true,
            });

        return verdict catch error.OutOfMemory;
    }

    if (reason) |why| {
        const heading = try session.translated("Not saved");

        return admin.message(session, heading, why, &[_]Problem{}, back);
    }

    try session.response.redirect(.see_other, back);
}

test "settings_of: variants and disabled contexts by index, settings by name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = "kind=pattern&name=hero&variant_0_name=light&variant_0_label=Light" ++
        "&variant_0_html=%3Cp%3Ea%3C%2Fp%3E&variant_1_name=dark&variant_1_label=Dark" ++
        "&variant_1_description=On+dark&default_variant=dark&default_color_context=clay" ++
        "&disabled_color_context_0=slate&variant_3_name=skipped";
    const form = Form.parse(arena, body) orelse return error.TestUnexpectedResult;
    const settings = try settings_of(arena, &form);

    try std.testing.expectEqual(@as(usize, 2), settings.variants.len);
    try std.testing.expectEqualStrings("<p>a</p>", settings.variants[0].html);
    try std.testing.expectEqualStrings("On dark", settings.variants[1].description);
    try std.testing.expectEqualStrings("dark", settings.default_variant);
    try std.testing.expectEqualStrings("clay", settings.default_color_context);
    try std.testing.expectEqualStrings("slate", settings.disabled_color_contexts[0]);
    try std.testing.expectEqual(@as(?[]const u8, null), pattern_settings.problem(settings));

    const bare = "kind=pattern&name=hero";
    const none = Form.parse(arena, bare) orelse return error.TestUnexpectedResult;
    const empty = try settings_of(arena, &none);

    try std.testing.expectEqual(@as(usize, 0), empty.variants.len);
    try std.testing.expectEqual(@as(usize, 0), empty.disabled_color_contexts.len);
}
