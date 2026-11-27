const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/role.zig");
const store = @import("../store.zig");
const role = @import("../model/role.zig");
const trash = @import("trash.zig");
const rows = @import("role/rows.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Listed = rows.Listed;

pub const namespace = public.namespace;

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const found = try store.roles.list(ctx.db, ctx.arena);
        const listed = ctx.arena.alloc(Listed, found.len) catch return error.OutOfMemory;

        for (found, listed) |row, *out| {
            out.* = try rows.listed(ctx, row);
        }

        return .{
            .roles = listed,
        };
    }
};

pub const Get = struct {
    pub const shape = public.Get;
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

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(in.name.len <= 4096);

        return .{
            .role = try rows.listed(ctx, try rows.find(ctx, in.name)),
        };
    }
};

pub const Create = struct {
    pub const shape = public.Create;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const failures = shape.failures;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (!role.valid_name(in.name) or try sdk.stored_roles.exists(ctx, in.name)) {
            return error.Invalid;
        }

        if (try store.roles.count(ctx.db) >= role.roles_max) {
            return error.Invalid;
        }

        const copied = if (in.copy.len > 0)
            try store.role_grants.of(ctx.db, ctx.arena, (try rows.find(ctx, in.copy)).name)
        else
            &.{};
        const both = [_][]const []const u8{ copied, in.grants };
        const grants = std.mem.concat(ctx.arena, []const u8, &both) catch {
            return error.OutOfMemory;
        };
        const row: store.roles.Row = .{
            .name = in.name,
            .label = in.label,
            .description = in.description,
        };

        try rows.check(row, grants);
        try rows.refuse_staff_given(ctx, row, grants);
        try store.roles.insert(ctx.db, row, ctx.now_ms);
        try store.role_grants.set(ctx.db, in.name, grants);
        ctx.emit(Created, .{
            .role = in.name,
        });

        return .{
            .role = try rows.listed(ctx, row),
        };
    }
};

pub const Update = struct {
    pub const shape = public.Update;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const failures = shape.failures;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const found = try rows.changeable(ctx, in.name);
        const row: store.roles.Row = .{
            .name = found.name,
            .label = in.label,
            .description = in.description,
            .owner = found.owner,
        };

        try rows.check(row, in.grants);
        try rows.refuse_staff_given(ctx, row, in.grants);
        try store.roles.update(ctx.db, row, ctx.now_ms);
        try store.role_grants.set(ctx.db, found.name, in.grants);
        ctx.emit(Updated, .{
            .role = found.name,
        });

        return .{
            .role = try rows.listed(ctx, row),
        };
    }
};

pub const Reset = struct {
    pub const shape = public.Reset;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const failures = shape.failures;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const found = try rows.changeable(ctx, in.name);
        const declared = try store.role_declarations.patterns_for(ctx.db, ctx.arena, found.name);

        if (found.owner.len == 0 or declared.len > role.grants_max) {
            return error.Invalid;
        }

        try rows.refuse_staff_given(ctx, found, declared);

        try store.role_grants.set(ctx.db, found.name, declared);
        ctx.emit(Updated, .{
            .role = found.name,
        });

        return .{
            .role = try rows.listed(ctx, found),
        };
    }
};

pub const Remove = struct {
    pub const shape = public.Remove;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const failures = shape.failures;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const found = try rows.changeable(ctx, in.name);

        if (try store.user_roles.sole_holders(ctx.db, found.name) > 0) {
            return ctx.fail(rows.only_role);
        }

        const label = std.fmt.allocPrint(ctx.arena, "Role {s}", .{found.label}) catch {
            return error.OutOfMemory;
        };
        const trash_id = try trash.keep(ctx, .{
            .kind = "role",
            .key = found.name,
            .label = label,
            .roots = try rows.roots_of(ctx, found.name),
        });

        try rows.drop(ctx, found.name);
        ctx.emit(Removed, .{
            .role = found.name,
        });

        return .{
            .removed = found.name,
            .trash = trash_id,
        };
    }
};

pub const operations = [_]type{ List, Get, Create, Update, Reset, Remove };

test {
    _ = @import("role/tests.zig");
    _ = @import("role/stale.zig");
}

pub const Changed = public.Changed;
pub const Created = public.Created;
pub const Updated = public.Updated;
pub const Removed = public.Removed;
pub const GrantDropped = public.GrantDropped;
