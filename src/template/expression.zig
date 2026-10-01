//! Expressions inside `{...}`: a recursive-descent parser producing typed nodes, and
//! the text helpers the rest of the reader shares.

const std = @import("std");
const ast = @import("ast.zig");
const compile = @import("compile.zig");

const Compiler = compile.Compiler;
const Error = compile.Error;
const Type = ast.Type;
const Expr = ast.Expr;

pub fn expression(compiler: *Compiler, text: []const u8) Error!Expr {
    std.debug.assert(text.len < 1 << 20);

    if (compiler.javascript) {
        return @import("javascript/compile.zig").expression(compiler, text);
    }

    var parser: Parser = .{ .compiler = compiler, .text = std.mem.trim(u8, text, " \t\r\n") };
    const value = try parser.ternary();
    parser.skip_whitespace();

    if (parser.position != parser.text.len) {
        return compiler.script(
            "unsupported expression syntax at `{s}`",
            .{compiler.excerpt(parser.text[parser.position..])},
        );
    }

    std.debug.assert(parser.position == parser.text.len);

    return value;
}

/// Whether a value of this type has a truthiness (the renderer decides it; this only
/// refuses the types that have none).
pub fn check_truthy(compiler: *Compiler, value: Expr) Error!void {
    std.debug.assert(compiler.template.compiling);

    switch (value.type) {
        .javascript, .boolean, .opt_string, .int, .string, .collection, .session, .null => {},
        else => return compiler.fail("a {s} has no truthiness", .{@tagName(value.type)}),
    }
}

/// Writes a value by type: strings escaped, optionals when present, numbers printed,
/// booleans as words.
pub fn write_value(compiler: *Compiler, value: Expr) Error!void {
    std.debug.assert(compiler.template.compiling);

    switch (value.type) {
        .javascript, .string, .opt_string, .int, .boolean => try compiler.push(.{ .value = value }),
        .null => {},
        else => return compiler.fail(
            "a {s} cannot be written as text",
            .{@tagName(value.type)},
        ),
    }
}

/// The characters of a string literal, quotes stripped.
pub fn js_string(compiler: *Compiler, text: []const u8) Error![]const u8 {
    std.debug.assert(compiler.template.compiling);

    const quoted = text.len >= 2 and (text[0] == '\'' or text[0] == '"') and
        text[text.len - 1] == text[0];

    if (!quoted) {
        return compiler.fail("expected a string literal: {s}", .{text});
    }

    return text[1 .. text.len - 1];
}

/// The `}` closing the `{` at `start`, respecting nesting, strings, templates.
pub fn expression_end(compiler: *Compiler, text: []const u8, start: u32) Error!u32 {
    std.debug.assert(start < text.len);
    std.debug.assert(text[start] == '{');

    if (compiler.javascript) {
        const syntax = @import("pjsx_syntax").template_syntax;
        return start + (syntax.syntax.expressionEnd(
            compiler.arena,
            text[start..],
            compiler.template.rel,
        ) catch |err| {
            if (err == error.OutOfMemory) {
                return error.OutOfMemory;
            }

            return compiler.fail("JavaScript syntax: {s}", .{syntax.lastError()});
        });
    }

    var depth: u32 = 0;
    var quote: u8 = 0;
    var index = start;

    while (index < text.len) : (index += 1) {
        const byte = text[index];

        if (quote != 0) {
            if (byte == '\\') {
                index += 1;
            } else if (byte == quote) {
                quote = 0;
            }

            continue;
        }

        switch (byte) {
            '\'', '"', '`' => quote = byte,
            '{' => depth += 1,
            '}' => {
                depth -= 1;

                if (depth == 0) {
                    return index;
                }
            },
            else => {},
        }
    }

    return compiler.fail("unterminated expression: {s}", .{compiler.excerpt(text[start..])});
}

const globals = [_][]const u8{
    "Math",
    "Number",
    "String",
    "Array",
    "Object",
    "JSON",
    "Set",
    "Map",
    "Date",
    "RegExp",
    "BigInt",
    "Infinity",
    "NaN",
    "undefined",
    "globalThis",
    "new",
    "typeof",
    "void",
    "parseInt",
    "parseFloat",
    "isNaN",
    "isFinite",
    "encodeURIComponent",
    "decodeURIComponent",
};

