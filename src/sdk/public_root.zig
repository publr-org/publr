//! The root check: every name `publr` offers plugins is defined in a public file, one under
//! `src/publr/`, and so is every type its public signatures reach, fields and pub decls
//! included, but for `std` and the packages decided public (`publr_api`, `publr_text`,
//! `publr_ai`). A type's name says where it is defined: its file's path under `src/`, or
//! its package. Each build checks it, as `publr/root.zig` is read for the surface.
const std = @import("std");
const public = @import("../publr/root.zig");

/// How far from a root name the check follows types, a root name's own members being one:
/// past every type reached (about 1,800, by 12 levels, in 0.8.4).
const depth_max: u8 = 16;

/// The first part of a private type's name: core's folders and files under `src/`, and
/// the packages that stay Publr's own.
const private_parts = [_][]const u8{
    "adapters",
    "lib",
    "main",
    "model",
    "operations",
    "p",
    "sdk",
    "server",
    "store",
    "template",
    "ui",
    "publr_sqlite",
    "publr_http",
    "publr_auth",
    "publr_groq",
    "publr_deps",
    "publr_jit",
    "publr_wasm",
};

/// How many types the check follows at most: every public container type the root reaches.
const types_max: u32 = 4096;

/// Types are told apart by name, in this many buckets, so a type is looked for among few.
const buckets: u32 = 256;

/// A type the check follows, and the root name it was reached from.
const Reach = struct {
    from: []const u8,
    Type: type,
};

/// Each private type the public root reaches, with the root name it is reached from.
pub fn reached() []const []const u8 {
    comptime {
        @setEvalBranchQuota(types_max * 1024);

        var seen: [buckets][]const type = @splat(&.{});
        var level: []const Reach = &.{};
        var found: []const []const u8 = &.{};
        var followed: u32 = 0;

        for (std.meta.declarations(public)) |decl| {
            level = level ++ reaches(decl, types_of_value(@field(public, decl)));
        }

        for (0..depth_max + 1) |depth| {
            var next: []const Reach = &.{};

            for (level) |reach| {
                const name = @typeName(reach.Type);
                const bucket = &seen[bucket_of(name)];

                if (listed_type(bucket.*, reach.Type)) {
                    continue;
                }

                bucket.* = bucket.* ++ &[_]type{reach.Type};
                followed += 1;

                if (listed(&private_parts, first_part(name))) {
                    found = found ++ &[_][]const u8{"publr." ++ reach.from ++ ": " ++ name};
                    continue;
                }

                if (std.mem.eql(u8, first_part(name), "publr") and depth < depth_max) {
                    next = next ++ reaches(reach.from, members_of(reach.Type));
                }
            }

            level = next;
        }

        if (followed > types_max) {
            @compileError("the root check follows more than types_max types");
        }

        const done = found;

        return done;
    }
}

/// Fails the build when the public root reaches a private file, naming each type.
pub fn check() void {
    comptime {
        const found = reached();

        if (found.len > 0) {
            var said: []const u8 = "";

            for (found) |name| {
                said = said ++ "\n  " ++ name;
            }

            @compileError("the public root (src/publr/root.zig) reaches types defined " ++
                "outside src/publr/:" ++ said);
        }
    }
}

/// Whether `forwarded` (the `publr` module's root) forwards exactly the public root's names.
pub fn forwards_all(comptime forwarded: type) bool {
    comptime {
        std.debug.assert(std.meta.declarations(public).len > 0);

        for (std.meta.declarations(public)) |decl| {
            if (!@hasDecl(forwarded, decl)) {
                return false;
            }
        }

        for (std.meta.declarations(forwarded)) |decl| {
            if (!@hasDecl(public, decl)) {
                return false;
            }
        }

        return true;
    }
}

fn reaches(comptime from: []const u8, comptime types: []const type) []const Reach {
    comptime {
        std.debug.assert(from.len > 0);

        var out: []const Reach = &.{};

        for (types) |Type| {
            out = out ++ &[_]Reach{.{
                .from = from,
                .Type = Type,
            }};
        }

        const done = out;

        return done;
    }
}

/// The container types a value is or names: its own type, or itself when it is one.
fn types_of_value(comptime value: anytype) []const type {
    const Value = @TypeOf(value);

    return if (Value == type) types_of(value) else types_of(Value);
}

/// The container types `Type` names, through pointers, optionals, arrays, error unions and
/// a function's parameters and answer.
fn types_of(comptime Type: type) []const type {
    comptime {
        std.debug.assert(@typeName(Type).len > 0);

        return switch (@typeInfo(Type)) {
            .pointer => |pointer| types_of(pointer.child),
            .optional => |optional| types_of(optional.child),
            .array => |array| types_of(array.child),
            .vector => |vector| types_of(vector.child),
            .error_union => |error_union| types_of(error_union.payload),
            .@"fn" => |function| types_of_fn(function),
            .@"struct", .@"enum", .@"union", .@"opaque" => &.{Type},
            else => &.{},
        };
    }
}

fn types_of_fn(comptime function: std.builtin.Type.Fn) []const type {
    comptime {
        std.debug.assert(function.param_types.len == function.param_attrs.len);

        var out: []const type = &.{};

        for (function.param_types) |param| {
            if (param) |Param| {
                out = out ++ types_of(Param);
            }
        }

        if (function.return_type) |Return| {
            out = out ++ types_of(Return);
        }

        const done = out;

        return done;
    }
}

/// What a public container's fields and pub decls name.
fn members_of(comptime Type: type) []const type {
    comptime {
        std.debug.assert(std.mem.startsWith(u8, @typeName(Type), "publr"));

        var out: []const type = &.{};

        switch (@typeInfo(Type)) {
            inline .@"struct", .@"union" => |container| {
                for (container.field_types) |Field| {
                    out = out ++ types_of(Field);
                }
            },
            else => {},
        }

        for (std.meta.declarations(Type)) |decl| {
            out = out ++ types_of_value(@field(Type, decl));
        }

        const done = out;

        return done;
    }
}

fn bucket_of(comptime name: []const u8) u32 {
    const middle: u32 = name[name.len / 2];
    const last: u32 = name[name.len - 1];

    return @intCast((name.len * 31 + middle * 7 + last) % buckets);
}

fn listed_type(comptime types: []const type, comptime Type: type) bool {
    std.debug.assert(types.len <= types_max);

    for (types) |one| {
        if (one == Type) {
            return true;
        }
    }

    return false;
}

fn first_part(comptime name: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, name, ".(") orelse name.len;

    return name[0..end];
}

fn listed(comptime names: []const []const u8, comptime name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |one| {
        if (std.mem.eql(u8, one, name)) {
            return true;
        }
    }

    return false;
}

test "publr forwards the public root's names and nothing besides" {
    try std.testing.expect(comptime forwards_all(@import("publr_sdk")));
    try std.testing.expect(comptime !forwards_all(struct {}));
}
