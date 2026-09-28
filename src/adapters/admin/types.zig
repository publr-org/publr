//! Content types in the admin: `definitions.zig` over the content type operations. A
//! new type is created from its head alone, then built up field by field on its fields
//! page (`type_fields.zig`).
const std = @import("std");
const model = @import("../../model.zig");
const definitions = @import("definitions.zig");

const Kind = model.content_type.Kind;
const KindText = struct { kind: Kind, label: []const u8, description: []const u8 };

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
pub const site_url_of = definitions.site_url_of;
pub const handle_of = definitions.handle_of;
pub const print = definitions.print;

pub const kind_texts = [_]KindText{
    .{
        .kind = .record,
        .label = "Record type",
        .description = "Holds any number of records: posts, pages, hotels, players.",
    },
    .{
        .kind = .settings,
        .label = "Settings",
        .description = "Holds exactly one record: the homepage, the header, general options.",
    },
    .{
        .kind = .component,
        .label = "Component",
        .description = "Holds no records of its own: a set of fields for other types to reuse.",
    },
};

pub fn kind_text(kind: Kind) KindText {
    std.debug.assert(kind_texts.len == @typeInfo(Kind).@"enum".fields.len);
    std.debug.assert(kind_texts[0].kind == .record);

    for (kind_texts) |text| {
        if (text.kind == kind) {
            return text;
        }
    }

    unreachable;
}

test {
    std.testing.refAllDecls(@This());
}
