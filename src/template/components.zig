//! Component call sites: `<X />` embeds a template here, `<X island />` and
//! `<X dynamic />` make it a fragment of its own, and a PJSX component is a call into
//! the module its toolchain lowered.

const std = @import("std");
const ast = @import("ast.zig");
const compile = @import("compile.zig");
const expression = @import("expression.zig");
const markup = @import("markup.zig");

const Compiler = compile.Compiler;
const Error = compile.Error;
const Node = ast.Node;
const Template = ast.Template;
const Attr = markup.Attr;

const island_attributes = [_][]const u8{ "island", "dynamic", "prerender", "eager" };

/// What a component tag's attributes say: the island markers, the cache policy, and
/// the props with their literal spellings (empty for an expression).
const CallSite = struct {
    static_island: bool = false,
    dynamic_island: bool = false,
    /// `dynamic` itself, which `dynamic-if` may not be given with.
    dynamic_bare: bool = false,
    /// `dynamic-if="<name>"`: the browser condition that decides whether it is fetched.
    condition: []const u8 = "",
    prerender: bool = false,
    eager: bool = false,
    max_age: ?u32 = null,
    props: std.ArrayList(ast.PropArg) = .empty,
    literals: std.ArrayList([]const u8) = .empty,

    fn is_island(site: *const CallSite) bool {
        return site.static_island or site.dynamic_island;
    }
};

pub fn component(
    compiler: *Compiler,
    name: []const u8,
    attributes: []const Attr,
    self_closing: bool,
) Error!void {
    std.debug.assert(std.ascii.isUpper(name[0]));

    var callee_index: ?u32 = null;

    for (compiler.imports.items) |import| {
        if (!std.mem.eql(u8, import.local, name)) {
            continue;
        }

        if (import.pjsx) |component_index| {
            return pjsx_component(compiler, name, component_index, attributes, self_closing);
        }

        callee_index = import.index;
    }

    const index = callee_index orelse return compiler.fail("<{s}> is not imported", .{name});
    const callee = &compiler.context.templates[index];

    if (callee.kind != .layout) {
        return compiler.fail(
            "<{s}> imports a page ({s}); a page is a route, not a component — only " ++
                "content/ holds pages",
            .{ name, callee.rel },
        );
    }

    if (!callee.compiled) {
        compiler.context.compile(index) catch |err| {
            if (err == error.Unsupported) {
                return compiler.fail("<{s}> could not be lowered (see above)", .{name});
            }

            return err;
        };
    }

    std.debug.assert(callee.compiled);

    var site: CallSite = .{};

    for (attributes) |attr| {
        try read_attribute(compiler, name, callee, &site, attr);
    }

    try check_entry_props(compiler, name, callee, &site);
    try check_placement(compiler, name, callee, &site);

    if (site.is_island() and !compiler.context.options.dynamic) {
        const default_age: u32 = if (callee.dynamic) 0 else compile.static_island_max_age;

        const max_age = site.max_age orelse default_age;

        return emit_island(compiler, name, callee, index, &site, max_age, self_closing);
    }

    try embed(compiler, name, callee, index, &site, self_closing);
}

