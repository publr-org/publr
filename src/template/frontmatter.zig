//! The frontmatter of a template: imports, and `const name = Publr.<build|request>.<call>`
//! declarations, split by when the answer is known.

const std = @import("std");
const ast = @import("ast.zig");
const compile = @import("compile.zig");
const expression = @import("expression.zig");

const Compiler = compile.Compiler;
const Error = compile.Error;
const Type = ast.Type;

pub const lines_max: u32 = 4096;

pub fn read(compiler: *Compiler, text: []const u8) Error!void {
    std.debug.assert(compiler.decls.items.len == 0);
    std.debug.assert(compiler.imports.items.len == 0);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var count: u32 = 0;
    var block: ?ast.Decl.When = null;

    while (lines.next()) |raw| : (count += 1) {
        if (count == lines_max) {
            return compiler.fail("frontmatter has more than {d} lines", .{lines_max});
        }

        const line = std.mem.trim(u8, raw, " \t\r");

        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) {
            continue;
        }

        if (try branch(compiler, line, &block)) {
            continue;
        }

        if (block) |when| {
            try guarded(compiler, line, when);
        } else {
            try statement(compiler, line);
        }
    }

    if (block != null) {
        return compiler.fail("an `if` block in the frontmatter is never closed with `}}`", .{});
    }
}

/// `if (<condition>) {`, `} else {` and `}`: the lines that open, turn and close a block
/// of actions. True when the line was one of them.
fn branch(compiler: *Compiler, line: []const u8, block: *?ast.Decl.When) Error!bool {
    std.debug.assert(line.len > 0);

    if (std.mem.startsWith(u8, line, "if ") or std.mem.startsWith(u8, line, "if(")) {
        if (block.* != null) {
            return compiler.fail("frontmatter `if` blocks do not nest: {s}", .{line});
        }

        const open = std.mem.indexOfScalar(u8, line, '(') orelse line.len;
        const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse 0;
        const tail = std.mem.trim(u8, line[@min(close + 1, line.len)..], " \t");

        if (close <= open or !std.mem.eql(u8, tail, "{")) {
            return compiler.fail("write a frontmatter `if` as `if (<condition>) {{`: {s}", .{line});
        }

        const condition = try expression.expression(compiler, line[open + 1 .. close]);

        try expression.check_truthy(compiler, condition);
        block.* = .{ .condition = condition };

        return true;
    }

    if (std.mem.eql(u8, line, "} else {") or std.mem.eql(u8, line, "}else{")) {
        const when = block.* orelse return compiler.fail("`else` without an `if`", .{});

        if (when.otherwise) {
            return compiler.fail("an `if` block takes one `else`", .{});
        }

        block.* = .{ .condition = when.condition, .otherwise = true };

        return true;
    }

    if (std.mem.eql(u8, line, "}")) {
        if (block.* == null) {
            return compiler.fail("`}}` without an `if`", .{});
        }

        block.* = null;

        return true;
    }

    return false;
}

/// A line inside a block: an action (`Publr.request.redirect(…)`, `Publr.request.call(…)`),
/// never a declaration, whose name would be missing on the path that skips it.
fn guarded(compiler: *Compiler, line: []const u8, when: ast.Decl.When) Error!void {
    std.debug.assert(line.len > 0);

    if (!std.mem.startsWith(u8, line, "Publr.")) {
        return compiler.fail(
            "an `if` block holds actions (Publr.request.redirect, Publr.request.call), " ++
                "not {s}",
            .{line},
        );
    }

    const before = compiler.decls.items.len;

    try action(compiler, line);

    std.debug.assert(compiler.decls.items.len == before + 1);

    compiler.decls.items[before].when = when;
}

fn statement(compiler: *Compiler, line: []const u8) Error!void {
    std.debug.assert(line.len > 0);
    std.debug.assert(line[0] != ' ');

    if (std.mem.indexOf(u8, line, "Astro") != null) {
        return compiler.fail("the Publr format has no Astro vocabulary: {s}", .{line});
    }

    if (std.mem.startsWith(u8, line, "import ")) {
        return import_line(compiler, line);
    }

    if (is_dump(line)) {
        return compiler.fail("dd() / dump() are not supported by this demo's lowering", .{});
    }

    if (std.mem.startsWith(u8, line, "Publr.")) {
        return action(compiler, line);
    }

    if (!std.mem.startsWith(u8, line, "const ")) {
        return compiler.fail("unsupported frontmatter statement: {s}", .{line});
    }

    return declaration(compiler, line);
}

