//! `publr.operation.define(In, Out, .{ .name, .kind, .authorize, .untrusted_callers,
//! .public_api, .validate, .destructive, .limit, .secret, .deprecated, .run })`: an
//! operation's parts, without its words. `Described` adds them when the plugin is bound to
//! its doc comments: the description, details, `Fails:` and `Example:` from the comment
//! above it (or its file's `//!`), each field's from the `///` on it.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const comptime_json = @import("../../model/comptime_json.zig");
const plugin_define = @import("define.zig");
const PluginCtx = @import("context.zig").PluginCtx;
const plugin_words = @import("words.zig");

pub const Kind = sdk.operation.Kind;
pub const verb_len_max: u32 = 48;

const option_names = [_][]const u8{
    "name",        "kind",  "authorize", "untrusted_callers", "public_api", "validate",
    "destructive", "limit", "secret",    "deprecated",        "run",
};

/// A ready answer to who may call, as data a site can read and override; the other kind of
/// `.authorize` is a function of the plugin's own taking the context and the input.
pub const Answer = @import("../../model/caller_answer.zig").Answer;

pub const Limit = struct {
    per_minute: u32,
};

pub fn define(comptime Input: type, comptime Output: type, comptime options: anytype) type {
    comptime {
        const Options = @TypeOf(options);

        for (std.meta.fieldNames(Options)) |given| {
            if (!plugin_define.listed_in(&option_names, given)) {
                @compileError("operation " ++ options.name ++ ": no option `" ++ given ++ "`");
            }
        }

        const complete = @hasField(Options, "name") and @hasField(Options, "run") and
            @hasField(Options, "kind");

        if (!complete) {
            @compileError("an operation needs `.name`, `.kind` and `.run`");
        }

        if (options.name.len == 0 or options.name.len > verb_len_max) {
            @compileError("operation " ++ options.name ++ ": `.name` is a verb of 1 to 48 chars");
        }

        if (std.mem.indexOfScalar(u8, options.name, '.') != null) {
            @compileError("operation " ++ options.name ++ ": `.name` is the verb alone; " ++
                "the plugin's name goes in front of it");
        }

        if (@hasField(Options, "secret")) {
            for (options.secret) |field| {
                if (!@hasField(Input, @tagName(field))) {
                    @compileError("operation " ++ options.name ++ ": `.secret` names `" ++
                        @tagName(field) ++ "`, which is no field of its input");
                }
            }
        }

        return struct {
            pub const publr_operation_definition = true;
            pub const In = Input;
            pub const Out = Output;
            pub const verb = options.name;
            pub const given = options;
        };
    }
}

pub fn is_definition(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "publr_operation_definition");
}

