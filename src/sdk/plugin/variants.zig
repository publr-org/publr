//! A variant dimension: what makes a field hold a value per variant (`name@pl`, see
//! `model/variant.zig`). One plugin may declare it (the languages plugin: a language is a
//! variant); the core draws its setting on every field, reads the list where it shows or
//! serves variants, and knows nothing else about what a variant is.
const std = @import("std");
const plugin_define = @import("define.zig");
const model_variant = @import("../../model/variant.zig");

/// `pub const variants: publr.plugin.Variants` in a plugin.
pub const Dimension = struct {
    /// The field setting that turns it on: `Translate`.
    label: []const u8,
    /// What the setting means, under it.
    help: []const u8,
    /// The admin's picker of the variant content shows in, top right: `Content language`.
    /// Empty: no picker.
    picker: []const u8 = "",
    /// A read of the plugin's own (`publr.operation.define`) taking nothing and answering
    /// `variants`: every `Variant` in the order people see them, the main one first.
    list: type,
    /// The type setting for records not written in a variant: shown in its main values
    /// (`keep`), or left out of it (`omit`). Unnamed: the setting is not offered.
    untranslated: Untranslated = .{},
};

pub const Untranslated = struct {
    label: []const u8 = "",
    keep: []const u8 = "",
    keep_help: []const u8 = "",
    omit: []const u8 = "",
    omit_help: []const u8 = "",
};

/// One variant as the core shows and serves it.
pub const Variant = struct {
    /// `pl`, `en-gb`: the code its values are stored under. The main variant's values are
    /// stored under the plain name; its code still names it (`<html lang>`).
    code: []const u8,
    /// What people call it: `Polski`.
    label: []const u8,
    /// Where its pages are, under the site: `/pl`; empty for the main variant.
    address: []const u8 = "",
    main: bool = false,
};

pub const variants_max: u32 = 64;

/// The dimension a plugin declares, checked.
pub fn of(comptime Plugin: type) ?Dimension {
    comptime {
        const name = Plugin.manifest.name;

        if (!plugin_define.has(Plugin, "variants")) {
            return null;
        }

        var declared: Dimension = plugin_define.get(Plugin, "variants");
        const List = @import("operation_define.zig").Described(declared.list, name, Plugin.docs);

        if (declared.label.len == 0 or declared.help.len == 0) {
            @compileError("plugin " ++ name ++ ": `variants` needs a label and help");
        }

        const kind = if (@hasDecl(List, "given")) List.given.kind else List.kind;

        if (kind != .read or !@hasField(List.Out, "variants")) {
            @compileError("plugin " ++ name ++ ": `variants.list` is a read answering `variants`");
        }

        declared.list = List;

        const done = declared;

        return done;
    }
}