/// `const <name> = <what>;`: a value the rest of the template reads by name.
fn declaration(compiler: *Compiler, line: []const u8) Error!void {
    std.debug.assert(std.mem.startsWith(u8, line, "const "));
    std.debug.assert(compiler.template.compiling);

    const equals = std.mem.indexOf(u8, line, " = ") orelse {
        return compiler.fail("unsupported frontmatter statement: {s}", .{line});
    };
    const name = std.mem.trim(u8, line["const ".len..equals], " \t");
    var rhs = std.mem.trim(u8, line[equals + " = ".len ..], " \t");

    if (std.mem.endsWith(u8, rhs, ";")) {
        rhs = std.mem.trim(u8, rhs[0 .. rhs.len - 1], " \t");
    }

    if (!expression.is_identifier(name)) {
        return compiler.fail("`{s}` is not a plain identifier", .{name});
    }

    if (std.mem.eql(u8, rhs, "Date.now()")) {
        return compiler.fail(
            "Date.now() does not say when: write Publr.build.now() or Publr.request.now()",
            .{},
        );
    }

    const build = std.mem.startsWith(u8, rhs, "Publr.build.");
    const request = std.mem.startsWith(u8, rhs, "Publr.request.");

    if (build or request) {
        return publr_call(compiler, name, rhs);
    }

    if (std.mem.startsWith(u8, rhs, "Publr.")) {
        return compiler.fail(
            "Publr.* is namespaced by when the answer is known: Publr.build.* or " ++
                "Publr.request.*, not {s}",
            .{rhs},
        );
    }

    if (std.mem.startsWith(u8, rhs, "props.entry.")) {
        return entry_prop(compiler, name, rhs["props.entry.".len..]);
    }

    if (std.mem.startsWith(u8, rhs, "props.")) {
        return prop_text(compiler, name, line, rhs["props.".len..]);
    }

    if (std.mem.indexOf(u8, rhs, ".data.")) |at| {
        return data_access(compiler, name, line, rhs, @intCast(at));
    }

    return compiler.fail("unsupported frontmatter statement: {s}", .{line});
}

/// `const section = props.entry.section;`: a prop that is an entry, which every call
/// site has to pass as one (`<Section section={item} />`).
fn entry_prop(compiler: *Compiler, name: []const u8, field: []const u8) Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(compiler.entry_props.items.len <= compile.props_max);

    if (compiler.template.kind != .layout) {
        return compiler.fail("`props` belong to layouts; pages read `ctx`", .{});
    }

    if (!expression.is_identifier(field) or std.mem.eql(u8, field, "children")) {
        return compiler.fail("`props.entry.{s}` is not a prop name", .{field});
    }

    for (compiler.prop_names.items) |existing| {
        if (std.mem.eql(u8, existing, field)) {
            return compiler.fail("props.{s} is declared twice", .{field});
        }
    }

    if (compiler.prop_names.items.len == compile.props_max) {
        return compiler.fail("a template reads more than {d} props", .{compile.props_max});
    }

    try compiler.prop_names.append(compiler.arena, field);
    try compiler.entry_props.append(compiler.arena, field);
    try declare(compiler, name, .entry, .{ .entry_prop = field });
}

/// `const mode = props.mode ?? 'card';`: a string prop with its fallback, as a local.
fn prop_text(compiler: *Compiler, name: []const u8, line: []const u8, rest: []const u8) Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(compiler.prop_names.items.len <= compile.props_max);

    if (compiler.template.kind != .layout) {
        return compiler.fail("`props` belong to layouts; pages read `ctx`", .{});
    }

    const nullish = std.mem.indexOf(u8, rest, "??") orelse {
        return compiler.fail("a prop in the frontmatter needs a ?? fallback: {s}", .{line});
    };
    const key = std.mem.trim(u8, rest[0..nullish], " \t");

    if (!expression.is_identifier(key) or std.mem.eql(u8, key, "children")) {
        return compiler.fail("`props.{s}` is not a prop name", .{key});
    }

    for (compiler.entry_props.items) |existing| {
        if (std.mem.eql(u8, existing, key)) {
            return compiler.fail("props.{s} is an entry, not a string", .{key});
        }
    }

    const fallback_text = std.mem.trim(u8, rest[nullish + 2 ..], " \t");
    const fallback = try expression.js_string(compiler, fallback_text);
    var known = false;

    for (compiler.prop_names.items) |existing| {
        known = known or std.mem.eql(u8, existing, key);
    }

    if (!known) {
        if (compiler.prop_names.items.len == compile.props_max) {
            return compiler.fail("a template reads more than {d} props", .{compile.props_max});
        }

        try compiler.prop_names.append(compiler.arena, key);
    }

    try declare(compiler, name, .string, .{ .prop_text = .{ .key = key, .fallback = fallback } });
}

