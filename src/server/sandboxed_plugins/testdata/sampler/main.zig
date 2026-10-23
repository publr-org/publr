//! A sample of every part of the plugin contract, for the two-mode check.
//!
//! Every part of the plugin contract a sandboxed plugin can declare, once, so the two-mode
//! check sees each part run sandboxed and compiled in: an operation open to anyone, a write
//! with a before hook that reshapes its input and an after hook that emits an event, an
//! `on` hook that answers the event with a record, its own types and a custom field group,
//! and a page of its own in the plugin frame, drawn by a read.
//! Its page has an entry in the top bar (with the notes counted), its types sit under a menu
//! item of its own, and this text is what its page in the admin says about it.
//! Compiled in, it also answers a route, lists it in Settings,
//! keeps a state, takes `--sampler-in <folder>` off a command, notes the port `serve` got,
//! and answers the operator's `ping`: what only a compiled-in plugin does, left out of its
//! sandboxed build.
//! Notes, a log the notes' events leave, and a greeting open to anyone. A note's reminder
//! time queues a job, and another server may ping it through a webhook.
const publr = @import("publr");

const Native = @import("native.zig");

const Notes = @import("records/notes.zig");
const Logs = @import("records/logs.zig");
const Tallies = @import("records/tallies.zig");
const Reviews = @import("records/reviews.zig");
const Visits = @import("records/visits.zig");
const Profile = @import("records/profile.zig");
const Noted = @import("events/noted.zig");
const Place = @import("kinds/place.zig");

const Hello = @import("operations/hello.zig");
const Hi = @import("operations/hi.zig");
const Echo = @import("operations/echo.zig");
const Note = @import("operations/note.zig");
const ReadLogs = @import("operations/logs.zig");
const Page = @import("operations/page.zig");
const Count = @import("operations/count.zig");
const NotePanel = @import("operations/note_panel.zig");
const Wave = @import("operations/wave.zig");
const Submit = @import("operations/submit.zig");
const Later = @import("operations/later.zig");
const Measure = @import("operations/measure.zig");
const Reference = @import("operations/reference.zig");
const Motto = @import("operations/motto.zig");
const HasMotto = @import("rules/has_motto.zig");

const WriteNote = @import("jobs/write_note.zig");
const Tick = @import("jobs/tick.zig");
const Remind = @import("jobs/remind.zig");

const Ping = @import("webhooks/ping.zig");

const Shout = @import("hooks/shout.zig");
const Announce = @import("hooks/announce.zig");
const LogNote = @import("hooks/log_note.zig");
const NoteTitle = @import("hooks/note_title.zig");
const Double = @import("hooks/double.zig");

const manifest: publr.Manifest = .{
    .name = "sampler",
    .version = "0.1.0",
};

/// Its types in a part of the admin of their own.
const notes_menu: publr.MenuItem = .{
    .name = "notes",
    .label = publr.t("Sample notes"),
    .icon = "sampler.note",
};

const pages = [_]publr.plugin.Page{
    .{
        .path = "log",
        .label = "Sampler log",
        .icon = "stack",
        .operation = Page.operation,
        .top_bar = .{
            .count = Count.operation,
        },
    },
    .{
        .path = "reference",
        .label = "SDK reference",
        .icon = "code",
        .operation = Reference.operation,
    },
};

/// A box on each sample note's form, drawn in the plugin frame.
const panels = [_]publr.plugin.Panel{.{
    .type = "sampler.sample_note",
    .label = "Sampler",
    .operation = NotePanel.operation,
}};

/// An action on the rows of any page that names a `sampler` slot.
const row_actions = [_]publr.plugin.RowAction{.{
    .slot = "sampler",
    .label = "Open the log",
    .path = "/admin/plugin/sampler/log",
    .operation = ReadLogs.operation,
}};

/// Secrets sampler declares, listed with it under Settings › Secrets either way it runs.
const Secrets = struct {
    /// Sampler key
    ///
    /// Any text; what the sampler's ping webhook receives carries it.
    SAMPLER_KEY: publr.Secret,
};

const permissions = .{.{
    .key = "http.fetch",
    .domains = &.{"sampler.example"},
    .reason = "Holds a key for the sampler service",
}};

/// A status sampler adds to greeter's salutations: the same flow either way it runs.
const added_statuses = .{.{
    .to = "greeter.salutation",
    .status = "sampled",
    .label = "Sampled",
    .transitions = .{
        .{
            .name = "sample",
            .from = .{"draft"},
            .to = "sampled",
            .label = "Sample it",
        },
        .{
            .name = "release",
            .from = .{"sampled"},
            .to = "published",
            .label = "Release",
        },
    },
}};

const records = [_]type{ Notes.record, Logs.record, Tallies.record, Reviews.record };
/// Compiled in, a type whose field is of the sampler's own kind.
const native_records = records ++ [_]type{Visits.record};
const jobs = [_]type{ WriteNote.job, Tick.job, Remind.job };
const webhooks = [_]type{Ping.webhook};

const operations = [_]type{
    Hello.operation,
    Echo.operation,
    Note.operation,
    ReadLogs.operation,
    Page.operation,
    Count.operation,
    NotePanel.operation,
    Wave.operation,
    Submit.operation,
    Later.operation,
    Measure.operation,
    Reference.operation,
    Hi.operation,
};
/// Compiled in, a write to the sampler's own field group on users.
const native_operations = operations ++ [_]type{Motto.operation};

const hooks = .{
    publr.before(Note.operation, Shout.run),
    publr.after(Note.operation, Announce.run),
    publr.on(Noted.event, LogNote.run),
    publr.modify("sampler.sample_note.title", NoteTitle.run),
    publr.modify("sampler.*", Double.run),
};

const field_groups = .{
    .{
        .fields = Profile.Fields,
        .location = Profile.location,
    },
};

const icons = .{
    .{
        .name = "note",
        .svg = @embedFile("icons/note.svg"),
    },
};

/// What only a compiled-in plugin carries (routes, Settings pages, operator commands, a state,
/// process hooks) takes the host's own modules, which the sandbox lacks: its sandboxed build
/// registers the rest.
pub const plugin = if (publr.plugin.guest.mode == .native)
    publr.plugin.define(manifest, .{
        .records = &native_records,
        .field_kinds = &.{Place.kind},
        .register_location_rules = .{HasMotto.location_rule},
        .jobs = &jobs,
        .webhooks = &webhooks,
        .register_fields = field_groups,
        .operations = native_operations,
        .hooks = hooks,
        .events = &.{Noted.event},
        .secrets = Secrets,
        .permissions = permissions,
        .register_statuses = added_statuses,
        .menu = &.{notes_menu},
        .icons = icons,
        .pages = pages,
        .panels = panels,
        .row_actions = row_actions,
        .settings_pages = Native.settings_pages,
        .extend = Native.extend,
    })
else
    publr.plugin.define(manifest, .{
        .records = &records,
        .jobs = &jobs,
        .webhooks = &webhooks,
        .register_fields = field_groups,
        .operations = operations,
        .hooks = hooks,
        .events = &.{Noted.event},
        .secrets = Secrets,
        .permissions = permissions,
        .register_statuses = added_statuses,
        .menu = &.{notes_menu},
        .icons = icons,
        .pages = pages,
        .panels = panels,
        .row_actions = row_actions,
    });
