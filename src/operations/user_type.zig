//! The types of user plugins register (customers, members, students), and which apps each
//! may sign in to: a setting on the type that administrators and agents change.
const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/user_type.zig");
const store = @import("../store.zig");
const model = @import("../model/user_type.zig");
const user_types = @import("../sdk/user_types.zig");
const operation_define = @import("../publr/plugin/operation_define.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace = public.namespace;

pub const operations = [_]type{ List, Set };

pub const Listed = public.Listed;

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const untrusted_callers = shape.untrusted_callers;
    pub const answer = shape.answer;
    pub const example_signed_in = shape.example_signed_in;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const declared = try user_types.all(ctx);
        const listed = try ctx.arena.alloc(Listed, declared.len);

        for (declared, listed) |one, *each| {
            each.* = .{
                .name = one.name,
                .label = one.label,
                .plugin = one.plugin,
                .apps = try user_types.apps_of(ctx, one),
                .refused_role = try user_types.staff_role_given(ctx, one) orelse "",
            };
        }

        std.debug.assert(listed.len == declared.len);

        return .{
            .types = listed,
        };
    }
};

pub const Set = struct {
    pub const shape = public.Set;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: Set.In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (!model.valid_name(in.user_type) or model.apps_problem(in.apps) != null) {
            return error.Invalid;
        }

        if (try user_types.find(ctx, in.user_type) == null) {
            return error.NotFound;
        }

        const setting: model.Setting = .{
            .apps = in.apps,
        };
        const text = try sdk.stringify(ctx.arena, setting);
        const key = try user_types.setting_key(ctx.arena, in.user_type);

        try store.settings.set(ctx.db, key, text, ctx.now_ms);

        return .{
            .user_type = in.user_type,
            .apps = in.apps,
        };
    }
};