fn is_dump(line: []const u8) bool {
    std.debug.assert(line.len > 0);

    const forms = [_][]const u8{ "dd();", "dd()", "dump();", "dump()" };

    for (forms) |form| {
        if (std.mem.eql(u8, line, form)) {
            return true;
        }
    }

    return false;
}

/// `const body = post.data.content ?? '';` a text; `const rows = post.data.rows;` a repeater's
/// rows as a collection.
fn data_access(
    compiler: *Compiler,
    name: []const u8,
    line: []const u8,
    rhs: []const u8,
    at: u32,
) Error!void {
    std.debug.assert(at < rhs.len);
    std.debug.assert(std.mem.startsWith(u8, rhs[at..], ".data."));

    const object = rhs[0..at];
    const owner = compiler.find_local(object) orelse {
        return compiler.fail("`{s}` is not a frontmatter entry", .{object});
    };

    if (owner.type != .entry) {
        return compiler.fail(
            "`.data` belongs to an entry; `{s}` is a {s}",
            .{ object, @tagName(owner.type) },
        );
    }

    const rest = rhs[at + ".data.".len ..];
    const nullish = std.mem.indexOf(u8, rest, "??") orelse {
        if (!expression.is_identifier(rest)) {
            return compiler.fail(".data access needs a ?? fallback: {s}", .{line});
        }

        return declare(compiler, name, .collection, .{
            .data_items = .{ .object = object, .key = rest },
        });
    };
    const key = std.mem.trim(u8, rest[0..nullish], " \t");

    if (!expression.is_identifier(key)) {
        return compiler.fail("`{s}` is not a field name", .{key});
    }

    const fallback_text = std.mem.trim(u8, rest[nullish + 2 ..], " \t");
    const fallback = try expression.js_string(compiler, fallback_text);

    try declare(compiler, name, .string, .{
        .data_text = .{ .object = object, .key = key, .fallback = fallback },
    });
}

fn declare(compiler: *Compiler, name: []const u8, kind: Type, value: ast.Decl.Value) Error!void {
    std.debug.assert(name.len > 0);

    try compiler.decls.append(compiler.arena, .{ .name = name, .type = kind, .value = value });
    try compiler.add_local(name, kind);

    std.debug.assert(compiler.decls.items.len <= compiler.locals.items.len);
}

/// `const name = Publr.<build|request>.<call>;`: the same evaluation either way (`ctx`
/// answers at whatever time the render runs); what differs is that a `request` read
/// makes the template dynamic.
fn publr_call(compiler: *Compiler, name: []const u8, rhs: []const u8) Error!void {
    const template = compiler.template;
    const request = std.mem.startsWith(u8, rhs, "Publr.request.");
    const prefix_len = if (request) "Publr.request.".len else "Publr.build.".len;
    const call = rhs[prefix_len..];

    std.debug.assert(request or std.mem.startsWith(u8, rhs, "Publr.build."));
    std.debug.assert(call.len < rhs.len);

    if (request and !compiler.context.forced_dynamic(template.rel)) {
        return compiler.fail(
            "{s} reads the dynamic API (Publr.request), so it is dynamic and its name " ++
                "has to say so. Rename it to {s}",
            .{ template.rel, try compile.dynamic_name(compiler.arena, template.rel) },
        );
    }

    const mixed = (request and template.uses_build) or (!request and template.reads_request);

    if (mixed) {
        return compiler.fail(
            "Template {s} is using the dynamic API (Publr.request), so it renders per " ++
                "request. Read everything through the dynamic API: Publr.request.{s}",
            .{ template.rel, call },
        );
    }

    if (request) {
        template.dynamic = true;
        template.reads_request = true;
    } else {
        template.uses_build = true;
    }

    template.reads_data = true;

    if (std.mem.eql(u8, call, "now()")) {
        return declare(compiler, name, .string, if (request) .request_now else .build_now);
    }

    if (std.mem.eql(u8, call, "session")) {
        return session_call(compiler, name, request);
    }

    if (call_of(call, "header(")) |literal| {
        return header_call(compiler, name, request, literal);
    }

    if (call_of(call, "cookie(")) |literal| {
        return cookie_call(compiler, name, request, literal);
    }

    if (call_of(call, "random(")) |bound| {
        return random_call(compiler, name, request, call, bound);
    }

    return visitor_call(compiler, name, rhs, request, call);
}