const Parser = struct {
    compiler: *Compiler,
    text: []const u8,
    position: u32 = 0,

    fn skip_whitespace(parser: *Parser) void {
        std.debug.assert(parser.position <= parser.text.len);

        while (parser.at(std.ascii.isWhitespace)) {
            parser.position += 1;
        }
    }

    /// Whether the byte at the position satisfies `predicate`; false at the end.
    fn at(parser: *const Parser, predicate: *const fn (byte: u8) bool) bool {
        std.debug.assert(parser.position <= parser.text.len);

        if (parser.position == parser.text.len) {
            return false;
        }

        return predicate(parser.text[parser.position]);
    }

    fn peek(parser: *Parser, token: []const u8) bool {
        std.debug.assert(token.len > 0);

        parser.skip_whitespace();

        return std.mem.startsWith(u8, parser.text[parser.position..], token);
    }

    fn take(parser: *Parser, token: []const u8) bool {
        std.debug.assert(token.len > 0);

        if (parser.peek(token)) {
            parser.position += @intCast(token.len);

            return true;
        }

        return false;
    }

    fn ternary(parser: *Parser) Error!Expr {
        try parser.compiler.descend();
        defer parser.compiler.ascend();
        const condition = try parser.logical_or();

        std.debug.assert(parser.position <= parser.text.len);

        if (parser.peek("?") and !parser.peek("??")) {
            parser.position += 1;
            const consequent = try parser.ternary();

            if (!parser.take(":")) {
                return parser.compiler.fail("conditional without `:`", .{});
            }

            const alternate = try parser.ternary();

            return parser.select(condition, consequent, alternate);
        }

        return condition;
    }

    fn select(parser: *Parser, condition: Expr, consequent: Expr, alternate: Expr) Error!Expr {
        const compiler = parser.compiler;

        std.debug.assert(parser.position <= parser.text.len);

        try check_truthy(compiler, condition);

        const node: Expr.Form = .{ .ternary = .{
            .condition = try compiler.box(condition),
            .consequent = try compiler.box(consequent),
            .alternate = try compiler.box(alternate),
        } };

        if (consequent.type == alternate.type) {
            return .{ .type = consequent.type, .node = node };
        }

        if (consequent.type == .null or alternate.type == .null) {
            const present = if (consequent.type == .null) alternate else consequent;

            if (present.type != .string) {
                return compiler.fail(
                    "a conditional mixes null with a {s}",
                    .{@tagName(present.type)},
                );
            }

            return .{ .type = .opt_string, .node = node };
        }

        return compiler.fail(
            "a conditional mixes a {s} with a {s}",
            .{ @tagName(consequent.type), @tagName(alternate.type) },
        );
    }

    /// `a || b`: true when either is truthy, the right one read only when needed.
    fn logical_or(parser: *Parser) Error!Expr {
        return parser.logical(.@"or");
    }

    /// `a && b`: true when both are truthy, the right one read only when needed.
    fn logical_and(parser: *Parser) Error!Expr {
        return parser.logical(.@"and");
    }

    /// `&&` binds tighter than `||`, and `??` tighter than both.
    fn logical_operand(parser: *Parser, operator: Expr.Logical.Operator) Error!Expr {
        return if (operator == .@"or") parser.logical_and() else parser.nullish();
    }

    fn logical(parser: *Parser, operator: Expr.Logical.Operator) Error!Expr {
        const compiler = parser.compiler;
        const token = if (operator == .@"or") "||" else "&&";
        var left = try parser.logical_operand(operator);

        std.debug.assert(token.len == 2);

        while (parser.take(token)) {
            const right = try parser.logical_operand(operator);

            if (left.type != .boolean or right.type != .boolean) {
                return compiler.script("logical operators return JavaScript operands", .{});
            }

            try check_truthy(compiler, left);
            try check_truthy(compiler, right);

            // Boxed before the assignment, as for `??`.
            const boxed_left = try compiler.box(left);
            const boxed_right = try compiler.box(right);
            left = .{ .type = .boolean, .node = .{ .logical = .{
                .left = boxed_left,
                .right = boxed_right,
                .operator = operator,
            } } };
        }

        return left;
    }

    fn nullish(parser: *Parser) Error!Expr {
        const compiler = parser.compiler;
        var left = try parser.equality();

        while (parser.take("??")) {
            const right = try parser.equality();

            if (!left.type.is_optional()) {
                return compiler.fail("`??` on a {s}, which is never null", .{@tagName(left.type)});
            }

            // `a ?? b ?? c`: an optional fallback keeps the chain optional until a string
            // ends it.

            if (right.type != .string and right.type != .opt_string) {
                return compiler.fail(
                    "`??` needs a string fallback; got a {s}",
                    .{@tagName(right.type)},
                );
            }

            // Boxed before the assignment: `left` is the result location of the
            // initializer, so reading it inside one would read the half already
            // overwritten.
            const boxed_left = try compiler.box(left);
            const boxed_right = try compiler.box(right);
            left = .{
                .type = right.type,
                .node = .{ .nullish = .{ .left = boxed_left, .right = boxed_right } },
            };
        }

        std.debug.assert(parser.position <= parser.text.len);

        return left;
    }

    fn equality(parser: *Parser) Error!Expr {
        const left = try parser.relational();
        const negated = parser.peek("!==") or parser.peek("!=");
        const found = parser.take("===") or parser.take("!==") or parser.take("==") or
            parser.take("!=");

        std.debug.assert(parser.position <= parser.text.len);

        if (found) {
            const right = try parser.relational();

            return parser.equals(left, right, negated);
        }

        return left;
    }

    fn equals(parser: *Parser, left: Expr, right: Expr, negated: bool) Error!Expr {
        const compiler = parser.compiler;

        std.debug.assert(compiler.template.compiling);

        if (left.type == .null or right.type == .null) {
            const subject = if (right.type == .null) left else right;

            if (!subject.type.is_optional()) {
                return compiler.fail("comparing a {s} with null", .{@tagName(subject.type)});
            }

            const null_expr: Expr = .{ .type = .null, .node = .null };

            return parser.comparison(subject, null_expr, negated, .null_check);
        }

        if (left.type != right.type) {
            return compiler.fail(
                "equality between a {s} and a {s}",
                .{ @tagName(left.type), @tagName(right.type) },
            );
        }

        const mode: Expr.Equality.Mode = switch (left.type) {
            .string => .strings,
            .int => .ints,
            .boolean => .booleans,
            else => return compiler.fail(
                "equality between a {s} and a {s}",
                .{ @tagName(left.type), @tagName(right.type) },
            ),
        };

        return parser.comparison(left, right, negated, mode);
    }

    fn comparison(
        parser: *Parser,
        left: Expr,
        right: Expr,
        negated: bool,
        mode: Expr.Equality.Mode,
    ) Error!Expr {
        const compiler = parser.compiler;

        std.debug.assert(mode != .null_check or right.type == .null);

        return .{ .type = .boolean, .node = .{ .equality = .{
            .left = try compiler.box(left),
            .right = try compiler.box(right),
            .negated = negated,
            .mode = mode,
        } } };
    }

    fn relational(parser: *Parser) Error!Expr {
        const compiler = parser.compiler;
        const left = try parser.unary();
        const operators = [_]struct { text: []const u8, operator: Expr.Relational.Operator }{
            .{ .text = "<=", .operator = .le },
            .{ .text = ">=", .operator = .ge },
            .{ .text = "<", .operator = .lt },
            .{ .text = ">", .operator = .gt },
        };

        std.debug.assert(operators.len == 4);

        for (operators) |candidate| {
            if (!parser.take(candidate.text)) {
                continue;
            }

            const right = try parser.unary();

            if (left.type != .int or right.type != .int) {
                return compiler.fail(
                    "`{s}` compares a {s} with a {s}",
                    .{ candidate.text, @tagName(left.type), @tagName(right.type) },
                );
            }

            return .{ .type = .boolean, .node = .{ .relational = .{
                .left = try compiler.box(left),
                .right = try compiler.box(right),
                .operator = candidate.operator,
            } } };
        }

        return left;
    }

    /// `!value`: the opposite of the value's truthiness, a boolean.
    fn unary(parser: *Parser) Error!Expr {
        std.debug.assert(parser.position <= parser.text.len);

        parser.skip_whitespace();

        if (!parser.peek("!") or parser.peek("!=")) {
            return parser.postfix();
        }

        parser.position += 1;

        const operand = try parser.unary();

        try check_truthy(parser.compiler, operand);

        return .{ .type = .boolean, .node = .{ .not = try parser.compiler.box(operand) } };
    }

    fn postfix(parser: *Parser) Error!Expr {
        var value = try parser.primary();

        while (parser.take(".")) {
            const member_name = try parser.identifier();
            value = try parser.member(value, member_name);
        }

        std.debug.assert(parser.position <= parser.text.len);

        return value;
    }

    fn member(parser: *Parser, object: Expr, field: []const u8) Error!Expr {
        const compiler = parser.compiler;
        const boxed = try compiler.box(object);

        std.debug.assert(field.len > 0);

        return switch (object.type) {
            .entry => entry_member(compiler, boxed, field),
            .data => .{
                .type = .opt_string,
                .node = .{ .member = .{ .object = boxed, .kind = .{ .data_text = field } } },
            },
            .session => session_member(compiler, boxed, field),
            .collection, .string => length_member(compiler, boxed, object.type, field),
            .props => parser.prop_member(boxed, field),
            else => compiler.fail("`.{s}` of a {s}", .{ field, @tagName(object.type) }),
        };
    }

    fn prop_member(parser: *Parser, boxed: *const Expr, field: []const u8) Error!Expr {
        const compiler = parser.compiler;

        std.debug.assert(boxed.type == .props);

        if (std.mem.eql(u8, field, "children")) {
            return compiler.fail("write children with <slot />, not {{props.children}}", .{});
        }

        var known = false;

        for (compiler.entry_props.items) |existing| {
            if (std.mem.eql(u8, existing, field)) {
                return compiler.fail(
                    "props.{s} is an entry: read it in the frontmatter, " ++
                        "const {s} = props.entry.{s};",
                    .{ field, field, field },
                );
            }
        }

        for (compiler.prop_names.items) |existing| {
            if (std.mem.eql(u8, existing, field)) {
                known = true;
            }
        }

        if (!known) {
            if (compiler.prop_names.items.len == compile.props_max) {
                return compiler.fail("a template reads more than {d} props", .{compile.props_max});
            }

            try compiler.prop_names.append(compiler.arena, field);
        }

        return .{
            .type = .opt_string,
            .node = .{ .member = .{ .object = boxed, .kind = .{ .prop = field } } },
        };
    }

    fn identifier(parser: *Parser) Error![]const u8 {
        parser.skip_whitespace();

        const start = parser.position;

        while (parser.at(is_identifier_char)) {
            parser.position += 1;
        }

        std.debug.assert(parser.position >= start);

        if (parser.position == start or std.ascii.isDigit(parser.text[start])) {
            return parser.compiler.script(
                "expected a name at `{s}`",
                .{parser.compiler.excerpt(parser.text[start..])},
            );
        }

        return parser.text[start..parser.position];
    }

    fn primary(parser: *Parser) Error!Expr {
        const compiler = parser.compiler;

        parser.skip_whitespace();

        if (parser.position >= parser.text.len) {
            return compiler.fail("expression ends early", .{});
        }

        const byte = parser.text[parser.position];

        std.debug.assert(!std.ascii.isWhitespace(byte));

        if (byte == '(') {
            parser.position += 1;
            const inner = try parser.ternary();

            if (!parser.take(")")) {
                return compiler.fail("missing `)`", .{});
            }

            return inner;
        }

        if (byte == '\'' or byte == '"') {
            return parser.string_literal(byte);
        }

        if (byte == '`') {
            return parser.template_literal();
        }

        if (std.ascii.isDigit(byte)) {
            return parser.number();
        }

        return parser.word_expression();
    }

    fn string_literal(parser: *Parser, quote: u8) Error!Expr {
        std.debug.assert(quote == '\'' or quote == '"');
        std.debug.assert(parser.text[parser.position] == quote);

        if (std.mem.indexOfScalar(u8, parser.text[parser.position..], '\\') != null) {
            return parser.compiler.script("escaped JavaScript string", .{});
        }

        const end = std.mem.indexOfScalarPos(u8, parser.text, parser.position + 1, quote) orelse {
            return parser.compiler.fail("unterminated string", .{});
        };
        const literal = parser.text[parser.position + 1 .. end];
        parser.position = @intCast(end + 1);

        return .{ .type = .string, .node = .{ .string = literal } };
    }

    fn number(parser: *Parser) Error!Expr {
        const start = parser.position;

        std.debug.assert(std.ascii.isDigit(parser.text[start]));

        while (parser.at(std.ascii.isDigit)) {
            parser.position += 1;
        }

        const digits = parser.text[start..parser.position];
        const value = std.fmt.parseInt(i64, digits, 10) catch {
            return parser.compiler.script("JavaScript number: {s}", .{digits});
        };

        if (value > 9007199254740991) {
            return parser.compiler.script("JavaScript number rounding", .{});
        }

        std.debug.assert(digits.len > 0);

        return .{ .type = .int, .node = .{ .int = value } };
    }

    fn word_expression(parser: *Parser) Error!Expr {
        const compiler = parser.compiler;
        const word = try parser.identifier();

        std.debug.assert(word.len > 0);

        if (std.mem.eql(u8, word, "null")) {
            return .{ .type = .null, .node = .null };
        }

        if (std.mem.eql(u8, word, "true")) {
            return .{ .type = .boolean, .node = .{ .boolean = true } };
        }

        if (std.mem.eql(u8, word, "false")) {
            return .{ .type = .boolean, .node = .{ .boolean = false } };
        }

        if (std.mem.eql(u8, word, "props")) {
            if (compiler.template.kind != .layout) {
                return compiler.fail("`props` belong to layouts; pages read `ctx`", .{});
            }

            return .{ .type = .props, .node = .props };
        }

        if (std.mem.eql(u8, word, "Publr") or std.mem.eql(u8, word, "Astro")) {
            return compiler.fail("{s}.* calls are frontmatter-only", .{word});
        }

        const found = compiler.find_local(word) orelse {
            for (globals) |name| {
                if (std.mem.eql(u8, word, name)) {
                    return compiler.script("JavaScript global {s}", .{word});
                }
            }

            return compiler.fail("`{s}` is not declared", .{word});
        };

        return .{ .type = found.type, .node = .{ .local = word } };
    }

    /// A template string: literal runs and holes.
    fn template_literal(parser: *Parser) Error!Expr {
        const compiler = parser.compiler;
        var parts: std.ArrayList(Expr.TemplatePart) = .empty;
        var text: std.ArrayList(u8) = .empty;

        std.debug.assert(parser.text[parser.position] == '`');

        parser.position += 1;

        while (true) {
            if (parser.position >= parser.text.len) {
                return compiler.fail("unterminated template string", .{});
            }

            const byte = parser.text[parser.position];

            if (byte == '`') {
                parser.position += 1;
                break;
            }

            if (std.mem.startsWith(u8, parser.text[parser.position..], "${")) {
                try parser.template_hole(&parts, &text);
                continue;
            }

            try text.append(compiler.arena, byte);
            parser.position += 1;
        }

        if (text.items.len > 0) {
            try parts.append(compiler.arena, .{ .text = try compiler.arena.dupe(u8, text.items) });
        }

        std.debug.assert(parser.position <= parser.text.len);

        return .{ .type = .string, .node = .{ .template = parts.items } };
    }

    fn template_hole(
        parser: *Parser,
        parts: *std.ArrayList(Expr.TemplatePart),
        text: *std.ArrayList(u8),
    ) Error!void {
        const compiler = parser.compiler;

        std.debug.assert(parser.text[parser.position] == '$');
        std.debug.assert(parser.text[parser.position + 1] == '{');

        const end = try expression_end(compiler, parser.text, parser.position + 1);
        const value = try expression(compiler, parser.text[parser.position + 2 .. end]);

        switch (value.type) {
            .string, .int => {},
            .opt_string => return compiler.fail(
                "an optional inside a template string — add `?? \"\"`",
                .{},
            ),
            else => return compiler.fail(
                "a {s} inside a template string",
                .{@tagName(value.type)},
            ),
        }

        if (text.items.len > 0) {
            try parts.append(compiler.arena, .{ .text = try compiler.arena.dupe(u8, text.items) });
            text.clearRetainingCapacity();
        }

        try parts.append(compiler.arena, .{ .hole = try compiler.box(value) });
        parser.position = end + 1;
    }
};