fn read_attribute(
    compiler: *Compiler,
    name: []const u8,
    callee: *const Template,
    site: *CallSite,
    attr: Attr,
) Error!void {
    std.debug.assert(callee.compiled);

    if (std.mem.eql(u8, attr.name, "dynamic-if")) {
        return read_condition(compiler, name, site, attr);
    }

    if (is_island_attribute(attr.name)) {
        if (attr.literal != null or attr.expression != null) {
            return compiler.fail("<{s} {s}> is a bare attribute", .{ name, attr.name });
        }

        site.static_island = site.static_island or std.mem.eql(u8, attr.name, "island");
        site.dynamic_island = site.dynamic_island or std.mem.eql(u8, attr.name, "dynamic");
        site.dynamic_bare = site.dynamic_bare or std.mem.eql(u8, attr.name, "dynamic");
        site.prerender = site.prerender or std.mem.eql(u8, attr.name, "prerender");
        site.eager = site.eager or std.mem.eql(u8, attr.name, "eager");

        return;
    }

    if (std.mem.eql(u8, attr.name, "cache")) {
        const text = attr.literal orelse {
            return compiler.fail("<{s} cache> takes a number of seconds: cache=\"60\"", .{name});
        };
        site.max_age = std.fmt.parseInt(u32, text, 10) catch {
            return compiler.fail(
                "<{s} cache=\"{s}\"> — cache takes a number of seconds",
                .{ name, text },
            );
        };

        return;
    }

    if (!reads_prop(callee, attr.name)) {
        return compiler.fail("<{s}> never reads props.{s}", .{ name, attr.name });
    }

    if (site.props.items.len == compile.props_max) {
        return compiler.fail(
            "<{s}> has more than {d} props at this call site",
            .{ name, compile.props_max },
        );
    }

    if (attr.literal) |text| {
        if (std.mem.eql(u8, attr.name, "class") or std.mem.eql(u8, attr.name, "classes")) {
            try markup.collect_classes(compiler, text);
        }
        if (is_entry_prop(callee, attr.name)) {
            return compiler.fail(
                "<{s} {s}=\"…\"> — {s} takes an entry, not a string: {s}={{…}}",
                .{ name, attr.name, attr.name, attr.name },
            );
        }

        const literal: ast.PropArg = .{ .name = attr.name, .value = .{ .literal = text } };

        try site.props.append(compiler.arena, literal);
        const pair = try std.fmt.allocPrint(compiler.arena, "{s}={s}", .{ attr.name, text });
        try site.literals.append(compiler.arena, pair);

        return;
    }

    const text = attr.expression orelse {
        return compiler.fail(
            "<{s} {s}> — a bare attribute cannot fill a string prop",
            .{ name, attr.name },
        );
    };

    try expression_prop(compiler, name, callee, site, attr.name, text);
    try site.literals.append(compiler.arena, "");
}

/// `name={expr}`: a string (or optional string) for a string prop, an entry for a prop
/// the component declares as one.
fn expression_prop(
    compiler: *Compiler,
    name: []const u8,
    callee: *const Template,
    site: *CallSite,
    prop_name: []const u8,
    text: []const u8,
) Error!void {
    std.debug.assert(callee.compiled);
    std.debug.assert(prop_name.len > 0);

    const value = try expression.expression(compiler, text);
    const takes_entry = is_entry_prop(callee, prop_name);

    switch (value.type) {
        .javascript => {},
        .int, .boolean => if (callee.javascript == null) {
            return compiler.fail("<{s}> expects a string prop", .{name});
        },
        .string, .opt_string => if (takes_entry) {
            return compiler.fail(
                "<{s} {s}={{…}}> passes a {s}; {s} takes an entry",
                .{ name, prop_name, @tagName(value.type), prop_name },
            );
        },
        .entry => if (!takes_entry and callee.javascript == null) {
            return compiler.fail(
                "<{s} {s}={{…}}> passes an entry; {s} is a string prop (a component " ++
                    "declares an entry prop as const {s} = props.entry.{s};)",
                .{ name, prop_name, prop_name, prop_name, prop_name },
            );
        },
        else => return compiler.fail(
            "<{s} {s}={{…}}> passes a {s}; props are strings or entries",
            .{ name, prop_name, @tagName(value.type) },
        ),
    }

    const computed: ast.PropArg = .{ .name = prop_name, .value = .{ .expr = value } };

    try site.props.append(compiler.arena, computed);
}

fn is_entry_prop(callee: *const Template, name: []const u8) bool {
    std.debug.assert(callee.compiled);
    std.debug.assert(name.len > 0);

    for (callee.entry_props) |prop| {
        if (std.mem.eql(u8, prop, name)) {
            return true;
        }
    }

    return false;
}

/// An entry prop has no default: every call site passes it.
fn check_entry_props(
    compiler: *Compiler,
    name: []const u8,
    callee: *const Template,
    site: *const CallSite,
) Error!void {
    std.debug.assert(callee.compiled);
    std.debug.assert(site.props.items.len <= compile.props_max);

    for (callee.entry_props) |prop| {
        var passed = false;

        for (site.props.items) |arg| {
            if (std.mem.eql(u8, arg.name, prop)) {
                passed = true;
            }
        }

        if (!passed) {
            return compiler.fail(
                "<{s}> needs {s}={{…}}: {s} reads it as an entry",
                .{ name, prop, callee.rel },
            );
        }
    }
}