/// `Publr.request.redirect(…);` and `Publr.request.call(…);` on their own: an action the
/// page takes, in its place among the declarations, with no value to name. A read on its
/// own would do nothing, so it needs its `const`.
fn action(compiler: *Compiler, line: []const u8) Error!void {
    std.debug.assert(std.mem.startsWith(u8, line, "Publr."));

    const rhs = std.mem.trim(u8, std.mem.trimEnd(u8, line, ";"), " \t");
    const at = std.mem.indexOfScalar(u8, rhs, '.') orelse rhs.len;
    const after = rhs[@min(at + 1, rhs.len)..];
    const dot = std.mem.indexOfScalar(u8, after, '.') orelse after.len;
    const call = after[@min(dot + 1, after.len)..];
    const is_action = std.mem.startsWith(u8, call, "redirect(") or
        std.mem.startsWith(u8, call, "call(");
    const known = std.mem.startsWith(u8, rhs, "Publr.request.") or
        std.mem.startsWith(u8, rhs, "Publr.build.");

    if (!known) {
        return compiler.fail(
            "Publr.* is namespaced by when the answer is known: Publr.build.* or " ++
                "Publr.request.*, not {s}",
            .{rhs},
        );
    }

    if (!is_action) {
        return compiler.fail("`{s}` reads a value and does nothing on its own: " ++
            "name it, const value = {s}", .{ rhs, rhs });
    }

    const name = std.fmt.allocPrint(
        compiler.arena,
        "action_{d}",
        .{compiler.decls.items.len},
    ) catch return error.OutOfMemory;

    std.debug.assert(expression.is_identifier(name));

    return publr_call(compiler, name, rhs);
}

/// What only a visitor's request has: its account's fields, an operation it runs, a
/// redirect it answers; else the reads of records.
fn visitor_call(
    compiler: *Compiler,
    name: []const u8,
    rhs: []const u8,
    request: bool,
    call: []const u8,
) Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(call.len < rhs.len);

    if (call_of(call, "call(")) |literal| {
        return operation_call(compiler, name, request, literal);
    }

    if (call_of(call, "userField(")) |literal| {
        return user_field_call(compiler, name, request, literal);
    }

    if (call_of(call, "redirect(")) |target| {
        return redirect_call(compiler, name, request, target);
    }

    return data_call(compiler, name, rhs, call);
}

/// `const go = Publr.request.redirect(target);`: a page answers with a redirect to the
/// path `target` gives, any string expression over what came before, or renders as usual
/// when it gives nothing. Only a page, and only per request: a build writes files.
fn redirect_call(
    compiler: *Compiler,
    name: []const u8,
    request: bool,
    text: []const u8,
) Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(compiler.template.compiling);

    if (!request) {
        return compiler.fail(
            "Publr.build.redirect() — a build writes files and cannot redirect: " ++
                "Publr.request.redirect()",
            .{},
        );
    }

    if (compiler.template.kind != .page) {
        return compiler.fail("only a page can redirect, not a layout or a component", .{});
    }

    const target = try expression.expression(compiler, text);

    if (target.type != .string and target.type != .opt_string) {
        return compiler.fail("redirect() takes a path, a string: empty for no redirect", .{});
    }

    try declare(compiler, name, .string, .{ .redirect = target });
}

/// The reads of records: an entry, a collection, or what an entry points at.
fn data_call(compiler: *Compiler, name: []const u8, rhs: []const u8, call: []const u8) Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(call.len < rhs.len);

    if (call_of(call, "getEntry(")) |args| {
        return entry_call(compiler, name, args);
    }

    if (call_of(call, "getCollection(")) |args| {
        return collection_call(compiler, name, args);
    }

    if (call_of(call, "getReferences(")) |args| {
        return references_call(compiler, name, args, .many);
    }

    if (call_of(call, "getReference(")) |args| {
        return references_call(compiler, name, args, .one);
    }

    return compiler.fail("unsupported Publr call: {s}", .{rhs});
}

