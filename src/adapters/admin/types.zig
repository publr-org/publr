//! Content types in the admin: `definitions.zig` over the content type operations. A
//! new type is created from its head alone, then built up field by field on its fields
//! page (`type_fields.zig`).
const std = @import("std");
const model = @import("../../model.zig");
const definitions = @import("definitions.zig");
const admin = @import("../admin.zig");

const Kind = model.content_type.Kind;
const Session = admin.Session;
const KindText = struct {
    kind: Kind,
    label: []const u8,
    description: []const u8,
};

const Pages = definitions.Pages(.{
    .base = "/admin/types",
    .title = "Content types",
    .noun = "content type",
    .key = "type",
    .plural = "types",
    .operations = @import("../../operations/content_type.zig"),
    .is_taxonomy = false,
    .fixed_kind = .record,
});

pub const list = Pages.list;
pub const new_page = Pages.new_page;
pub const settings_page = Pages.settings_page;
pub const create = Pages.create;
pub const update = Pages.update;
pub const delete = Pages.delete;
pub const problems_of = Pages.problems_of;
pub const host_url_of = definitions.host_url_of;
pub const handle_of = definitions.handle_of;
pub const print = definitions.print;

/// What the admin calls a kind, and what it says a kind holds.
pub fn kind_text(session: *const Session, kind: Kind) admin.Error!KindText {
    std.debug.assert(@typeInfo(Kind).@"enum".fields.len == 4);
    std.debug.assert(session.signed_in());

    return switch (kind) {
        .record => .{
            .kind = .record,
            .label = try session.translated("Record type", .{}),
            .description = try session.translated(
                "Holds any number of records: posts, pages, hotels, players.",
                .{},
            ),
        },
        .settings => .{
            .kind = .settings,
            .label = try session.translated("Settings", .{}),
            .description = try session.translated(
                "Holds exactly one record: the homepage, the header, general options.",
                .{},
            ),
        },
        .component => .{
            .kind = .component,
            .label = try session.translated("Component", .{}),
            .description = try session.translated(
                "Holds no records of its own: a set of fields for other types to reuse.",
                .{},
            ),
        },
        .media => .{
            .kind = .media,
            .label = try session.translated("Media", .{}),
            .description = try session.translated(
                "Holds files, shown only where the plugin that declares it draws them.",
                .{},
            ),
        },
    };
}

test {
    std.testing.refAllDecls(@This());
}
