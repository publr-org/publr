//! Core's permission keys: the spec's table, each with what narrows it and the flags it
//! takes.
const permission = @import("../permission.zig");

const Permission = permission.Permission;
const Flag = permission.Flag;

const read_flags = [_]Flag{ .drafts, .private, .internal };
const publish_flag = [_]Flag{.publish};
const private_flag = [_]Flag{.private};

pub const core = [_]Permission{
    .{
        .key = "records.read",
        .sentence = "Read what visitors see on your site",
        .tier = .low,
        .narrowing = .records,
        .flags = &read_flags,
        .operations = &.{
            "record.get",
            "record.list",
            "record.referrers",
            "record.shown",
            "record.query",
            "record.reach",
            "project.impact",
            "snapshot.list",
            "snapshot.get",
        },
        .history = &.{ "snapshot.list", "snapshot.get" },
    },
    .{
        .key = "records.write",
        .sentence = "Create and change content",
        .tier = .medium,
        .wide_tier = .high,
        .narrowing = .records,
        .flags = &publish_flag,
        .operations = &.{
            "record.create",
            "record.save",
            "record.delete",
            "record.discard_changes",
            "record.transition",
            "record.decline_request",
            "snapshot.take",
            "snapshot.restore",
            "record.publish",
            "record.transition_many",
        },
        .publishing = &.{ "record.publish", "record.transition_many" },
    },
    .{
        .key = "records.destroy",
        .sentence = "Delete content for good, with its history",
        .tier = .high,
        .narrowing = .records,
        .operations = &.{
            "record.purge",
            "term.purge",
            "snapshot.prune",
        },
    },
    .{
        .key = "project.put",
        .sentence = "Put anything exactly as another copy of your site keeps it, with its ids",
        .tier = .high,
        .operations = &.{"project.put"},
    },
    .{
        .key = "terms.read",
        .sentence = "Read terms, tags, and folders",
        .tier = .low,
        .narrowing = .taxonomies,
        .flags = &read_flags,
        .operations = &.{
            "taxonomy.get",
            "taxonomy.list",
            "term.get",
            "term.list",
            "term.tree",
        },
    },
    .{
        .key = "terms.write",
        .sentence = "Create and change terms",
        .tier = .medium,
        .narrowing = .taxonomies,
        .flags = &publish_flag,
        .operations = &.{
            "term.create",
            "term.save",
            "term.delete",
            "term.discard_changes",
            "term.transition",
            "term.publish",
        },
        .publishing = &.{"term.publish"},
    },
    .{
        .key = "schema.read",
        .sentence = "Read content type definitions",
        .tier = .low,
        .operations = &.{
            "content_type.get",
            "content_type.list",
            "custom_fields.list",
            "custom_fields.get",
            "content_type.validate",
            "record.validate",
            "taxonomy.validate",
            "term.validate",
            "custom_fields.validate",
            "user.validate",
        },
    },
    .{
        .key = "schema.write",
        .sentence = "Change content type definitions",
        .tier = .high,
        .operations = &.{
            "content_type.create",
            "content_type.update",
            "content_type.delete",
            "taxonomy.create",
            "taxonomy.update",
            "taxonomy.delete",
            "custom_fields.create",
            "custom_fields.update",
            "custom_fields.delete",
        },
    },
    .{
        .key = "users.names",
        .sentence = "See the names of people on your site",
        .tier = .low,
        .operations = &.{
            "user.options",
        },
    },
    .{
        .key = "users.read",
        .sentence = "Access user accounts and email addresses",
        .tier = .high,
        .operations = &.{
            "user.list",
            "user.get",
        },
    },
    .{
        .key = "users.write",
        .sentence = "Create and change user accounts",
        .tier = .high,
        .operations = &.{
            "user.create",
            "user.update",
            "user.delete",
        },
    },
    .{
        .key = "site.read",
        .sentence = "Read the site's name, description, and address",
        .tier = .low,
    },
    .{
        .key = "settings.write",
        .sentence = "Change the site's settings",
        .tier = .high,
        .operations = &.{
            "settings.edit",
        },
    },
    .{
        .key = "http.fetch",
        .sentence = "Send requests to the domains it names",
        .tier = .high,
        .narrowing = .domains,
        .operations = &.{ "http.fetch", "http.stream", "http.read" },
    },
    .{
        .key = "media.read",
        .sentence = "See the files in the media library",
        .tier = .low,
        .flags = &private_flag,
        .operations = &.{
            "media.list",
            "media.get",
            "media.file",
            "media.view",
            "media.read",
        },
    },
    .{
        .key = "media.write",
        .sentence = "Put files into the media library",
        .tier = .medium,
        .operations = &.{
            "media.upload",
            "media.add",
            "media.import",
            "media.import_many",
            "media.update",
            "media.move",
            "media.tag",
        },
    },
    .{
        .key = "email.send",
        .sentence = "Send emails",
        .tier = .medium,
    },
    .{
        .key = "ai.progress",
        .sentence = "Show the words a model writes as it writes them",
        .tier = .low,
        .operations = &.{"ai.progress"},
    },
};