/// `dynamic-if="<name>"`: a dynamic island fetched only when the browser's condition of
/// that name holds. A name, not an expression: the condition is decided in the browser on
/// each view, and braces always mean the build or the server.
fn read_condition(compiler: *Compiler, name: []const u8, site: *CallSite, attr: Attr) Error!void {
    std.debug.assert(std.mem.eql(u8, attr.name, "dynamic-if"));

    if (attr.expression != null) {
        return compiler.fail(
            "<{s} dynamic-if={{…}}> — the condition is decided in the browser, on each view: " ++
                "name one, dynamic-if=\"signedIn\", registered with Publr.islands.condition",
            .{name},
        );
    }

    const condition = attr.literal orelse {
        return compiler.fail("<{s} dynamic-if> needs a condition's name: " ++
            "dynamic-if=\"signedIn\"", .{name});
    };

    if (!valid_condition(condition)) {
        return compiler.fail(
            "<{s} dynamic-if=\"{s}\"> — a condition's name is a letter, then letters, " ++
                "digits or _",
            .{ name, condition },
        );
    }

    site.condition = condition;
    site.dynamic_island = true;
}

fn valid_condition(text: []const u8) bool {
    std.debug.assert(text.len <= 1 << 16);

    if (text.len == 0 or text.len > 64 or !std.ascii.isAlphabetic(text[0])) {
        return false;
    }

    for (text) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_') {
            return false;
        }
    }

    return true;
}

fn is_island_attribute(name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (island_attributes) |candidate| {
        if (std.mem.eql(u8, name, candidate)) {
            return true;
        }
    }

    return false;
}

fn reads_prop(callee: *const Template, name: []const u8) bool {
    std.debug.assert(callee.compiled);

    if (callee.javascript != null) {
        return true;
    }

    for (callee.props.?) |prop| {
        if (std.mem.eql(u8, prop, name)) {
            return true;
        }
    }

    return false;
}

/// The call site names the kind of island, and it has to be the kind the component
/// is, which is what the name says. With the whole site run dynamic there are no
/// islands at all.
fn check_placement(
    compiler: *Compiler,
    name: []const u8,
    callee: *const Template,
    site: *const CallSite,
) Error!void {
    std.debug.assert(callee.compiled);

    if (!compiler.context.options.dynamic) {
        if (callee.dynamic and !site.dynamic_island) {
            return compiler.fail(
                "{s} is dynamic, so it renders per request wherever it is placed. Say so " ++
                    "here: <{s} dynamic />",
                .{ callee.rel, name },
            );
        }

        if (!callee.dynamic and site.dynamic_island) {
            return compiler.fail(
                "<{s} dynamic> — {s} is static, so it is a choice: <{s} /> renders it into " ++
                    "this page, <{s} island /> makes it a fragment of its own",
                .{ name, callee.rel, name, name },
            );
        }
    }

    if (site.dynamic_bare and site.condition.len > 0) {
        return compiler.fail(
            "<{s} dynamic dynamic-if> — use one: dynamic fetches it on every view, " ++
                "dynamic-if only when its condition holds",
            .{name},
        );
    }

    if (site.static_island and site.dynamic_island) {
        return compiler.fail(
            "<{s} island dynamic> — an island is static or dynamic, not both",
            .{name},
        );
    }

    if (site.is_island()) {
        return;
    }

    if (site.max_age != null) {
        return compiler.fail(
            "<{s} cache> only means something on an island: an embedded component is part " ++
                "of the page",
            .{name},
        );
    }

    if (site.prerender) {
        return compiler.fail(
            "<{s} prerender> only means something on an island: an embedded component is " ++
                "rendered at build already",
            .{name},
        );
    }

    if (site.eager) {
        return compiler.fail(
            "<{s} eager> only means something on an island: an embedded component is part " ++
                "of the page",
            .{name},
        );
    }
}

/// What an embedded template emits, this one emits; what it reads, this template
/// effectively reads.
fn embed(
    compiler: *Compiler,
    name: []const u8,
    callee: *const Template,
    index: u32,
    site: *const CallSite,
    self_closing: bool,
) Error!void {
    const template = compiler.template;

    std.debug.assert(callee.compiled);
    std.debug.assert(index < compiler.context.templates.len);

    template.has_static_islands = template.has_static_islands or callee.has_static_islands;
    template.has_interactive = template.has_interactive or callee.has_interactive;
    template.reads_data = template.reads_data or callee.reads_data;
    template.has_dynamic_islands = template.has_dynamic_islands or callee.has_dynamic_islands;
    template.has_head = template.has_head or callee.has_head;

    try note_nested(compiler, callee, !template.dynamic);

    const props = site.props.items;

    if (self_closing) {
        return compiler.push(.{ .embed = .{ .callee = index, .props = props, .children = null } });
    }

    const children = try markup.children_list(compiler, name);

    try compiler.push(.{ .embed = .{ .callee = index, .props = props, .children = children } });
}

