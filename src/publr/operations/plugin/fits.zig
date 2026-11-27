//! Whether each installed plugin fits this Publr, as an update asks it of the release it
//! would move to: run by that release on a copy of the site (`publr upgrade --check`), or by
//! the site's own Publr to see what is on its way out.
const operation = @import("../../operation.zig");

pub const State = enum {
    /// Everything it uses is here, and none of it on its way out.
    fits,
    /// It fits; some of what it uses is deprecated.
    deprecations,
    /// It does not fit: built with a later Publr, or using what this one lacks.
    blocked,
    /// Built before plugins said what they use: nothing to check it by.
    unchecked,
};

pub const Used = struct {
    /// As its `uses` names it: `call:money.texts`.
    item: []const u8,
    removed_on: []const u8,
    instead: []const u8 = "",
    migration: []const u8,
};

pub const Plugin = struct {
    name: []const u8,
    version: []const u8,
    state: State,
    /// Why it does not fit, when blocked.
    reason: []const u8 = "",
    deprecated: []const Used = &.{},
};

pub const Fits = struct {
    pub const name = "plugin.fits";
    pub const description = "Say whether each installed plugin fits this Publr";
    pub const details =
        \\Administrators only. Each installed plugin, by what its manifest says: `fits`,
        \\`deprecations` (it fits; each deprecated item it uses with the day it goes and what
        \\to change), `blocked` (built with a later Publr, or using what this Publr lacks, with
        \\the reason) or `unchecked` (built before plugins said what they use). `publr upgrade
        \\--check` asks it of the release a site would move to, on a copy of the site.
        \\Changes nothing.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        publr: []const u8,
        plugins: []const Plugin,
        more: bool = false,
    };
    pub const field_docs: operation.Docs(In) = .{
        .limit = "How many installed plugins to look at; 50 when omitted, up to 200",
        .offset = "How many to pass over first",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .publr = "This Publr's release",
        .plugins = "Each installed plugin: `name`, `version`, `state`, `reason`, `deprecated`",
        .more = "Whether more follow past this page",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .publr = "0.8.4",
        .plugins = &.{.{
            .name = "deposits",
            .version = "0.2.0",
            .state = .blocked,
            .reason = "deposits 0.2.0 uses call:payment.hold, which Publr 0.8.4 does not have.",
        }},
    };
};