/// The operation the core runs: the definition with its words, named `<plugin>.<verb>`.
pub fn Described(comptime Definition: type, comptime plugin: []const u8, comptime Docs: type) type {
    comptime {
        const options = Definition.given;
        const Options = @TypeOf(options);
        const full_name = plugin ++ "." ++ Definition.verb;
        const words = plugin_define.words(Docs, "operation:" ++ Definition.verb) orelse
            @compileError("operation " ++ full_name ++ ": needs words: a `//!` comment at the " ++
                "top of its file, or `///` right above it");
        const untrusted = @hasField(Options, "untrusted_callers") and options.untrusted_callers;

        if (@hasField(Options, "authorize") and @TypeOf(options.authorize) == Answer) {
            if (options.authorize == .visitor) {
                @compileError("operation " ++ full_name ++ ": leave `.authorize` out; " ++
                    "`.untrusted_callers = true` alone lets anyone call");
            }

            if (options.authorize == .signed_in and !untrusted) {
                @compileError("operation " ++ full_name ++ ": `user_is_signed_in` needs " ++
                    "`.untrusted_callers = true`");
            }
        }

        return struct {
            // Read where it is first used, each operation's words on their own.
            const parsed = sections(full_name, words);

            pub const definition = Definition;
            pub const name = full_name;
            pub const description = parsed.description;
            pub const details = parsed.details;
            pub const kind: Kind = options.kind;
            pub const In = Definition.In;
            pub const Out = Definition.Out;
            pub const example: In = comptime_json.parse(In, parsed.example_in);
            pub const example_out: Out = comptime_json.parse(Out, parsed.example_out);
            /// The example as written: what an installed plugin's build runs.
            pub const example_json = parsed.example_in;
            pub const example_out_json = parsed.example_out;
            pub const field_docs: sdk.operation.Docs(In) = field_words(full_name, In, Docs);
            pub const output_docs: sdk.operation.Docs(Out) = field_words(full_name, Out, Docs);
            pub const failures: []const sdk.operation.Failure = parsed.failures;
            pub const open = @hasField(Options, "authorize") or untrusted;
            pub const destroys = @hasField(Options, "destructive") and options.destructive;
            pub const untrusted_callers = untrusted;
            pub const public_api = @hasField(Options, "public_api") and options.public_api;
            pub const answer: ?Answer = answer_of(options, untrusted);
            pub const limit: ?Limit = if (@hasField(Options, "limit")) .{
                .per_minute = options.limit.per_minute,
            } else null;
            pub const secret: []const []const u8 = secret_names(options);
            pub const deprecated: ?sdk.operation.Deprecated = deprecated_of(options);
            /// The `.validate` function's `///`: what is checked, the "Checked" line.
            pub const checked: []const u8 = plugin_define.words(
                Docs,
                "operation:" ++ Definition.verb ++ ":validate",
            ) orelse "";
            /// The "Who may call it" line: a ready answer in words, or the `.authorize`
            /// function's `///`.
            pub const who_may_call: []const u8 = who_of(
                full_name,
                answer,
                @hasField(Options, "authorize") and @TypeOf(options.authorize) != Answer,
                plugin_define.words(Docs, "operation:" ++ Definition.verb ++ ":authorize"),
            );

            pub fn run(ctx: *PluginCtx, in: In, granted: *const sdk.Grant) sdk.Error!Out {
                std.debug.assert(name.len > 0);
                std.debug.assert(granted.allows());
                comptime std.debug.assert(@hasField(Options, "run"));

                const custom = comptime @hasField(Options, "authorize") and
                    @TypeOf(options.authorize) != Answer;

                if (custom) {
                    if (!options.authorize(ctx, in)) {
                        return error.Denied;
                    }
                }

                if (comptime @hasField(Options, "validate")) {
                    var problems: Problems(In) = .{};

                    options.validate(in, &problems);

                    if (!problems.is_empty()) {
                        return problems.refuse(ctx);
                    }
                }

                return options.run(ctx, in);
            }
        };
    }
}

/// Whether the ready answer lets this caller through. Administrators pass every answer,
/// except through an app's address, where they are signed-in people like any other.
pub fn admits(answer: Answer, caller: sdk.Caller, through_app: bool) bool {
    std.debug.assert(@intFromEnum(caller) <= @intFromEnum(sdk.Caller.plugin));
    std.debug.assert(@intFromEnum(answer) <= @intFromEnum(Answer.plugin_calls));

    if (!through_app and (caller == .system or caller.holds("admin"))) {
        return true;
    }

    return switch (answer) {
        .visitor => true,
        .signed_in => caller.is_authenticated() and caller != .plugin,
        .roles => |names| for (names) |wanted| {
            if (caller == .system or caller.holds(wanted)) {
                break true;
            }
        } else false,
        .plugin_calls => caller == .plugin,
    };
}

/// What `.validate` fills: `problems.add(.page, "Must start with /")`. Every problem is told
/// at once, each beside its field.
pub fn Problems(comptime In: type) type {
    return struct {
        const Self = @This();

        items: [sdk.operation.problems_max]sdk.operation.Problem = undefined,
        len: u32 = 0,

        pub fn add(self: *Self, comptime field: std.meta.FieldEnum(In), reason: []const u8) void {
            std.debug.assert(reason.len > 0);
            std.debug.assert(self.len <= sdk.operation.problems_max);

            if (self.len == sdk.operation.problems_max) {
                return;
            }

            self.items[self.len] = .{
                .field = @tagName(field),
                .message = plugin_words.kept(reason),
            };
            self.len += 1;
        }

        pub fn slice(self: *const Self) []const sdk.operation.Problem {
            std.debug.assert(self.len <= sdk.operation.problems_max);
            std.debug.assert(self.items.len == sdk.operation.problems_max);

            return self.items[0..self.len];
        }

        pub fn is_empty(self: *const Self) bool {
            std.debug.assert(self.len <= sdk.operation.problems_max);

            return self.len == 0;
        }

        /// Refuses the call with every problem: `Invalid`, answered with a `problems` list.
        pub fn refuse(self: *const Self, ctx: *PluginCtx) error{ Invalid, OutOfMemory } {
            std.debug.assert(!self.is_empty());
            std.debug.assert(self.len <= sdk.operation.problems_max);

            return ctx.refuse(self.slice());
        }
    };
}