fn entry_member(compiler: *Compiler, boxed: *const Expr, name: []const u8) Error!Expr {
    std.debug.assert(boxed.type == .entry);

    const Access = Expr.Member.Access;
    const members = [_]struct { name: []const u8, type: Type, access: Access }{
        .{ .name = "title", .type = .string, .access = .entry_title },
        .{ .name = "created_at", .type = .string, .access = .entry_created_at },
        .{ .name = "updated_at", .type = .string, .access = .entry_updated_at },
        .{ .name = "slug", .type = .opt_string, .access = .entry_slug },
        .{ .name = "id", .type = .string, .access = .entry_id },
        .{ .name = "type", .type = .string, .access = .entry_type },
        .{ .name = "data", .type = .data, .access = .entry_data },
    };

    std.debug.assert(members.len == 7);

    for (members) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) {
            return .{
                .type = candidate.type,
                .node = .{ .member = .{ .object = boxed, .kind = candidate.access } },
            };
        }
    }

    return compiler.fail(
        "an entry has no `{s}` (it has id, type, slug, title, created_at, updated_at, data)",
        .{name},
    );
}

fn session_member(compiler: *Compiler, boxed: *const Expr, name: []const u8) Error!Expr {
    std.debug.assert(boxed.type == .session);

    if (std.mem.eql(u8, name, "email")) {
        return .{
            .type = .opt_string,
            .node = .{ .member = .{ .object = boxed, .kind = .session_email } },
        };
    }

    return compiler.fail(
        "a session has no `{s}` (it has email, null when nobody is signed in)",
        .{name},
    );
}

