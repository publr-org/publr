//! Interactive components for a host with no compiler (`--script`): their render as one
//! JavaScript program (`render.js`, run in Publr's script engine), the browser's stores
//! beside it, the classes the sheet needs, and the components a page may place with the
//! props a call site fills (`components.json`). An installed plugin carries the four in its
//! module; an app loaded from a folder gets them from the `publr` command.
const std = @import("std");
const pjsx = @import("pjsx");

const Module = pjsx.compiler.ModuleIR;

pub const render_name = "render.js";
pub const browser_name = "stores.js";
pub const classes_name = "classes.txt";
pub const components_name = "components.json";

pub const Parts = struct {
    arena: std.mem.Allocator,
    render: []const u8,
    browser: []const u8,
    classes: []const u8,
    /// The modules of the folder itself, not the design-system parts they import.
    placeable: []const *const Module,
};

/// A component a page may place: the props a call site may fill and whether it draws
/// children.
pub const Component = struct {
    name: []const u8,
    props: []const Prop,
    takes_children: bool,
};

pub const Prop = struct {
    name: []const u8,
    /// `string`, `number`, `boolean`, `list` or `object`: what a call site hands it.
    kind: []const u8,
    has_default: bool,
};

pub fn write(io: std.Io, out_dir: std.Io.Dir, parts: Parts) !void {
    std.debug.assert(parts.render.len > 0);
    std.debug.assert(parts.placeable.len > 0);

    const components = try components_of(parts.arena, parts.placeable);
    const listing = try std.json.Stringify.valueAlloc(parts.arena, components, .{});
    const files = [_][2][]const u8{
        .{ render_name, parts.render },
        .{ browser_name, parts.browser },
        .{ classes_name, parts.classes },
        .{ components_name, listing },
    };

    for (files) |file| {
        try out_dir.writeFile(io, .{
            .sub_path = file[0],
            .data = file[1],
        });
    }
}

fn components_of(arena: std.mem.Allocator, modules: []const *const Module) ![]const Component {
    std.debug.assert(modules.len > 0);

    var found: std.ArrayList(Component) = .empty;

    for (modules) |module| {
        var props: std.ArrayList(Prop) = .empty;
        var takes_children = false;
        const schema = module.component.props;

        for (schema.keys(), schema.values()) |name, prop| {
            if (std.mem.eql(u8, name, "children")) {
                takes_children = true;
                continue;
            }

            const kind = kind_of(prop.type) orelse continue;

            try props.append(arena, .{
                .name = name,
                .kind = kind,
                .has_default = prop.optional or prop.default != null or
                    prop.default_expression != null,
            });
        }

        try found.append(arena, .{
            .name = module.component.name,
            .props = props.items,
            .takes_children = takes_children,
        });
    }

    return found.items;
}

/// What a call site hands a prop of `kind`; null for one no page fills (an action, a ref,
/// markup).
fn kind_of(kind: pjsx.analyze.PropType) ?[]const u8 {
    std.debug.assert(@tagName(kind).len > 0);

    return switch (kind) {
        .string, .optional_string, .@"union" => "string",
        .number, .optional_number => "number",
        .boolean, .optional_boolean => "boolean",
        .array => "list",
        .object => "object",
        else => null,
    };
}