/// The islands a nested template will place, on this template's lists.
pub fn note_nested(compiler: *Compiler, callee: *const Template, with_dynamic: bool) Error!void {
    std.debug.assert(callee.compiled);

    for (callee.static_island_keys) |nested| {
        try compiler.note_static_island(nested, false);
    }

    for (callee.static_idle_keys) |nested| {
        try compiler.note_static_island(nested, true);
    }

    if (!with_dynamic) {
        return;
    }

    for (callee.dynamic_eager_keys) |nested| {
        try compile.note(compiler.arena, &compiler.dynamic_eager_keys, nested);
    }

    for (callee.dynamic_idle_keys) |nested| {
        try compile.note(compiler.arena, &compiler.dynamic_idle_keys, nested);
    }
}

/// `<X ... island>fallback</X>` / `<X ... dynamic>fallback</X>`: a `<publr-island>`
/// placeholder naming the fragment, the fallback inside it, and the (component, props)
/// pair registered on the islands table.
fn emit_island(
    compiler: *Compiler,
    name: []const u8,
    callee: *const Template,
    index: u32,
    site: *const CallSite,
    max_age: u32,
    self_closing: bool,
) Error!void {
    const template = compiler.template;

    std.debug.assert(site.is_island());
    std.debug.assert(callee.compiled);

    for (site.literals.items) |literal| {
        if (literal.len == 0) {
            return compiler.fail(
                "<{s}> — island props must be string literals: the fragment is built once " ++
                    "and shared by every page that names it",
                .{name},
            );
        }
    }

    const fallback_source: []const u8 = if (self_closing)
        ""
    else
        try markup.take_children(compiler, name);

    if (site.prerender and std.mem.trim(u8, fallback_source, " \t\r\n").len > 0) {
        return compiler.fail(
            "<{s} prerender>: a fallback would replace the whole prerender — give the " ++
                "component a prop for what the build cannot know instead",
            .{name},
        );
    }

    // An island holding an interactive component makes the page that places it
    // interactive, exactly as it makes it an island-bearing page.
    template.has_interactive = template.has_interactive or callee.has_interactive;

    const key = try compile.island_key(compiler.arena, callee.rel, site.literals.items);
    try register_island(compiler, name, callee, index, site, key, max_age);

    // What this page will preload: this island when it is static, and whatever static
    // islands its fragment will itself place. Only what is `eager`: an island is
    // deferred unless the call site says it is needed at once (above the fold).
    if (site.eager) {
        try note_eager(compiler, callee, site, key);
    }

    if (callee.dynamic) {
        template.has_dynamic_islands = true;
    } else {
        template.has_static_islands = true;
    }

    const fallback: []const Node = if (site.prerender or self_closing)
        &.{}
    else
        try markup.sub_list(compiler, fallback_source);

    try compiler.push(.{ .island = .{
        .callee = index,
        .key = key,
        .props = site.props.items,
        .dynamic = callee.dynamic,
        .prerender = site.prerender,
        .deferred = !site.eager,
        .condition = site.condition,
        .fallback = fallback,
    } });
}

fn register_island(
    compiler: *Compiler,
    name: []const u8,
    callee: *const Template,
    index: u32,
    site: *const CallSite,
    key: []const u8,
    max_age: u32,
) Error!void {
    const islands = &compiler.context.islands;

    std.debug.assert(key.len > 0);
    std.debug.assert(islands.items.len <= compile.islands_max);

    for (islands.items) |existing| {
        if (!std.mem.eql(u8, existing.key, key)) {
            continue;
        }

        if (existing.max_age != max_age) {
            return compiler.fail(
                "<{s} cache=\"{d}\"> — another call site names the same island with " ++
                    "cache=\"{d}\"; one fragment, one policy",
                .{ name, max_age, existing.max_age },
            );
        }

        return;
    }

    if (islands.items.len == compile.islands_max) {
        return compiler.fail("more than {d} islands in the app", .{compile.islands_max});
    }

    try islands.append(compiler.arena, .{
        .key = key,
        .template = index,
        .props = site.props.items,
        .dynamic = callee.dynamic,
        .max_age = max_age,
    });
}

