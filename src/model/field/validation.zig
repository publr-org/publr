//! A field's rules: what a value must be for a write to go through, the messages shown when
//! it is not, and the hint that says the rules beside the field's help. Only rules live
//! here; how a field is shown and edited is its `options`. Every part has a default, so a
//! field carries only what was set.
const std = @import("std");

pub const hint_len_max: u32 = 255;

const public = @import("../../publr/field_options.zig");

pub const Messages = public.Messages;
pub const Preset = public.Preset;
pub const Date = public.DateRule;
pub const Slug = public.SlugRule;
pub const Email = public.EmailRule;
pub const Url = public.UrlRule;
pub const Reference = public.ReferenceRule;
pub const Media = public.MediaRule;
pub const Validation = public.Validation;

test "a validation writes only what was set" {
    const set: Validation = .{
        .required = true,
        .max_len = 280,
    };
    const text = try std.json.Stringify.valueAlloc(std.testing.allocator, set, .{});
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("{\"required\":true,\"max_len\":280}", text);
    try std.testing.expect(!(Validation{}).required);
}