const Arity = enum { one, many };

/// `getReferences(page, 'sections')`: the records a reference field of an entry points
/// at, a collection in the order stored; a target that is not live and public is left
/// out. `getReference(page, 'settings')`: the first of them as an entry, blank when
/// there is none.
fn references_call(
    compiler: *Compiler,
    name: []const u8,
    args: []const u8,
    arity: Arity,
) Error!void {
    std.debug.assert(name.len > 0);

    const comma = expression.top_level(args, ',') orelse {
        return compiler.fail(
            "getReferences takes an entry and a field name: getReferences(page, 'sections')",
            .{},
        );
    };
    const object = std.mem.trim(u8, args[0..comma], " \t");
    const key = try expression.js_string(compiler, std.mem.trim(u8, args[comma + 1 ..], " \t"));
    const owner = compiler.find_local(object) orelse {
        return compiler.fail("`{s}` is not a frontmatter entry", .{object});
    };

    if (owner.type != .entry) {
        return compiler.fail(
            "getReferences follows a field of an entry; `{s}` is a {s}",
            .{ object, @tagName(owner.type) },
        );
    }

    if (!expression.is_identifier(key)) {
        return compiler.fail("`{s}` is not a field name", .{key});
    }

    std.debug.assert(object.len > 0);

    if (arity == .one) {
        return declare(compiler, name, .entry, .{
            .reference = .{ .object = object, .key = key },
        });
    }

    try declare(compiler, name, .collection, .{
        .references = .{ .object = object, .key = key },
    });
}

/// The trimmed argument text of `<prefix>...)`, when `call` is that call.
fn call_of(call: []const u8, prefix: []const u8) ?[]const u8 {
    std.debug.assert(prefix.len > 1);
    std.debug.assert(prefix[prefix.len - 1] == '(');

    if (!std.mem.startsWith(u8, call, prefix) or !std.mem.endsWith(u8, call, ")")) {
        return null;
    }

    return std.mem.trim(u8, call[prefix.len .. call.len - 1], " \t");
}

fn session_call(compiler: *Compiler, name: []const u8, request: bool) Error!void {
    std.debug.assert(name.len > 0);

    if (!request) {
        return compiler.fail(
            "Publr.build.session — who is signed in is only known per request: " ++
                "Publr.request.session",
            .{},
        );
    }

    return declare(compiler, name, .session, .session);
}

fn header_call(
    compiler: *Compiler,
    name: []const u8,
    request: bool,
    literal: []const u8,
) Error!void {
    std.debug.assert(name.len > 0);

    if (!request) {
        return compiler.fail(
            "Publr.build.header() — headers are only known per request: Publr.request.header()",
            .{},
        );
    }

    const header = try expression.js_string(compiler, literal);

    if (header.len == 0) {
        return compiler.fail("header() needs a nonempty name", .{});
    }

    return declare(compiler, name, .opt_string, .{ .header = header });
}

fn cookie_call(
    compiler: *Compiler,
    name: []const u8,
    request: bool,
    literal: []const u8,
) Error!void {
    std.debug.assert(name.len > 0);

    if (!request) {
        return compiler.fail(
            "Publr.build.cookie() — cookies are only known per request: Publr.request.cookie()",
            .{},
        );
    }

    const cookie = try expression.js_string(compiler, literal);

    if (cookie.len == 0) {
        return compiler.fail("cookie() needs a nonempty name", .{});
    }

    return declare(compiler, name, .opt_string, .{ .cookie = cookie });
}

/// `const seen = Publr.request.call('app.cloud.welcome');`: the page runs an operation as the
/// visitor who opened it. Only an operation that allows frontmatter calls runs this way
/// (the server refuses the rest), and never for a prefetch: opening the page is the event.
fn operation_call(
    compiler: *Compiler,
    name: []const u8,
    request: bool,
    literal: []const u8,
) Error!void {
    std.debug.assert(name.len > 0);

    if (!request) {
        return compiler.fail(
            "Publr.build.call() — a build writes files and runs no operation: " ++
                "Publr.request.call()",
            .{},
        );
    }

    const operation = try expression.js_string(compiler, literal);
    // What apps call is `app.<feature>.<verb>`: the namespace is everything before the verb.
    const app = std.mem.startsWith(u8, operation, "app.");
    const inside = if (app) operation["app.".len..] else operation;
    const dot = std.mem.indexOfScalar(u8, inside, '.') orelse inside.len;
    const namespace = inside[0..dot];
    const verb = if (dot < inside.len) inside[dot + 1 ..] else "";

    if (!expression.is_identifier(namespace) or !expression.is_identifier(verb)) {
        return compiler.fail("call() names an operation, `<namespace>.<verb>` or " ++
            "`app.<feature>.<verb>`: {s}", .{operation});
    }

    return declare(compiler, name, .entry, .{ .call = operation });
}

