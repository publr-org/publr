//! The renderer: walks a compiled template against a context and writes the page. `Ctx`
//! is what the frontmatter reads (the store, the request, the clock, the page's head);
//! it is a parameter so the engine can be tested against a stand-in.

const std = @import("std");
const ast = @import("ast.zig");
const compile = @import("compile.zig");
const time = @import("../lib/time.zig");

const Expr = ast.Expr;
const Node = ast.Node;
const Template = ast.Template;

pub const Error = error{NestingTooDeep};

/// Escapes the five HTML-special characters.
pub fn escape(writer: *std.Io.Writer, text: []const u8) !void {
    std.debug.assert(text.len < 1 << 30);

    for (text) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(byte),
        }
    }
}

/// A prop as a call site supplies it: by name, a string or null.
pub const Prop = struct { name: []const u8, value: ?[]const u8 };

/// A PJSX component the renderer can call: the lowered module's `render`, wrapped to
/// take props by name.
pub const PjsxRender = *const fn (
    writer: *std.Io.Writer,
    arena: std.mem.Allocator,
    props: []const Prop,
    children: ?[]const u8,
) anyerror!void;

pub fn Renderer(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        pub const Value = union(enum) {
            string: []const u8,
            opt_string: ?[]const u8,
            int: i64,
            boolean: bool,
            entry: Ctx.Entry,
            collection: []const Ctx.Entry,
            data: Ctx.Data,
            props,
            session: Ctx.Session,
            null,
        };

        const Binding = struct { name: []const u8, value: Value };

        /// An entry a call site passes, for a prop the component declares as one.
        pub const EntryProp = struct { name: []const u8, value: Ctx.Entry };

        /// The props of one template render: the call site's values and the children
        /// it rendered.
        pub const Props = struct {
            values: []const Prop = &.{},
            entries: []const EntryProp = &.{},
            children: []const u8 = "",

            fn get(props: Props, name: []const u8) ?[]const u8 {
                std.debug.assert(name.len > 0);

                for (props.values) |prop| {
                    if (std.mem.eql(u8, prop.name, name)) {
                        return prop.value;
                    }
                }

                return null;
            }

            fn get_entry(props: Props, name: []const u8) ?Ctx.Entry {
                std.debug.assert(name.len > 0);

                for (props.entries) |prop| {
                    if (std.mem.eql(u8, prop.name, name)) {
                        return prop.value;
                    }
                }

                return null;
            }
        };

        /// A call site's props, split by what they carry.
        const Split = struct { values: []const Prop, entries: []const EntryProp };

        templates: []const Template,
        pjsx: []const PjsxRender,
        arena: std.mem.Allocator,
        /// What the app's own URLs start with, `/newsletter` under that path: the islands'
        /// fragments are fetched below it.
        base: []const u8 = "",

        /// One template's evaluation: its locals and props.
        const Frame = struct {
            template: *const Template,
            ctx: *const Ctx,
            props: Props,
            /// How deep this render nests, against `compile.nesting_max`.
            depth: u32,
            expression_depth: u32 = 0,
            locals: std.ArrayList(Binding) = .empty,

            fn lookup(frame: *const Frame, name: []const u8) Value {
                std.debug.assert(name.len > 0);

                var index = frame.locals.items.len;

                while (index > 0) {
                    index -= 1;

                    if (std.mem.eql(u8, frame.locals.items[index].name, name)) {
                        return frame.locals.items[index].value;
                    }
                }

                // The compiler checked every name.
                unreachable;
            }
        };

        /// Renders template `index` with `ctx` and `props` into `writer`.
        pub fn render(
            renderer: *const Self,
            writer: *std.Io.Writer,
            index: u32,
            ctx: *const Ctx,
            props: Props,
        ) anyerror!void {
            if (index >= renderer.templates.len) {
                return error.InvalidTemplate;
            }

            return renderer.render_at(writer, index, ctx, props, 0);
        }

        fn render_at(
            renderer: *const Self,
            writer: *std.Io.Writer,
            index: u32,
            ctx: *const Ctx,
            props: Props,
            depth: u32,
        ) anyerror!void {
            const page = &renderer.templates[index];

            std.debug.assert(page.compiled);

            if (depth >= compile.nesting_max) {
                return error.NestingTooDeep;
            }

            if (@hasDecl(Ctx, "record_template")) {
                ctx.record_template(page.rel);
            }

            var frame: Frame = .{ .template = page, .ctx = ctx, .props = props, .depth = depth };

            for (page.decls) |decl| {
                if (decl.when) |when| {
                    const holds = truthy(try renderer.eval(&frame, when.condition));

                    if (holds == when.otherwise) {
                        continue;
                    }
                }

                const value = renderer.declare(&frame, decl) catch |err| {
                    if (err != error.Redirect and @hasDecl(Ctx, "report_declaration_error")) {
                        ctx.report_declaration_error(page.rel, decl, err);
                    }
                    return err;
                };

                try frame.locals.append(renderer.arena, .{ .name = decl.name, .value = value });
            }

            try renderer.nodes(writer, &frame, page.body);
        }

        fn declare(renderer: *const Self, frame: *Frame, decl: ast.Decl) anyerror!Value {
            const ctx = frame.ctx;

            std.debug.assert(renderer.templates.len > 0);

            std.debug.assert(decl.name.len > 0);
            std.debug.assert(frame.depth < compile.nesting_max);

            return switch (decl.value) {
                .build_now => .{
                    .string = try time.datetime_text(renderer.arena, ctx.build_time()),
                },
                .request_now => .{ .string = try time.datetime_text(renderer.arena, ctx.now()) },
                .session => .{ .session = try ctx.session() },
                .header => |name| .{ .opt_string = ctx.header(name) },
                .cookie => |name| .{ .opt_string = ctx.cookie(name) },
                .random => |bound| .{ .int = ctx.random(bound) },
                .user_field => |path| .{ .opt_string = try ctx.user_field(path) },
                .call => |operation| .{ .entry = try ctx.call(operation) },
                .redirect => |target| try renderer.redirect(frame, target),
                .entry => |query| .{
                    .entry = if (query.first) try ctx.first(query.type_id) else try ctx.entry(
                        query.type_id,
                        query.slug orelse ctx.param("slug") orelse "unknown",
                    ),
                },
                .query => |query| .{ .collection = try ctx.query(type_id_of(query), .{
                    .limit = query.limit,
                    .offset = query.offset,
                }) },
                .data_text => |access| blk: {
                    const owner = frame.lookup(access.object);
                    const text = owner.entry.data.getText(access.key) orelse access.fallback;

                    break :blk .{ .string = text };
                },
                .data_items => |access| blk: {
                    const owner = frame.lookup(access.object);
                    const items = try owner.entry.data.getItems(renderer.arena, access.key);

                    break :blk .{ .collection = items };
                },
                .references => |access| blk: {
                    const owner = frame.lookup(access.object);
                    const ids = try owner.entry.data.getIds(renderer.arena, access.key);

                    break :blk .{ .collection = try ctx.references(ids) };
                },
                .reference => |access| blk: {
                    const owner = frame.lookup(access.object);
                    const ids = try owner.entry.data.getIds(renderer.arena, access.key);

                    break :blk .{ .entry = try ctx.reference(ids) };
                },
                .prop_text => |access| .{
                    .string = frame.props.get(access.key) orelse access.fallback,
                },
                // The compiler refuses a call site that leaves an entry prop out.
                .entry_prop => |name| .{
                    .entry = frame.props.get_entry(name) orelse return error.MissingProp,
                },
            };
        }

        /// A redirect the page asks for ends its render: the context keeps the path, the
        /// server answers with it. An empty path is no redirect, and the page renders.
        fn redirect(renderer: *const Self, frame: *Frame, target: Expr) anyerror!Value {
            std.debug.assert(frame.template.kind == .page);
            std.debug.assert(target.type == .string or target.type == .opt_string);

            const path = switch (try renderer.eval(frame, target)) {
                .string => |text| text,
                .opt_string => |text| text orelse "",
                else => unreachable,
            };

            if (path.len > 0) {
                try frame.ctx.redirect(path);

                return error.Redirect;
            }

            return .{ .string = "" };
        }

        fn type_id_of(query: ast.Decl.Query) []const u8 {
            std.debug.assert(query.type_id.len > 0);

            return query.type_id;
        }

        fn nodes(
            renderer: *const Self,
            writer: *std.Io.Writer,
            frame: *Frame,
            list: []const Node,
        ) anyerror!void {
            std.debug.assert(frame.depth < compile.nesting_max);

            for (list) |item| {
                try renderer.node(writer, frame, item);
            }
        }

        fn nested(
            renderer: *const Self,
            writer: *std.Io.Writer,
            frame: *Frame,
            list: []const Node,
        ) anyerror!void {
            std.debug.assert(frame.depth < compile.nesting_max);

            if (frame.depth + 1 >= compile.nesting_max) {
                return error.NestingTooDeep;
            }

            frame.depth += 1;
            defer frame.depth -= 1;

            try renderer.nodes(writer, frame, list);
        }

        fn node(
            renderer: *const Self,
            writer: *std.Io.Writer,
            frame: *Frame,
            item: Node,
        ) anyerror!void {
            std.debug.assert(frame.depth < compile.nesting_max);

            switch (item) {
                .text => |text| try writer.writeAll(text),
                .value => |expr| try renderer.write_value(writer, frame, expr),
                .raw => |expr| try renderer.write_raw(writer, frame, expr),
                .attr => |attr| try renderer.write_attr(writer, frame, attr),
                .asset => |path| try frame.ctx.asset_url(writer, path),
                .head_assets => try frame.ctx.head_assets(writer),
                .loop => |loop| try renderer.write_loop(writer, frame, loop),
                .cond => |cond| {
                    const chosen = if (truthy(try renderer.eval(frame, cond.condition)))
                        cond.consequent
                    else
                        cond.alternate;

                    try renderer.nested(writer, frame, chosen);
                },
                .slot => try writer.writeAll(frame.props.children),
                .embed => |embed| try renderer.write_embed(writer, frame, embed),
                .island => |use| try renderer.island(writer, frame, use),
                .pjsx => |call| try renderer.write_pjsx(writer, frame, call),
            }
        }

        fn write_raw(
            renderer: *const Self,
            writer: *std.Io.Writer,
            frame: *Frame,
            expr: Expr,
        ) anyerror!void {
            std.debug.assert(expr.type == .string or expr.type == .opt_string);

            switch (try renderer.eval(frame, expr)) {
                .string => |text| try writer.writeAll(text),
                .opt_string => |text| if (text) |present| {
                    try writer.writeAll(present);
                },
                else => unreachable,
            }
        }

        fn write_attr(
            renderer: *const Self,
            writer: *std.Io.Writer,
            frame: *Frame,
            attr: Node.Attr,
        ) anyerror!void {
            std.debug.assert(attr.name.len > 0);

            switch (try renderer.eval(frame, attr.expr)) {
                .boolean => |flag| if (flag) {
                    try writer.writeAll(" ");
                    try writer.writeAll(attr.name);
                },
                .opt_string => |text| if (text) |present| {
                    try write_quoted(writer, attr.name, present);
                },
                .string => |text| try write_quoted(writer, attr.name, text),
                .int => |number| try writer.print(" {s}=\"{d}\"", .{ attr.name, number }),
                else => unreachable,
            }
        }

        fn write_quoted(writer: *std.Io.Writer, name: []const u8, text: []const u8) anyerror!void {
            std.debug.assert(name.len > 0);

            try writer.print(" {s}=\"", .{name});
            try escape(writer, text);
            try writer.writeAll("\"");
        }

        fn write_loop(
            renderer: *const Self,
            writer: *std.Io.Writer,
            frame: *Frame,
            loop: Node.Loop,
        ) anyerror!void {
            const collection = frame.lookup(loop.collection).collection;
            const locals_before = frame.locals.items.len;

            for (collection) |entry| {
                const binding: Binding = .{ .name = loop.param, .value = .{ .entry = entry } };

                try frame.locals.append(renderer.arena, binding);
                try renderer.nested(writer, frame, loop.body);
                _ = frame.locals.pop();
            }

            std.debug.assert(frame.locals.items.len == locals_before);
        }

        fn write_embed(
            renderer: *const Self,
            writer: *std.Io.Writer,
            frame: *Frame,
            embed: Node.Embed,
        ) anyerror!void {
            std.debug.assert(embed.callee < renderer.templates.len);

            const props = try renderer.props_of(frame, embed.props);
            const inner = frame.depth + 1;
            const children = embed.children orelse {
                const only: Props = .{ .values = props.values, .entries = props.entries };

                return renderer.render_at(writer, embed.callee, frame.ctx, only, inner);
            };
            var buffer: std.Io.Writer.Allocating = .init(renderer.arena);

            try renderer.nested(&buffer.writer, frame, children);
            try renderer.render_at(writer, embed.callee, frame.ctx, .{
                .values = props.values,
                .entries = props.entries,
                .children = buffer.written(),
            }, inner);
        }

        fn write_pjsx(
            renderer: *const Self,
            writer: *std.Io.Writer,
            frame: *Frame,
            call: Node.Pjsx,
        ) anyerror!void {
            std.debug.assert(call.component < renderer.pjsx.len);

            const props = try renderer.props_of(frame, call.props);
            const children = call.children orelse {
                return renderer.pjsx[call.component](writer, renderer.arena, props.values, null);
            };
            var buffer: std.Io.Writer.Allocating = .init(renderer.arena);

            std.debug.assert(props.entries.len == 0);

            try renderer.nested(&buffer.writer, frame, children);
            const rendered = buffer.written();

            try renderer.pjsx[call.component](writer, renderer.arena, props.values, rendered);
        }

        /// The placeholder for a fragment: a static island is always one, its fallback
        /// (or the build's own render, with `prerender`) inside; a dynamic island is
        /// flattened into a live render and a placeholder otherwise.
        fn island(
            renderer: *const Self,
            writer: *std.Io.Writer,
            frame: *Frame,
            use: Node.Island,
        ) anyerror!void {
            std.debug.assert(use.key.len > 0);
            std.debug.assert(use.callee < renderer.templates.len);

            const props = (try renderer.props_of(frame, use.props)).values;

            if (use.dynamic and frame.ctx.live) {
                const inner = frame.depth + 1;

                const only: Props = .{ .values = props };

                return renderer.render_at(writer, use.callee, frame.ctx, only, inner);
            }

            try writer.print("<publr-island src=\"{s}/_islands/{s}\"", .{
                renderer.base,
                use.key,
            });

            if (use.dynamic) {
                try writer.writeAll(" credentials");
            }

            // A letter, then letters, digits or _: checked when the app compiled.
            if (use.condition.len > 0) {
                try writer.print(" if=\"{s}\"", .{use.condition});
            }

            if (use.deferred) {
                try writer.writeAll(" defer");
            }

            if (use.prerender) {
                try writer.writeAll(" prerendered>");
                try renderer.prerender(writer, frame, use, props);
            } else {
                try writer.writeAll(">");
                try renderer.nested(writer, frame, use.fallback);
            }

            try writer.writeAll("</publr-island>");
        }

        /// The build's own copy of the fragment: a dynamic island as a visitor nobody
        /// knows; a static island through a context that keeps no `deps`, so the page
        /// does not subscribe to what the island reads.
        fn prerender(
            renderer: *const Self,
            writer: *std.Io.Writer,
            frame: *Frame,
            use: Node.Island,
            props: []const Prop,
        ) anyerror!void {
            std.debug.assert(use.prerender);
            std.debug.assert(use.fallback.len == 0);

            const ctx = if (use.dynamic) frame.ctx.prerender() else frame.ctx.stale();

            try renderer.render_at(writer, use.callee, &ctx, .{ .values = props }, frame.depth + 1);
        }

        fn props_of(
            renderer: *const Self,
            frame: *Frame,
            args: []const ast.PropArg,
        ) anyerror!Split {
            std.debug.assert(args.len <= compile.props_max);

            var values: std.ArrayList(Prop) = .empty;
            var entries: std.ArrayList(EntryProp) = .empty;

            for (args) |arg| {
                switch (arg.value) {
                    .literal => |text| try values.append(renderer.arena, .{
                        .name = arg.name,
                        .value = text,
                    }),
                    .expr => |expr| switch (try renderer.eval(frame, expr)) {
                        .string => |text| try values.append(renderer.arena, .{
                            .name = arg.name,
                            .value = text,
                        }),
                        .opt_string => |text| try values.append(renderer.arena, .{
                            .name = arg.name,
                            .value = text,
                        }),
                        .entry => |entry| try entries.append(renderer.arena, .{
                            .name = arg.name,
                            .value = entry,
                        }),
                        else => unreachable,
                    },
                }
            }

            std.debug.assert(values.items.len + entries.items.len == args.len);

            return .{ .values = values.items, .entries = entries.items };
        }

        fn write_value(
            renderer: *const Self,
            writer: *std.Io.Writer,
            frame: *Frame,
            expr: Expr,
        ) anyerror!void {
            std.debug.assert(expr.type != .entry);

            switch (try renderer.eval(frame, expr)) {
                .string => |text| try escape(writer, text),
                .opt_string => |text| if (text) |present| {
                    try escape(writer, present);
                },
                .int => |number| try writer.print("{d}", .{number}),
                .boolean => |flag| try writer.writeAll(if (flag) "true" else "false"),
                .null => {},
                else => unreachable,
            }
        }

        /// JavaScript truthiness.
        fn truthy(value: Value) bool {
            return switch (value) {
                .boolean => |flag| flag,
                .opt_string => |text| text != null,
                .int => |number| number != 0,
                .string => |text| text.len != 0,
                .collection => |list| list.len != 0,
                .session => |session| session.email != null,
                .null => false,
                else => unreachable,
            };
        }

        fn eval(renderer: *const Self, frame: *Frame, expr: Expr) anyerror!Value {
            if (frame.expression_depth == compile.nesting_max) {
                return error.NestingTooDeep;
            }

            frame.expression_depth += 1;
            defer frame.expression_depth -= 1;
            std.debug.assert(frame.depth < compile.nesting_max);

            return switch (expr.node) {
                .string => |text| .{ .string = text },
                .int => |number| .{ .int = number },
                .boolean => |flag| .{ .boolean = flag },
                .null => .null,
                .local => |name| frame.lookup(name),
                .props => .props,
                .member => |access| renderer.member_value(frame, access),
                .nullish => |binary| renderer.nullish_value(frame, binary),
                .ternary => |choice| renderer.ternary(frame, expr.type, choice),
                .equality => |compare| renderer.equality(frame, compare),
                .relational => |compare| renderer.relational(frame, compare),
                .not => |operand| .{ .boolean = !truthy(try renderer.eval(frame, operand.*)) },
                .logical => |both| renderer.logical(frame, both),
                .template => |parts| renderer.template_string(frame, parts),
            };
        }

        fn logical(renderer: *const Self, frame: *Frame, both: Expr.Logical) anyerror!Value {
            std.debug.assert(both.left.type != .entry);
            std.debug.assert(both.right.type != .entry);

            const left = truthy(try renderer.eval(frame, both.left.*));
            const settled = if (both.operator == .@"and") !left else left;

            if (settled) {
                return .{ .boolean = left };
            }

            return .{ .boolean = truthy(try renderer.eval(frame, both.right.*)) };
        }

        fn nullish_value(renderer: *const Self, frame: *Frame, binary: Expr.Binary) anyerror!Value {
            std.debug.assert(binary.left.type == .opt_string);

            const left = (try renderer.eval(frame, binary.left.*)).opt_string;
            const present = left orelse return renderer.eval(frame, binary.right.*);

            // The chain's type is the right side's: a string ends it, an optional keeps
            // it optional.
            if (binary.right.type == .string) {
                return .{ .string = present };
            }

            return .{ .opt_string = present };
        }

        fn ternary(
            renderer: *const Self,
            frame: *Frame,
            kind: ast.Type,
            choice: Expr.Ternary,
        ) anyerror!Value {
            const chosen = if (truthy(try renderer.eval(frame, choice.condition.*)))
                choice.consequent
            else
                choice.alternate;
            const value = try renderer.eval(frame, chosen.*);

            std.debug.assert(kind != .entry);

            // A branch mixing null with a string is an optional string.
            if (kind != .opt_string) {
                return value;
            }

            return switch (value) {
                .string => |text| .{ .opt_string = text },
                .null => .{ .opt_string = null },
                else => value,
            };
        }

        fn equality(renderer: *const Self, frame: *Frame, compare: Expr.Equality) anyerror!Value {
            const left = try renderer.eval(frame, compare.left.*);

            std.debug.assert(compare.mode != .null_check or compare.right.type == .null);

            const equal = switch (compare.mode) {
                .null_check => left.opt_string == null,
                .strings => std.mem.eql(
                    u8,
                    left.string,
                    (try renderer.eval(frame, compare.right.*)).string,
                ),
                .ints => left.int == (try renderer.eval(frame, compare.right.*)).int,
                .booleans => left.boolean == (try renderer.eval(frame, compare.right.*)).boolean,
            };

            return .{ .boolean = equal != compare.negated };
        }

        fn relational(
            renderer: *const Self,
            frame: *Frame,
            compare: Expr.Relational,
        ) anyerror!Value {
            std.debug.assert(compare.left.type == .int);
            std.debug.assert(compare.right.type == .int);

            const left = (try renderer.eval(frame, compare.left.*)).int;
            const right = (try renderer.eval(frame, compare.right.*)).int;

            return .{ .boolean = switch (compare.operator) {
                .lt => left < right,
                .le => left <= right,
                .gt => left > right,
                .ge => left >= right,
            } };
        }

        fn template_string(
            renderer: *const Self,
            frame: *Frame,
            parts: []const Expr.TemplatePart,
        ) anyerror!Value {
            std.debug.assert(frame.depth < compile.nesting_max);

            var out: std.Io.Writer.Allocating = .init(renderer.arena);

            for (parts) |part| {
                switch (part) {
                    .text => |text| try out.writer.writeAll(text),
                    .hole => |hole| switch (try renderer.eval(frame, hole.*)) {
                        .string => |text| try out.writer.writeAll(text),
                        .int => |number| try out.writer.print("{d}", .{number}),
                        else => unreachable,
                    },
                }
            }

            return .{ .string = out.written() };
        }

        fn member_value(renderer: *const Self, frame: *Frame, access: Expr.Member) anyerror!Value {
            const object = try renderer.eval(frame, access.object.*);

            std.debug.assert(frame.depth < compile.nesting_max);

            return switch (access.kind) {
                .entry_title => .{ .string = object.entry.title },
                .entry_created_at => .{ .string = object.entry.created_at },
                .entry_updated_at => .{ .string = object.entry.updated_at },
                .entry_slug => .{ .opt_string = object.entry.slug },
                .entry_id => .{ .string = object.entry.id },
                .entry_type => .{ .string = object.entry.type },
                .entry_data => .{ .data = object.entry.data },
                .data_text => |key| .{ .opt_string = object.data.getText(key) },
                .session_email => .{ .opt_string = object.session.email },
                .length => switch (object) {
                    .collection => |list| .{ .int = @intCast(list.len) },
                    .string => |text| .{ .int = @intCast(text.len) },
                    else => unreachable,
                },
                .prop => |name| .{ .opt_string = frame.props.get(name) },
            };
        }
    };
}

test "escape covers the five special characters and nothing else" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try escape(&writer, "<a href=\"x\">&'</a>");
    const expected = "&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;";
    try std.testing.expectEqualStrings(expected, writer.buffered());
}