const Sections = struct {
    description: []const u8,
    details: []const u8,
    failures: []const sdk.operation.Failure,
    example_in: []const u8,
    example_out: []const u8,
};

/// An operation's words cut into their parts: the first line, the paragraphs after it, and
/// the `Fails:` and `Example:` sections.
fn sections(comptime full_name: []const u8, comptime words: []const u8) Sections {
    comptime {
        @setEvalBranchQuota(words.len * 50 + 10_000);

        var lines = std.mem.splitScalar(u8, words, '\n');
        const first = std.mem.trim(u8, lines.next().?, " ");
        var details: []const u8 = "";
        var failures: []const sdk.operation.Failure = &.{};
        var example_in: []const u8 = "";
        var example_out: []const u8 = "";
        var section: enum { details, fails, example } = .details;
        var reading: enum { none, in, out } = .none;

        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " ");

            if (std.mem.eql(u8, line, "Fails:")) {
                section = .fails;
                continue;
            }

            if (std.mem.eql(u8, line, "Example:")) {
                section = .example;
                continue;
            }

            switch (section) {
                .details => details = details ++ (if (details.len > 0) "\n" else "") ++ raw,
                .fails => if (line.len > 0) {
                    failures = failures ++ [_]sdk.operation.Failure{failure(full_name, line)};
                },
                .example => {
                    if (std.mem.startsWith(u8, line, "in:")) {
                        reading = .in;
                        example_in = line["in:".len..];
                    } else if (std.mem.startsWith(u8, line, "out:")) {
                        reading = .out;
                        example_out = line["out:".len..];
                    } else if (reading == .in) {
                        example_in = example_in ++ "\n" ++ line;
                    } else if (reading == .out) {
                        example_out = example_out ++ "\n" ++ line;
                    }
                },
            }
        }

        if (first.len == 0) {
            @compileError("operation " ++ full_name ++ ": the first line of its words is its " ++
                "description");
        }

        if (example_in.len == 0 or example_out.len == 0) {
            @compileError("operation " ++ full_name ++ ": needs `Example:` with an `in:` and " ++
                "an `out:` line of JSON");
        }

        return .{
            .description = first,
            .details = std.mem.trim(u8, details, " \n"),
            .failures = failures,
            .example_in = example_in,
            .example_out = example_out,
        };
    }
}

/// `- NotEnoughStock (409): fewer left than asked`; the status defaults to 409. 401 and 429
/// keep core's meaning and no 5xx is a plugin's.
fn failure(comptime full_name: []const u8, comptime line: []const u8) sdk.operation.Failure {
    comptime {
        const body = std.mem.trim(u8, std.mem.trimStart(u8, line, "-"), " ");
        const colon = std.mem.indexOfScalar(u8, body, ':') orelse
            @compileError("operation " ++ full_name ++ ": a `Fails:` line is " ++
                "`- Name (status): what it means`");
        const head = std.mem.trim(u8, body[0..colon], " ");
        const message = std.mem.trim(u8, body[colon + 1 ..], " ");
        const open = std.mem.indexOfScalar(u8, head, '(');
        const failure_name = std.mem.trim(u8, if (open) |at| head[0..at] else head, " ");
        const status: u16 = if (open) |at|
            std.fmt.parseInt(u16, std.mem.trim(u8, head[at + 1 ..], " )"), 10) catch
                @compileError("operation " ++ full_name ++ ": `" ++ head ++ "` needs a status")
        else
            409;

        if (status == 401 or status == 429 or status < 400 or status > 499) {
            @compileError("operation " ++ full_name ++ ": failure " ++ failure_name ++
                " takes a 4xx status other than 401 and 429");
        }

        const found: sdk.operation.Failure = .{
            .name = failure_name,
            .status = status,
            .message = message,
        };

        if (!sdk.operation.valid_failure(found)) {
            @compileError("operation " ++ full_name ++ ": failure `" ++ failure_name ++
                "` needs a name of letters starting upper-case and a description");
        }

        return found;
    }
}