fn length_member(compiler: *Compiler, boxed: *const Expr, kind: Type, name: []const u8) Error!Expr {
    std.debug.assert(kind == .collection or kind == .string);

    if (std.mem.eql(u8, name, "length")) {
        if (kind == .string) {
            return compiler.script("JavaScript UTF-16 string length", .{});
        }

        return .{ .type = .int, .node = .{ .member = .{ .object = boxed, .kind = .length } } };
    }

    return compiler.script("`.{s}` of a {s}", .{ name, @tagName(kind) });
}

// ---- text helpers ------------------------------------------------------------------

pub const Parts = struct { frontmatter: []const u8, body: []const u8 };

/// `---` fences at column 0 delimit the frontmatter; without a first-line fence, the
/// whole file is body.
pub fn split_template(source: []const u8) Parts {
    const first_end = line_end(source, 0);

    std.debug.assert(first_end <= source.len);

    if (!is_fence(source[0..first_end])) {
        return .{ .frontmatter = "", .body = source };
    }

    const frontmatter_start = past_newline(source, first_end);
    var position = frontmatter_start;

    while (position < source.len) {
        const end = line_end(source, position);

        if (is_fence(source[position..end])) {
            return .{
                .frontmatter = source[frontmatter_start..position],
                .body = source[past_newline(source, end)..],
            };
        }

        position = past_newline(source, end);
    }

    return .{ .frontmatter = "", .body = source };
}