/// `Publr.request.userField('cloud.welcomed')`: one custom field of the signed-in user,
/// named `<group>.<field>` as the user's document holds it.
fn user_field_call(
    compiler: *Compiler,
    name: []const u8,
    request: bool,
    literal: []const u8,
) Error!void {
    std.debug.assert(name.len > 0);

    if (!request) {
        return compiler.fail(
            "Publr.build.userField() — who is signed in is only known per request: " ++
                "Publr.request.userField()",
            .{},
        );
    }

    const path = try expression.js_string(compiler, literal);
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
    const group = path[0..dot];
    const field = if (dot < path.len) path[dot + 1 ..] else "";

    if (!expression.is_identifier(group) or !expression.is_identifier(field)) {
        return compiler.fail("userField() names `<group>.<field>`: {s}", .{path});
    }

    return declare(compiler, name, .opt_string, .{ .user_field = path });
}

fn random_call(
    compiler: *Compiler,
    name: []const u8,
    request: bool,
    call: []const u8,
    bound: []const u8,
) Error!void {
    std.debug.assert(name.len > 0);

    if (!request) {
        return compiler.fail(
            "Publr.build.random() — a build is deterministic: Publr.request.random()",
            .{},
        );
    }

    const positive = expression.is_number(bound) and !std.mem.eql(u8, bound, "0");
    const value = std.fmt.parseInt(u32, bound, 10) catch 0;

    if (!positive or value == 0) {
        return compiler.fail("Publr.request.random(n) takes a positive number: {s}", .{call});
    }

    return declare(compiler, name, .int, .{ .random = value });
}

/// `getEntry()`: the record the route names. `getEntry({ type: 'post' })` reads another
/// type at this route's slug, or, where there is no slug, the type's one record (the
/// site's settings); `getEntry({ type: 'page', slug: 'home' })` one record by slug, from
/// anywhere.
fn entry_call(compiler: *Compiler, name: []const u8, args: []const u8) Error!void {
    std.debug.assert(name.len > 0);

    var query = try entry_options(compiler, args);

    if (query.slug != null) {
        if (query.type_id.len == 0) {
            return compiler.fail("getEntry({{ slug }}) names its type too: {{ type, slug }}", .{});
        }

        return declare(compiler, name, .entry, .{ .entry = query });
    }

    if (query.type_id.len > 0 and !at_slug_route(compiler.template.rel)) {
        query.first = true;

        return declare(compiler, name, .entry, .{ .entry = query });
    }

    const route = try route_context(compiler);

    if (!route.is_entry) {
        return compiler.fail(
            "getEntry() belongs in a [slug] template (or names a record: " ++
                "getEntry({{ type: 'page', slug: 'home' }}))",
            .{},
        );
    }

    if (query.type_id.len == 0) {
        query.type_id = route.type_id;
    }

    std.debug.assert(query.type_id.len > 0);

    return declare(compiler, name, .entry, .{ .entry = query });
}

fn at_slug_route(rel: []const u8) bool {
    std.debug.assert(rel.len > 0);

    return std.mem.startsWith(u8, rel, "content/") and
        std.mem.endsWith(u8, compile.stem_of(rel), "[slug]");
}