/// Every field's `///`, a missing one failing the build.
fn field_words(
    comptime full_name: []const u8,
    comptime Shape: type,
    comptime Docs: type,
) sdk.operation.Docs(Shape) {
    comptime {
        var docs: sdk.operation.Docs(Shape) = .{};

        for (std.meta.fields(Shape)) |field| {
            const key = @typeName(Shape) ++ "." ++ field.name;
            const text = plugin_define.words(Docs, key) orelse
                @compileError("operation " ++ full_name ++ ": field `" ++ field.name ++
                    "` of " ++ @typeName(Shape) ++ " needs a `///` comment");

            @field(docs, field.name) = text;
        }

        const done = docs;

        return done;
    }
}

/// The ready answer: the one written, else anyone when untrusted callers were promised,
/// else none (the default: administrators and the roles they granted).
fn answer_of(comptime options: anytype, comptime untrusted: bool) ?Answer {
    comptime {
        const Options = @TypeOf(options);

        const written = @hasField(Options, "authorize");
        const found: ?Answer = if (!written)
            (if (untrusted) .visitor else null)
        else if (@TypeOf(options.authorize) == Answer)
            options.authorize
        else
            null;

        // Anyone only ever where untrusted callers were promised.
        std.debug.assert(found == null or found.? != .visitor or untrusted);

        return found;
    }
}

/// Who may call, as `--help` says it.
fn who_of(
    comptime full_name: []const u8,
    comptime answer: ?Answer,
    comptime custom: bool,
    comptime function_words: ?[]const u8,
) []const u8 {
    comptime {
        if (custom) {
            return function_words orelse "the plugin's own check";
        }

        const ready = answer orelse return "administrators, and roles granted " ++ full_name;

        return switch (ready) {
            .visitor => "anyone",
            .signed_in => "anyone signed in",
            .plugin_calls => "other plugins",
            .roles => |names| roles: {
                var joined: []const u8 = "administrators, and anyone with the role ";

                for (names, 0..) |role, index| {
                    joined = joined ++ (if (index == 0) "" else " or ") ++ role;
                }

                break :roles joined;
            },
        };
    }
}

/// `.deprecated` as written, `.since` with `.instead` and `.why` when given.
fn deprecated_of(comptime options: anytype) ?sdk.operation.Deprecated {
    comptime {
        if (!@hasField(@TypeOf(options), "deprecated")) {
            return null;
        }

        const given = options.deprecated;
        var found: sdk.operation.Deprecated = .{
            .since = given.since,
        };

        for (std.meta.fieldNames(@TypeOf(given))) |field| {
            @field(found, field) = @field(given, field);
        }

        const kept = found;

        std.debug.assert(kept.since.len > 0);

        return kept;
    }
}

/// The input fields `.secret` names, masked wherever the call's input is shown.
fn secret_names(comptime options: anytype) []const []const u8 {
    comptime {
        if (!@hasField(@TypeOf(options), "secret")) {
            return &.{};
        }

        var names: [options.secret.len][]const u8 = undefined;

        for (options.secret, 0..) |field, index| {
            names[index] = @tagName(field);
        }

        const kept = names;

        std.debug.assert(kept.len > 0);

        return &kept;
    }
}