fn is_fence(text: []const u8) bool {
    std.debug.assert(std.mem.indexOfScalar(u8, text, '\n') == null);

    if (text.len < 3 or !std.mem.startsWith(u8, text, "---")) {
        return false;
    }

    for (text[3..]) |byte| {
        if (byte != ' ' and byte != '\t') {
            return false;
        }
    }

    return true;
}

fn line_end(source: []const u8, start: u32) u32 {
    std.debug.assert(start <= source.len);

    var index = start;

    while (index < source.len) : (index += 1) {
        if (source[index] == '\n') {
            return if (index > start and source[index - 1] == '\r') index - 1 else index;
        }
    }

    std.debug.assert(index == source.len);

    return @intCast(source.len);
}

fn past_newline(source: []const u8, end: u32) u32 {
    std.debug.assert(end <= source.len);

    var index = end;

    if (index < source.len and source[index] == '\r') {
        index += 1;
    }

    if (index < source.len and source[index] == '\n') {
        index += 1;
    }

    return index;
}

/// The index of `needle` at nesting depth zero (outside parentheses, braces, brackets,
/// strings and template literals) or null. A `?` that is part of `??` does not count.
pub fn top_level(text: []const u8, needle: u8) ?u32 {
    std.debug.assert(needle != '(' and needle != ')');

    var depth: u32 = 0;
    var quote: u8 = 0;
    var index: u32 = 0;

    while (index < text.len) : (index += 1) {
        const byte = text[index];

        if (quote != 0) {
            if (byte == '\\') {
                index += 1;
            } else if (byte == quote) {
                quote = 0;
            }

            continue;
        }

        switch (byte) {
            '\'', '"', '`' => quote = byte,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            else => {
                if (depth == 0 and byte == needle and !is_nullish_pair(text, index, needle)) {
                    return index;
                }
            },
        }
    }

    return null;
}

