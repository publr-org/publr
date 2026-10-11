//! Settings › Site Health › Translations: where installed translations disagree, each
//! plugin's version with a pick; how much of each domain's messages a language covers, the
//! missing ones as a `.pot`.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const translations = @import("../../../operations/health/translations.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;
const views = admin.views;
const back = "/admin/health";

const Disagreement = views.HealthTranslations.DisagreementsItem;

/// Site Health › Translations: every message installed translations disagree on.
pub fn page(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const listed = registry.SDK.dispatch(&session.ctx, translations.Translations, .{}) catch |err| {
        return admin.fail(&session, err, back);
    };
    const items = try session.arena.alloc(Disagreement, listed.disagreements.len);

    for (listed.disagreements, items) |disagreement, *item| {
        item.* = try disagreement_of(&session, disagreement);
    }

    try admin.screen(&session, .ok, views.HealthTranslations, .{
        .coverage = try coverage_of(&session, listed.coverage),
        .disagreements = items,
        .open = @floatFromInt(listed.open),
        .notice = if (admin.query_param(&session, "picked") != null)
            try session.translated("Picked: the admin shows it from the next page on.")
        else
            "",
    });
}

fn disagreement_of(session: *Session, disagreement: translations.Disagreement) Error!Disagreement {
    std.debug.assert(disagreement.candidates.len >= 2);

    const Candidate = @typeInfo(@FieldType(Disagreement, "candidates")).pointer.child;
    const candidates = try session.arena.alloc(Candidate, disagreement.candidates.len);
    const picked = disagreement.chosen.len > 0;

    for (disagreement.candidates, candidates) |candidate, *shown| {
        const chosen = std.mem.eql(u8, candidate.provider, disagreement.chosen);

        shown.* = .{
            .provider = candidate.provider,
            .first_party = candidate.first_party,
            .text = candidate.text,
            .shown = if (picked)
                chosen
            else
                candidate.first_party or first_of(disagreement, candidate),
        };
    }

    return .{
        .locale = disagreement.locale,
        .label = disagreement.label,
        .context = disagreement.context,
        .id = disagreement.id,
        .candidates = candidates,
        .picked = picked,
    };
}

/// With no first-party version, the first one is what shows.
fn first_of(disagreement: translations.Disagreement, candidate: translations.Candidate) bool {
    std.debug.assert(disagreement.candidates.len > 0);

    for (disagreement.candidates) |other| {
        if (other.first_party) {
            return false;
        }
    }

    return std.mem.eql(u8, disagreement.candidates[0].provider, candidate.provider);
}

pub fn choose(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    const tab = back ++ "/translations";
    var post = try admin.accept(request, response, ctx, tab) orelse return;
    const session = &post.session;
    const form = &post.form;

    _ = registry.SDK.dispatch(&session.ctx, translations.ChooseTranslation, .{
        .locale = form.text("locale") orelse "",
        .context = form.text("context") orelse "",
        .id = form.text("id") orelse "",
        .provider = form.text("provider") orelse "",
    }) catch |err| return admin.fail(session, err, tab);

    try response.redirect(.see_other, tab ++ "?picked=1");
}

const Covered = views.HealthTranslations.CoverageItem;

fn coverage_of(session: *Session, listed: []const translations.Covered) Error![]const Covered {
    std.debug.assert(session.signed_in());

    const arena = session.arena;
    const out = try arena.alloc(Covered, listed.len);

    for (listed, out) |covered, *row| {
        const share = if (covered.total == 0) 100 else covered.translated * 100 / covered.total;
        const untranslated = covered.total - covered.translated;

        row.* = .{
            .label = covered.label,
            .domain = if (std.mem.eql(u8, covered.domain, "publr")) "Publr" else covered.domain,
            .translated = @floatFromInt(covered.translated),
            .total = @floatFromInt(covered.total),
            .share = try std.fmt.allocPrint(arena, "{d}%", .{share}),
            .providers = try std.mem.join(arena, ", ", covered.providers),
            .missing_href = if (untranslated == 0)
                ""
            else
                try std.fmt.allocPrint(arena, "{s}/translations/missing?locale={s}&domain={s}", .{
                    back,
                    covered.locale,
                    covered.domain,
                }),
        };
    }

    return out;
}

/// The messages a language misses in one domain, as a `.pot` to download.
pub fn missing(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const locale = admin.query_param(&session, "locale") orelse "";
    const domain = admin.query_param(&session, "domain") orelse "";
    const listed = registry.SDK.dispatch(&session.ctx, translations.MissingTranslations, .{
        .locale = locale,
        .domain = domain,
    }) catch |err| return admin.fail(&session, err, back ++ "/translations");
    const name = try std.fmt.allocPrint(session.arena, "attachment; filename=\"{s}-{s}.pot\"", .{
        domain,
        locale,
    });

    try response.set_body(.ok, "text/plain; charset=utf-8", listed.template);
    try response.set_header("Content-Disposition", name);
}