fn note_eager(
    compiler: *Compiler,
    callee: *const Template,
    site: *const CallSite,
    key: []const u8,
) Error!void {
    std.debug.assert(site.eager);
    std.debug.assert(key.len > 0);

    // Whether it is fetched at all is the browser's to decide: a preload would fetch it
    // regardless, and whatever it would place inside.
    if (site.condition.len > 0) {
        return;
    }

    if (callee.dynamic) {
        if (!compiler.template.dynamic) {
            const set = if (site.prerender)
                &compiler.dynamic_idle_keys
            else
                &compiler.dynamic_eager_keys;

            try compile.note(compiler.arena, set, key);
        }
    } else {
        try compiler.note_static_island(key, site.prerender);
    }

    try note_nested(compiler, callee, false);
}

/// `<Disclosure label="..." />` where `Disclosure` came from a `.ptsx`: a call into the
/// module the PJSX toolchain lowered. It is embedded, never an island; the `.publr`
/// component that wraps it carries `island`.
fn pjsx_component(
    compiler: *Compiler,
    name: []const u8,
    component_index: u32,
    attributes: []const Attr,
    self_closing: bool,
) Error!void {
    const lowered = compiler.context.options.pjsx[component_index];
    var props: std.ArrayList(ast.PropArg) = .empty;

    std.debug.assert(lowered.name.len > 0);
    std.debug.assert(component_index < compiler.context.options.pjsx.len);

    for (attributes) |attr| {
        try pjsx_attribute(compiler, name, lowered, &props, attr);
    }

    compiler.template.has_interactive = true;

    const filled = props.items;

    if (self_closing) {
        return compiler.push(.{ .pjsx = .{
            .component = component_index,
            .props = filled,
            .children = null,
        } });
    }

    if (!lowered.takes_children) {
        return compiler.fail("<{s}> does not render children", .{name});
    }

    const children = try markup.children_list(compiler, name);

    try compiler.push(.{ .pjsx = .{
        .component = component_index,
        .props = filled,
        .children = children,
    } });
}

fn pjsx_attribute(
    compiler: *Compiler,
    name: []const u8,
    lowered: compile.PjsxComponent,
    props: *std.ArrayList(ast.PropArg),
    attr: Attr,
) Error!void {
    std.debug.assert(name.len > 0);

    if (is_island_attribute(attr.name) or std.mem.eql(u8, attr.name, "cache")) {
        return compiler.fail(
            "<{s} {s}> — {s} is a PJSX component, which is always embedded. Wrap it in a " ++
                ".publr component and mark that as the island",
            .{ name, attr.name, name },
        );
    }

    if (std.mem.eql(u8, attr.name, "children")) {
        return compiler.fail(
            "<{s} children> — children are the element's content, not a prop",
            .{name},
        );
    }

    var known: ?compile.PjsxProp = null;

    for (lowered.props) |prop| {
        if (std.mem.eql(u8, prop.name, attr.name)) {
            known = prop;
        }
    }

    const prop = known orelse return compiler.fail("<{s}> has no prop {s}", .{ name, attr.name });

    if (props.items.len == compile.props_max) {
        return compiler.fail(
            "<{s}> has more than {d} props at this call site",
            .{ name, compile.props_max },
        );
    }

    if (attr.literal) |text| {
        try props.append(compiler.arena, .{ .name = attr.name, .value = .{ .literal = text } });

        // A PJSX component spells its class prop `classes`; what a call site passes is
        // the app's, so the JIT has to see it.
        if (std.mem.eql(u8, attr.name, "classes")) {
            try markup.collect_classes(compiler, text);
        }

        return;
    }

    const text = attr.expression orelse {
        return compiler.fail(
            "<{s} {s}> — a bare attribute cannot fill a string prop",
            .{ name, attr.name },
        );
    };
    const value = try expression.expression(compiler, text);
    const computed: ast.PropArg = .{ .name = attr.name, .value = .{ .expr = value } };

    switch (value.type) {
        .javascript => try props.append(compiler.arena, computed),
        .string => try props.append(compiler.arena, computed),
        // A value that may be null, for a prop the component has a default for: the
        // default stands.
        .opt_string => if (prop.has_default) {
            try props.append(compiler.arena, computed);
        } else {
            return compiler.fail(
                "<{s} {s}={{…}}> may be null, and {s} has no default for {s} — give it a " ++
                    "fallback: {s}={{… ?? \"…\"}}",
                .{ name, attr.name, name, attr.name, attr.name },
            );
        },
        else => return compiler.fail(
            "<{s} {s}={{…}}> passes a {s}; props are strings",
            .{ name, attr.name, @tagName(value.type) },
        ),
    }
}