fn is_nullish_pair(text: []const u8, index: u32, needle: u8) bool {
    std.debug.assert(index < text.len);

    if (needle != '?') {
        return false;
    }

    const next_is = index + 1 < text.len and text[index + 1] == '?';
    const previous_is = index > 0 and text[index - 1] == '?';

    return next_is or previous_is;
}

pub fn is_identifier(text: []const u8) bool {
    std.debug.assert(text.len < 1 << 20);

    if (text.len == 0 or std.ascii.isDigit(text[0])) {
        return false;
    }

    for (text) |byte| {
        if (!is_identifier_char(byte)) {
            return false;
        }
    }

    return true;
}

fn is_identifier_char(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$';
}

pub fn is_number(text: []const u8) bool {
    std.debug.assert(text.len < 1 << 20);

    if (text.len == 0) {
        return false;
    }

    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) {
            return false;
        }
    }

    return true;
}

test "the frontmatter is fenced by --- at column 0" {
    const fenced = split_template("---\nconst alpha = 1;\n---\n<p>hi</p>");
    try std.testing.expectEqualStrings("const alpha = 1;\n", fenced.frontmatter);
    try std.testing.expectEqualStrings("<p>hi</p>", fenced.body);

    const windows = split_template("---\r\nx\r\n---\r\nbody");
    try std.testing.expectEqualStrings("x\r\n", windows.frontmatter);
    try std.testing.expectEqualStrings("body", windows.body);

    const bare = split_template("<p>only body</p>");
    try std.testing.expectEqualStrings("", bare.frontmatter);
    try std.testing.expectEqualStrings("<p>only body</p>", bare.body);

    const unclosed = split_template("---\nnever closed\n");
    try std.testing.expectEqualStrings("", unclosed.frontmatter);
    try std.testing.expect(std.mem.startsWith(u8, unclosed.body, "---"));
}

test "top-level operators skip nesting, strings and the ?? pair" {
    try std.testing.expectEqual(@as(?u32, 6), top_level("a > 1 ? (b) : c", '?'));
    try std.testing.expectEqual(@as(?u32, null), top_level("a ?? b", '?'));
    try std.testing.expectEqual(@as(?u32, null), top_level("(a ? b : c)", '?'));
    try std.testing.expectEqual(@as(?u32, null), top_level("'?' + `?`", '?'));
    try std.testing.expectEqual(@as(?u32, 4), top_level("(a) : c", ':'));
    try std.testing.expect(is_identifier("post_1$"));
    try std.testing.expect(!is_identifier("1post"));
    try std.testing.expect(!is_identifier(""));
    try std.testing.expect(!is_identifier("a-b"));
    try std.testing.expect(is_number("42"));
    try std.testing.expect(!is_number(""));
    try std.testing.expect(!is_number("4x"));
}
