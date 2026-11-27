//! The sample note type as Publr holds it.
//!
//! Reads the note type's definition through `content_type.get`, a value laid out like any
//! other: how many fields it has, which a note must hold, the option the sampler's editions
//! read on the note, and how many taxonomies file it. Administrators may call it.
//!
//! Example:
//!   in: {}
//!   out: { "fields": 2, "required": ["note"], "printed": "own", "taxonomies": 2 }
const publr = @import("publr");
const std = @import("std");

pub const In = struct {};

pub const Out = struct {
    /// How many fields the type has
    fields: u32,
    /// The fields a note must hold
    required: []const []const u8,
    /// What the note says through the editions' `printed` option
    printed: []const u8,
    /// How many taxonomies file it
    taxonomies: u32,
};

fn run(ctx: *publr.Ctx, _: In) publr.Error!Out {
    const got = try ctx.call(publr.operations.content_type.Get, .{
        .type = "sampler.sample_note",
    });
    const def: publr.content_type.Def = got.definition;
    var required: std.ArrayList([]const u8) = .empty;
    var printed: []const u8 = "";

    std.debug.assert(def.handle.len > 0);

    for (def.fields) |field| {
        if (field.validation.required) {
            try required.append(ctx.arena(), field.name);
        }

        for (field.wrapped) |wrapped| {
            if (std.mem.eql(u8, wrapped.option, "printed")) {
                printed = wrapped.value;
            }
        }
    }

    std.debug.assert(required.items.len <= def.fields.len);

    return .{
        .fields = @intCast(def.fields.len),
        .required = required.items,
        .printed = printed,
        .taxonomies = @intCast(def.taxonomies.len),
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "outline",
    .kind = .read,
    .run = run,
});