test "an operation described from its words" {
    const In = struct {
        page: []const u8,
    };
    const Out = struct {
        yes: u32,
    };
    const Docs = @import("define.zig").Words(.{
        .{ "operation:answer", "Records an answer.\n\nOne per visitor.\n\nFails:\n" ++
            "- Closed (410): answers are closed\n\nExample:\n  in: { \"page\": \"/a\" }\n" ++
            "  out: { \"yes\": 1 }" },
        .{ @typeName(In) ++ ".page", "The page" },
        .{ @typeName(Out) ++ ".yes", "Yes answers" },
    });
    const Definition = define(In, Out, .{
        .name = "answer",
        .kind = .write,
        .untrusted_callers = true,
        .secret = &.{.page},
        .deprecated = .{
            .since = "0.4.0",
            .instead = "helpful.rate",
        },
        .run = struct {
            fn run(_: *PluginCtx, _: In) sdk.Error!Out {
                return .{
                    .yes = 1,
                };
            }
        }.run,
    });
    const Operation = Described(Definition, "helpful", Docs);

    try std.testing.expectEqualStrings("helpful.answer", Operation.name);
    try std.testing.expectEqualStrings("Records an answer.", Operation.description);
    try std.testing.expectEqualStrings("One per visitor.", Operation.details);
    try std.testing.expectEqualStrings("Closed", Operation.failures[0].name);
    try std.testing.expectEqual(410, Operation.failures[0].status);
    try std.testing.expectEqualStrings("/a", Operation.example.page);
    try std.testing.expectEqual(1, Operation.example_out.yes);
    try std.testing.expectEqualStrings("The page", Operation.field_docs.page);
    try std.testing.expect(Operation.open and Operation.untrusted_callers);
    try std.testing.expectEqual(Answer.visitor, Operation.answer.?);
    try std.testing.expectEqualStrings("page", Operation.secret[0]);
    try std.testing.expectEqualStrings(
        "helpful.answer is deprecated since 0.4.0; call helpful.rate instead",
        comptime sdk.operation.deprecation_text(Operation),
    );
    try std.testing.expectEqualStrings("anyone", Operation.who_may_call);
}

test "--help says what is checked and who may call, in the functions' words" {
    const In = struct {
        page: []const u8,
    };
    const Out = struct {
        yes: u32,
    };
    const Docs = @import("define.zig").Words(.{
        .{ "operation:answer", "Records an answer.\n\nExample:\n  in: { \"page\": \"/a\" }\n" ++
            "  out: { \"yes\": 1 }" },
        .{ "operation:answer:validate", "A page of 1 to 200 characters." },
        .{ "operation:answer:authorize", "The person whose page it is." },
        .{ @typeName(In) ++ ".page", "The page" },
        .{ @typeName(Out) ++ ".yes", "Yes answers" },
    });
    const parts = struct {
        fn run(_: *PluginCtx, _: In) sdk.Error!Out {
            return .{
                .yes = 1,
            };
        }

        fn own(_: *PluginCtx, _: In) bool {
            return true;
        }

        fn check(_: In, _: *Problems(In)) void {}
    };
    const Own = Described(define(In, Out, .{
        .name = "answer",
        .kind = .write,
        .authorize = parts.own,
        .validate = parts.check,
        .run = parts.run,
    }), "helpful", Docs);
    const Roles = Described(define(In, Out, .{
        .name = "answer",
        .kind = .write,
        .authorize = Answer{
            .roles = &.{ "moderator", "editor" },
        },
        .run = parts.run,
    }), "helpful", Docs);
    const Default = Described(define(In, Out, .{
        .name = "answer",
        .kind = .write,
        .run = parts.run,
    }), "other", @import("define.zig").Words(.{
        .{ "operation:answer", "Records an answer.\n\nExample:\n  in: { \"page\": \"/a\" }\n" ++
            "  out: { \"yes\": 1 }" },
        .{ @typeName(In) ++ ".page", "The page" },
        .{ @typeName(Out) ++ ".yes", "Yes answers" },
    }));
    var buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    try sdk.help.command(Own, &out);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.buffered(),
        "\nChecked: A page of 1 to 200 characters.\n" ++
            "Who may call it: The person whose page it is.\n",
    ) != null);
    try std.testing.expectEqualStrings(
        "administrators, and anyone with the role moderator or editor",
        Roles.who_may_call,
    );
    try std.testing.expectEqualStrings("", Default.checked);
    try std.testing.expectEqualStrings(
        "administrators, and roles granted other.answer",
        Default.who_may_call,
    );
}

test "ready answers" {
    const admin: sdk.Caller = .{
        .user = .{
            .id = "ada",
        },
    };
    const editor: sdk.Caller = .{
        .user = .{
            .id = "bo",
            .roles = &.{"editor"},
        },
    };

    try std.testing.expect(admits(.signed_in, editor, true));
    try std.testing.expect(!admits(.signed_in, .anonymous, true));
    try std.testing.expect(admits(.{
        .roles = &.{"editor"},
    }, editor, false));
    try std.testing.expect(!admits(.plugin_calls, admin, true));
    try std.testing.expect(admits(.plugin_calls, admin, false));
}