/// `{ type: 'post', slug: 'hello' }`: both string literals, both optional.
fn entry_options(compiler: *Compiler, args: []const u8) Error!ast.Decl.EntryQuery {
    var query: ast.Decl.EntryQuery = .{ .type_id = "" };

    if (args.len == 0) {
        return query;
    }

    if (!std.mem.startsWith(u8, args, "{") or !std.mem.endsWith(u8, args, "}")) {
        return compiler.fail("getEntry options must be an object literal: {s}", .{args});
    }

    std.debug.assert(args.len >= 2);

    var pairs = std.mem.splitScalar(u8, args[1 .. args.len - 1], ',');
    var count: u32 = 0;

    while (pairs.next()) |pair| : (count += 1) {
        const trimmed = std.mem.trim(u8, pair, " \t");

        if (trimmed.len == 0) {
            continue;
        }

        if (count == compile.props_max) {
            return compiler.fail("getEntry takes fewer options than that", .{});
        }

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse {
            return compiler.fail("unsupported getEntry option: {s}", .{trimmed});
        };
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const literal = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        const value = try expression.js_string(compiler, literal);

        if (std.mem.eql(u8, key, "type")) {
            query.type_id = value;
        } else if (std.mem.eql(u8, key, "slug")) {
            query.slug = value;
        } else {
            return compiler.fail(
                "unsupported getEntry option: {s} (type and slug are the options)",
                .{key},
            );
        }
    }

    return query;
}

fn collection_call(compiler: *Compiler, name: []const u8, args: []const u8) Error!void {
    std.debug.assert(name.len > 0);

    var query = try collection_options(compiler, args);

    if (query.type_id.len == 0) {
        const route = try route_context(compiler);

        if (route.is_entry) {
            return compiler.fail(
                "getCollection() belongs in an index template (or names its type: " ++
                    "{{ type: 'post' }})",
                .{},
            );
        }

        query.type_id = route.type_id;
    }

    return declare(compiler, name, .collection, .{ .query = query });
}

const RouteContext = struct { type_id: []const u8, is_entry: bool };

/// `content/posts/[slug].publr` is a single "post"; `content/pages/index.publr` the
/// "page" collection; `content/[slug].publr` the core "page" type.
fn route_context(compiler: *Compiler) Error!RouteContext {
    const rel = compiler.template.rel;

    std.debug.assert(rel.len > 0);

    if (!std.mem.startsWith(u8, rel, "content/")) {
        return compiler.fail(
            "a component has no position in content/ — name the type: " ++
                "getCollection({{ type: 'post' }})",
            .{},
        );
    }

    const path = compile.stem_of(rel)["content/".len..];
    const cut = std.mem.lastIndexOfScalar(u8, path, '/');
    const basename = if (cut) |at| path[at + 1 ..] else path;
    const dir = if (cut) |at| path[0..at] else "";
    const last_dir = if (std.mem.lastIndexOfScalar(u8, dir, '/')) |at| dir[at + 1 ..] else dir;
    const is_entry = std.mem.eql(u8, basename, "[slug]");

    if (!is_entry and !std.mem.eql(u8, basename, "index")) {
        return compiler.fail(
            "Publr context calls need an index or [slug] template, not {s}",
            .{basename},
        );
    }

    if (last_dir.len == 0) {
        if (!is_entry) {
            return compiler.fail(
                "getCollection() needs a collection directory (content/<type>s/index.publr) " ++
                    "or a type option",
                .{},
            );
        }

        return .{ .type_id = "page", .is_entry = true };
    }

    std.debug.assert(last_dir.len > 0);

    return .{ .type_id = singular(last_dir), .is_entry = is_entry };
}

fn singular(dir: []const u8) []const u8 {
    std.debug.assert(dir.len > 0);

    if (dir.len > 1 and dir[dir.len - 1] == 's') {
        return dir[0 .. dir.len - 1];
    }

    return dir;
}

/// `{ type: 'post', limit: 100, offset: 10 }`: the type, and the numbers the store's
/// query takes.
fn collection_options(compiler: *Compiler, args: []const u8) Error!ast.Decl.Query {
    var query: ast.Decl.Query = .{ .type_id = "" };

    if (args.len == 0) {
        return query;
    }

    if (!std.mem.startsWith(u8, args, "{") or !std.mem.endsWith(u8, args, "}")) {
        return compiler.fail("getCollection options must be an object literal: {s}", .{args});
    }

    std.debug.assert(args.len >= 2);

    var pairs = std.mem.splitScalar(u8, args[1 .. args.len - 1], ',');
    var count: u32 = 0;

    while (pairs.next()) |pair| : (count += 1) {
        const trimmed = std.mem.trim(u8, pair, " \t");

        if (trimmed.len == 0) {
            continue;
        }

        if (count == compile.props_max) {
            return compiler.fail("getCollection takes fewer options than that", .{});
        }

        try collection_option(compiler, &query, trimmed);
    }

    return query;
}

