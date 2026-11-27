const std = @import("std");
const public = @import("../publr/model/app.zig");
const address = @import("app/address.zig");
pub const addresses = @import("app/addresses.zig");

pub const Resolved = address.Resolved;
pub const resolve = address.resolve;
pub const url = address.url;
pub const domain_of = address.domain_of;
pub const path_of = address.path_of;
pub const host_of = address.host_of;
pub const origin_of = address.origin_of;
pub const without_base = address.without_base;
pub const needs_base = address.needs_base;
pub const url_attribute = address.url_attribute;

pub const host_len_max = address.host_len_max;

pub const name_len_max = public.name_len_max;
pub const label_len_max = public.label_len_max;
pub const subdomain_len_max = public.subdomain_len_max;
pub const path_len_max = public.path_len_max;
pub const segments_max = public.segments_max;
pub const tokens_max = public.tokens_max;
pub const fonts_max = public.fonts_max;
pub const roles_max = public.roles_max;
pub const plugins_max = public.plugins_max;
pub const Mount = public.Mount;
pub const Token = public.Token;
pub const Font = public.Font;
pub const FontFace = public.FontFace;
pub const font_faces_max = public.font_faces_max;
pub const Config = public.Config;
pub const reserved_segments = public.reserved_segments;
pub const valid_name = public.valid_name;
pub const plugins_problem = public.plugins_problem;
pub const valid_label = public.valid_label;
pub const label_of = public.label_of;
pub const valid_mount = public.valid_mount;
pub const same_place = public.same_place;
pub const base_path = public.base_path;

test {
    std.testing.refAllDecls(address);
    std.testing.refAllDecls(addresses);
}
