//! Lowers JSX only; ECMAScript expressions and statements keep their source semantics.
const std = @import("std");
const syntax = @import("pjsx_syntax").template_syntax;
const core = @import("../compile.zig");
const ast = @import("../ast.zig");
const markup = @import("../markup.zig");
const VM = @import("vm.zig").VM;
const Compiler = core.Compiler;
const Node = syntax.ast.Node;

pub fn frontmatter(compiler: *Compiler, source: []const u8) core.Error!void {
    std.debug.assert(compiler.template.compiling);
    compiler.js_frontmatter = lower(compiler, source) catch |err| return failure(compiler, err);
}

pub fn expression(compiler: *Compiler, source: []const u8) core.Error!ast.Expr {
    std.debug.assert(compiler.template.compiling);

    if (compiler.js_expressions.items.len == 4096) {
        return compiler.fail("too many expressions", .{});
    }

    const wrapped = try std.fmt.allocPrint(compiler.arena, "({s})", .{source});
    const lowered = lower(compiler, wrapped) catch |err| return failure(compiler, err);
    const index: u32 = @intCast(compiler.js_expressions.items.len);
    try compiler.js_expressions.append(compiler.arena, lowered);
    return .{ .type = .javascript, .node = .{ .javascript = index } };
}

fn failure(compiler: *Compiler, err: anyerror) core.Error {
    std.debug.assert(compiler.template.compiling);

    if (err == error.OutOfMemory) {
        return error.OutOfMemory;
    }

    if (compiler.failure.len > 0) {
        return error.Unsupported;
    }

    return compiler.fail("JavaScript syntax: {s}", .{syntax.lastError()});
}

pub fn finish(compiler: *Compiler) core.Error!void {
    std.debug.assert(compiler.template.compiling);
    const template = compiler.template;

    if (template.reads_request and !compiler.context.forced_dynamic(template.rel)) {
        return compiler.fail(
            "Publr.request requires {s}",
            .{try core.dynamic_name(compiler.arena, template.rel)},
        );
    }

    if (template.reads_request and template.uses_build) {
        return compiler.fail(
            "use one API namespace per template: Publr.build or Publr.request",
            .{},
        );
    }

    var source: std.Io.Writer.Allocating = .init(compiler.arena);
    const out = &source.writer;

    for (compiler.js_imports.items) |item| {
        try out.print("{s}\n", .{item});
    }

    const is_module = compiler.js_imports.items.len > 0;
    const prefix = if (is_module) "export default function" else "(function";
    try out.print("{s}(props, Publr, $publr) {{\n", .{prefix});
    try out.writeAll("\"use strict\";\n");
    try out.writeAll(compiler.js_frontmatter);
    try out.writeAll("\nreturn [\n");

    for (compiler.js_expressions.items) |item| {
        try out.print("() => {s},\n", .{item});
    }

    try out.writeAll(if (is_module) "];\n}" else "];\n})");
    var vm = try VM.init(compiler.arena);
    defer vm.deinit();
    compiler_vm(compiler, &vm);
    template.javascript = vm.compile_kind(source.written(), template.rel, is_module) catch |err| {
        if (err == error.OutOfMemory) {
            return error.OutOfMemory;
        }

        return compiler.fail("{s}", .{vm.failure});
    };
    template.javascript_embeds = compiler.js_embeds.items;
    template.javascript_modules = compiler.js_modules.items;
}

pub fn module(compiler: *Compiler) core.Error!void {
    std.debug.assert(compiler.template.compiling);
    compiler.javascript = true;
    const source = lower(
        compiler,
        compiler.template.source,
    ) catch |err| return failure(compiler, err);
    var vm = try VM.init(compiler.arena);
    defer vm.deinit();
    compiler_vm(compiler, &vm);
    compiler.template.javascript = vm.compile_kind(
        source,
        compiler.template.rel,
        true,
    ) catch |err| {
        if (err == error.OutOfMemory) {
            return error.OutOfMemory;
        }

        return compiler.fail("{s}", .{vm.failure});
    };
    compiler.template.javascript_modules = compiler.js_modules.items;
    compiler.template.compiling = false;
    compiler.template.compiled = true;
}

fn compiler_vm(compiler: *Compiler, vm: *VM) void {
    std.debug.assert(compiler.template.compiling);
    vm.host = compiler;
    vm.module_load = module_source;
    vm.module_source = true;
}

fn module_source(userdata: *anyopaque, _: *VM, name: []const u8) anyerror![]const u8 {
    std.debug.assert(name.len > 0);
    const compiler: *Compiler = @ptrCast(@alignCast(userdata));

    for (compiler.context.templates) |template| {
        if (template.kind != .module or !std.mem.eql(u8, template.rel, name)) {
            continue;
        }

        var copy = template;
        copy.compiling = true;
        var helper = compiler.*;
        helper.template = &copy;
        helper.js_modules = .empty;
        helper.js_imports = .empty;
        return lower(&helper, copy.source);
    }

    return error.MissingModule;
}