fn collection_option(compiler: *Compiler, query: *ast.Decl.Query, pair: []const u8) Error!void {
    std.debug.assert(pair.len > 0);

    const colon = std.mem.indexOfScalar(u8, pair, ':') orelse {
        return compiler.fail("unsupported getCollection option: {s}", .{pair});
    };
    const key = std.mem.trim(u8, pair[0..colon], " \t");
    const value = std.mem.trim(u8, pair[colon + 1 ..], " \t");

    if (!expression.is_identifier(key)) {
        return compiler.fail("unsupported getCollection option: {s}", .{pair});
    }

    if (std.mem.eql(u8, key, "type")) {
        const quoted = value.len >= 2 and (value[0] == '\'' or value[0] == '"');

        if (!quoted) {
            return compiler.fail("getCollection's type is a string literal: {s}", .{pair});
        }

        query.type_id = value[1 .. value.len - 1];

        return;
    }

    const number = std.fmt.parseInt(u32, value, 10) catch null;

    if (!expression.is_number(value) or number == null) {
        return compiler.fail("getCollection's {s} is a number: {s}", .{ key, pair });
    }

    if (std.mem.eql(u8, key, "limit")) {
        query.limit = number;
    } else if (std.mem.eql(u8, key, "offset")) {
        query.offset = number;
    } else {
        return compiler.fail(
            "unsupported getCollection option: {s} (limit and offset are the options)",
            .{key},
        );
    }
}

/// `import Base from '../layouts/base.publr';`: resolved against this template's
/// directory to another template, called as `<Base>`.
fn import_line(compiler: *Compiler, line: []const u8) Error!void {
    std.debug.assert(std.mem.startsWith(u8, line, "import "));

    const from = std.mem.indexOf(u8, line, " from ") orelse {
        return compiler.fail("unsupported import: {s}", .{line});
    };
    const local_name = std.mem.trim(u8, line["import ".len..from], " \t");
    var spec = std.mem.trim(u8, line[from + " from ".len ..], " \t");

    if (std.mem.endsWith(u8, spec, ";")) {
        spec = std.mem.trim(u8, spec[0 .. spec.len - 1], " \t");
    }

    const capitalized = expression.is_identifier(local_name) and std.ascii.isUpper(local_name[0]);

    if (!capitalized) {
        return compiler.fail("imports bind a capitalized component name: {s}", .{line});
    }

    const quoted = spec.len >= 2 and (spec[0] == '\'' or spec[0] == '"') and
        spec[spec.len - 1] == spec[0];

    if (!quoted) {
        return compiler.fail("unsupported import: {s}", .{line});
    }

    const path = spec[1 .. spec.len - 1];

    if (std.mem.endsWith(u8, path, ".ptsx") or std.mem.endsWith(u8, path, ".pjsx")) {
        return import_pjsx(compiler, local_name, path);
    }

    if (!std.mem.endsWith(u8, path, ".publr")) {
        return compiler.fail(
            "only .publr templates and .ptsx components are importable: {s}",
            .{path},
        );
    }

    const resolved = compile.resolve_path(compiler.arena, compiler.template.rel, path) catch |err| {
        if (err == error.Unsupported) {
            return compiler.fail("import of {s} leaves the app", .{path});
        }

        return err;
    };

    for (compiler.context.templates, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate.rel, resolved)) {
            try compiler.imports.append(compiler.arena, .{
                .local = local_name,
                .index = @intCast(index),
            });

            return;
        }
    }

    return compiler.fail("import of {s} — no such template ({s})", .{ path, resolved });
}

/// A PJSX component: not a template but a module the PJSX toolchain lowered, called
/// from here. Resolved by file stem, because where the `.ptsx` sits on disk is that
/// toolchain's business.
fn import_pjsx(compiler: *Compiler, local_name: []const u8, path: []const u8) Error!void {
    std.debug.assert(local_name.len > 0);

    const stem = compile.file_stem(path);
    const components = compiler.context.options.pjsx;

    for (components, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate.name, stem)) {
            try compiler.imports.append(compiler.arena, .{
                .local = local_name,
                .pjsx = @intCast(index),
            });

            return;
        }
    }

    if (components.len == 0) {
        return compiler.fail(
            "import of {s} — this app has no PJSX components (nothing was compiled for it)",
            .{path},
        );
    }

    return compiler.fail("import of {s} — no PJSX component named {s}", .{ path, stem });
}
