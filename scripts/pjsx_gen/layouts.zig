//! The admin's page layouts hold: only a layout draws the chrome, and a page drawn by one
//! sets no spacing on what it puts in it. `render.page` checks at compile time that every
//! page's root is a layout; this checks the rest over the compiled set.
const std = @import("std");
const pjsx = @import("pjsx");

const Module = pjsx.compiler.ModuleIR;
const NodeIR = pjsx.compiler.NodeIR;

/// The layouts a page is drawn by, and the parts only they may use.
pub const layouts = [_][]const u8{ "IndexPage", "FormPage", "HubPage", "CardPage" };
const chrome_parts = [_][]const u8{ "Chrome", "Document" };
/// The spacing a layout owns: a page's own top-level elements set none of it.
const spacing_prefixes = [_][]const u8{
    "p-", "px-", "py-", "pt-", "pb-",
    "m-", "mx-", "my-", "mt-", "mb-",
};

pub fn check(modules: []const *const Module) !void {
    std.debug.assert(modules.len > 0);
    std.debug.assert(layouts.len == 4);

    for (modules) |module| {
        try check_imports(module);
        try check_spacing(module);
    }
}

fn is_one_of(name: []const u8, names: []const []const u8) bool {
    std.debug.assert(names.len > 0);

    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }

    return false;
}

fn check_imports(module: *const Module) !void {
    const name = module.component.name;

    std.debug.assert(name.len > 0);

    if (is_one_of(name, &layouts) or is_one_of(name, &chrome_parts)) {
        return;
    }

    for (module.component.imports) |import| {
        for (import.names) |entry| {
            if (is_one_of(entry.imported, &chrome_parts)) {
                std.debug.print(
                    "pjsx_gen: {s} imports {s}; pages draw the chrome through a layout " ++
                        "(IndexPage, FormPage, HubPage, CardPage)\n",
                    .{ name, entry.imported },
                );

                return error.ChromeOutsideLayouts;
            }
        }
    }
}

fn check_spacing(module: *const Module) !void {
    const root = module.component.root;

    std.debug.assert(module.component.name.len > 0);

    if (root.* != .element or root.element.name != .component) {
        return;
    }

    if (!is_one_of(root.element.name.component.name, &layouts)) {
        return;
    }

    for (root.element.children) |child| {
        if (child.* != .element) {
            continue;
        }

        for (child.element.attributes) |attribute| {
            if (attribute != .attribute) {
                continue;
            }

            const attribute_name = attribute.attribute.name;
            const is_class = std.mem.eql(u8, attribute_name, "class") or
                std.mem.eql(u8, attribute_name, "classes");

            if (is_class) {
                try check_classes(module.component.name, attribute.attribute.value);
            }
        }
    }
}

fn check_classes(page: []const u8, value: *const pjsx.compiler.ExpressionIR) !void {
    std.debug.assert(page.len > 0);

    if (value.* != .literal or value.literal != .string) {
        return;
    }

    var classes = std.mem.tokenizeScalar(u8, value.literal.string, ' ');

    while (classes.next()) |class| {
        for (spacing_prefixes) |prefix| {
            if (std.mem.startsWith(u8, class, prefix)) {
                std.debug.print(
                    "pjsx_gen: {s} sets \"{s}\" on what it puts in its layout; the layout " ++
                        "owns the page's spacing\n",
                    .{ page, class },
                );

                return error.PageSpacing;
            }
        }
    }
}