fn lower(compiler: *Compiler, source: []const u8) anyerror![]const u8 {
    std.debug.assert(compiler.template.compiling);
    const stripped = try syntax.dom.stripTypes(compiler.arena, source, compiler.template.rel);
    const tree = try syntax.syntax.parse(compiler.arena, stripped, compiler.template.rel);
    var output: std.Io.Writer.Allocating = .init(compiler.arena);
    var emitter: Emitter = .{ .compiler = compiler, .source = stripped, .out = &output.writer };
    try emitter.node(tree);
    return output.written();
}

const Emitter = struct {
    compiler: *Compiler,
    source: []const u8,
    out: *std.Io.Writer,
    depth: u32 = 0,
    cursor: u32 = 0,

    fn node(emitter: *Emitter, value: *Node) anyerror!void {
        std.debug.assert(emitter.compiler.template.compiling);

        if (emitter.depth == core.nesting_max) {
            return emitter.compiler.fail("JavaScript nests too deeply", .{});
        }

        emitter.depth += 1;
        defer emitter.depth -= 1;
        try emitter.inspect(value);

        switch (value.type) {
            .ImportDeclaration => return emitter.import_node(value),
            .ExportAllDeclaration => return emitter.module_import(value),
            .ExportNamedDeclaration => if (value.source != null) {
                return emitter.module_import(value);
            },
            .JSXElement => return emitter.element(value),
            .JSXFragment => {
                if (emitter.compiler.template.kind == .module) {
                    return emitter.compiler.fail("JSX belongs in .publr components", .{});
                }

                return emitter.children(value.children);
            },
            .JSXExpressionContainer => {
                if (value.expression.?.type == .JSXEmptyExpression) {
                    return emitter.out.writeAll("null");
                }

                return emitter.node(value.expression.?);
            },
            .JSXText => {
                try emitter.out.writeAll("$publr.text(");
                try emitter.quoted(emitter.source[value.start..value.end]);
                return emitter.out.writeAll(")");
            },
            else => {},
        }

        const saved = emitter.cursor;
        emitter.cursor = value.start;
        try syntax.ast.eachChild(value, emitter, child);
        try emitter.out.writeAll(emitter.source[emitter.cursor..value.end]);
        emitter.cursor = saved;
    }

    fn child(emitter: *Emitter, value: *Node) anyerror!void {
        std.debug.assert(emitter.compiler.template.compiling);

        if (value.start < emitter.cursor) {
            return;
        }

        try emitter.out.writeAll(emitter.source[emitter.cursor..value.start]);
        try emitter.node(value);
        emitter.cursor = value.end;
    }

    fn quoted(emitter: *Emitter, text: []const u8) !void {
        try std.json.Stringify.value(text, .{}, emitter.out);
    }

    fn import_node(emitter: *Emitter, value: *Node) anyerror!void {
        std.debug.assert(emitter.compiler.template.compiling);
        const path = value.source.?.value.string;

        if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".ts")) {
            return emitter.module_import(value);
        }

        if (emitter.compiler.template.kind == .module) {
            return emitter.compiler.fail("helper modules import .js or .ts files", .{});
        }

        if (value.specifiers.len != 1 or value.specifiers[0].type != .ImportDefaultSpecifier) {
            return emitter.compiler.fail("template imports take one default component", .{});
        }

        const line = try std.fmt.allocPrint(emitter.compiler.arena, "import {s} from '{s}';", .{
            value.specifiers[0].local.?.name, value.source.?.value.string,
        });
        try @import("../frontmatter.zig").import_line(emitter.compiler, line);
    }

    fn module_import(emitter: *Emitter, value: *Node) anyerror!void {
        std.debug.assert(emitter.compiler.template.compiling);
        const compiler = emitter.compiler;
        const path = value.source.?.value.string;

        if (!std.mem.startsWith(u8, path, "./") and !std.mem.startsWith(u8, path, "../")) {
            return compiler.fail("helper imports are relative .js or .ts files: {s}", .{path});
        }

        const resolved = try @import("../imports.zig").resolve(
            compiler.arena,
            compiler.template.rel,
            path,
            compiler.context.options.folder,
        );
        var found: ?u32 = null;

        for (compiler.context.templates, 0..) |candidate, index| {
            if (candidate.kind == .module and std.mem.eql(u8, candidate.rel, resolved)) {
                found = @intCast(index);
            }
        }

        const index = found orelse return compiler.fail("missing helper module {s}", .{resolved});
        try compiler.js_modules.append(compiler.arena, index);
        compiler.template.javascript_reads = true;
        compiler.template.reads_data = true;
        const prefix = emitter.source[value.start..value.source.?.start];
        const suffix = emitter.source[value.source.?.end..value.end];
        const path_literal = try std.json.Stringify.valueAlloc(compiler.arena, resolved, .{});
        const statement = try std.fmt.allocPrint(
            compiler.arena,
            "{s}{s}{s}",
            .{ prefix, path_literal, suffix },
        );

        if (compiler.template.kind == .module) {
            try emitter.out.writeAll(statement);
        } else try compiler.js_imports.append(compiler.arena, statement);
    }

    fn inspect(emitter: *Emitter, value: *Node) !void {
        std.debug.assert(emitter.compiler.template.compiling);
        const compiler = emitter.compiler;

        if (value.isIdentifier("Publr")) {
            compiler.template.reads_data = true;
            compiler.template.javascript_reads = true;
        }

        if (value.type == .Identifier and std.mem.startsWith(u8, value.name, "$publr")) {
            return compiler.fail("$publr is reserved by the template compiler", .{});
        }

        if (value.type == .ImportExpression) {
            return compiler.fail("dynamic imports are not template dependencies", .{});
        }

        if (value.type != .MemberExpression or !value.object.?.isIdentifier("Publr")) {
            return;
        }

        const property = value.property.?;
        const name = if (value.computed) property.stringValue() orelse "request" else property.name;
        compiler.template.reads_data = true;
        compiler.template.javascript_reads = true;

        if (std.mem.eql(u8, name, "build")) {
            compiler.template.uses_build = true;
        } else {
            compiler.template.reads_request = true;
        }
    }

    fn children(emitter: *Emitter, items: []*Node) anyerror!void {
        std.debug.assert(emitter.compiler.template.compiling);
        try emitter.out.writeAll("[");

        for (items) |item| {
            try emitter.node(item);
            try emitter.out.writeAll(",");
        }

        try emitter.out.writeAll("]");
    }

    fn element(emitter: *Emitter, value: *Node) anyerror!void {
        std.debug.assert(emitter.compiler.template.compiling);

        if (emitter.compiler.template.kind == .module) {
            return emitter.compiler.fail("JSX belongs in .publr components", .{});
        }

        const opening = value.opening_element.?;
        const name_node = opening.name_node.?;
        const name = emitter.source[name_node.start..name_node.end];

        if (std.ascii.isUpper(name[0])) {
            const index = try emitter.component(name);
            try emitter.out.print("$publr.component({d},", .{index});
        } else {
            if (std.mem.eql(u8, name, "head")) {
                emitter.compiler.template.has_head = true;
            }

            try emitter.out.writeAll("$publr.element(");
            try emitter.quoted(name);
            try emitter.out.writeAll(",");
        }

        try emitter.out.writeAll("{");

        for (opening.attributes) |attr| {
            try emitter.attribute(attr);
        }

        try emitter.out.writeAll("},");
        try emitter.children(value.children);
        try emitter.out.writeAll(")");
    }

    fn attribute(emitter: *Emitter, attr: *Node) anyerror!void {
        std.debug.assert(emitter.compiler.template.compiling);

        if (attr.type == .JSXSpreadAttribute) {
            try emitter.out.writeAll("...");
            try emitter.node(attr.argument.?);
            return emitter.out.writeAll(",");
        }

        const name_node = attr.name_node.?;
        const name = emitter.source[name_node.start..name_node.end];
        const directives = [_][]const u8{
            "island", "dynamic", "dynamic-if", "prerender", "eager", "client:load", "client:idle",
        };

        for (directives) |directive| {
            if (std.mem.eql(u8, name, directive)) {
                return emitter.compiler.fail("place island directives outside computed JSX", .{});
            }
        }

        try emitter.quoted(name);
        try emitter.out.writeAll(":");

        if (attr.value_node) |value| {
            if (std.mem.eql(u8, name, "class") and value.type == .Literal and
                value.value == .string)
            {
                try markup.collect_classes(emitter.compiler, value.value.string);
            }

            try emitter.node(value);
        } else {
            try emitter.out.writeAll("true");
        }

        try emitter.out.writeAll(",");
    }

    fn component(emitter: *Emitter, name: []const u8) anyerror!u32 {
        std.debug.assert(emitter.compiler.template.compiling);
        const compiler = emitter.compiler;

        for (compiler.imports.items) |import| {
            if (!std.mem.eql(u8, import.local, name)) {
                continue;
            }

            if (import.pjsx != null) {
                return compiler.fail("wrap interactive components outside computed JSX", .{});
            }

            try compiler.context.compile(import.index);
            const callee = compiler.context.templates[import.index];

            if (callee.kind != .layout or callee.dynamic) {
                return compiler.fail("computed JSX embeds static components", .{});
            }

            try compiler.js_embeds.append(compiler.arena, import.index);
            compiler.template.reads_data = compiler.template.reads_data or callee.reads_data;
            compiler.template.has_head = compiler.template.has_head or callee.has_head;
            compiler.template.has_static_islands =
                compiler.template.has_static_islands or callee.has_static_islands;
            compiler.template.has_dynamic_islands =
                compiler.template.has_dynamic_islands or callee.has_dynamic_islands;
            compiler.template.has_interactive =
                compiler.template.has_interactive or callee.has_interactive;
            try @import("../components.zig").note_nested(
                compiler,
                &callee,
                !compiler.template.dynamic,
            );
            return import.index;
        }

        return compiler.fail("<{s}> is not imported", .{name});
    }
};
