const std = @import("std");
const admin = @import("../admin.zig");
const editor = @import("editor.zig");

pub const back = "/admin/content";
pub const form_pages = @import("content/form.zig");
pub const list_page = @import("content/list.zig");
pub const view_pages = @import("content/views.zig");
pub const list = list_page.list;
pub const new_page = form_pages.new_page;
pub const create = form_pages.create;
pub const edit = form_pages.edit;
pub const save = form_pages.save;
pub const new_editor = form_pages.new_editor;
pub const editor_fragment = form_pages.editor_fragment;
pub const pick = form_pages.pick;
pub const action = form_pages.action;
pub const actions_of = editor.actions_of;
pub const has_destructive = editor.has_destructive;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(admin);
}
