//! A type's default view: the view its list starts at, from its plugin's `.data_view`, the
//! one administrators saved for everyone and the person's own.
const operation = @import("../../operation.zig");

/// A column or a field offered, by its name and what people call it.
pub const Named = struct {
    name: []const u8,
    label: []const u8,
};

/// A way a field may be filtered, and what its value is.
pub const Operator = struct {
    id: []const u8,
    label: []const u8,
    /// What the value is: `text`, `choices`, `yes_no`, `number`, `number_range`, `day`,
    /// `day_range`, `span`, `records`.
    takes: []const u8,
};

/// A field offered to filter by, with its ways.
pub const Filterable = struct {
    name: []const u8,
    label: []const u8,
    operators: []const Operator,
};

const example_query = "{\"types\":[\"post\"],\"type_view\":true,\"clauses\":[]," ++
    "\"order\":\"-updated\",\"columns\":[\"slug\",\"status\",\"updated\"],\"per_page\":20}";

pub const Default = struct {
    pub const name = "view.default";
    pub const description = "Read the view a type's list starts at, and what it may offer";
    pub const details =
        \\`query` is the start, as JSON: the caller's own default if they saved one, else
        \\the one administrators saved for everyone, else the plugin's, else core's (newest
        \\saved first; slug, status and updated shown). `layer` says which. `columns`,
        \\`filterable` and `orderable` are what the view options offer, as the type's plugin
        \\narrows them; each field to filter by comes with its operators.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        type: []const u8,
    };
    pub const Out = struct {
        query: operation.Json,
        layer: []const u8,
        /// Administrators saved a default for everyone.
        everyone: bool,
        /// The field the list's first column shows, always.
        title_field: []const u8,
        columns: []const Named,
        filterable: []const Filterable,
        orderable: []const Named,
    };
    pub const example: In = .{
        .type = "post",
    };
    pub const example_out: Out = .{
        .query = .{
            .text = example_query,
        },
        .layer = "core",
        .everyone = false,
        .title_field = "title",
        .columns = &.{
            .{
                .name = "title",
                .label = "Title",
            },
            .{
                .name = "slug",
                .label = "Slug",
            },
            .{
                .name = "body",
                .label = "Body",
            },
            .{
                .name = "related",
                .label = "Related",
            },
            .{
                .name = "status",
                .label = "Status",
            },
            .{
                .name = "updated",
                .label = "Updated",
            },
            .{
                .name = "created",
                .label = "Created",
            },
        },
        .filterable = &.{
            .{
                .name = "title",
                .label = "Title",
                .operators = &.{
                    .{
                        .id = "is",
                        .label = "is",
                        .takes = "text",
                    },
                    .{
                        .id = "is_not",
                        .label = "is not",
                        .takes = "text",
                    },
                    .{
                        .id = "contains",
                        .label = "contains",
                        .takes = "text",
                    },
                    .{
                        .id = "not_contains",
                        .label = "doesn't contain",
                        .takes = "text",
                    },
                    .{
                        .id = "starts_with",
                        .label = "starts with",
                        .takes = "text",
                    },
                },
            },
            .{
                .name = "slug",
                .label = "Slug",
                .operators = &.{
                    .{
                        .id = "is",
                        .label = "is",
                        .takes = "text",
                    },
                    .{
                        .id = "is_not",
                        .label = "is not",
                        .takes = "text",
                    },
                    .{
                        .id = "contains",
                        .label = "contains",
                        .takes = "text",
                    },
                    .{
                        .id = "not_contains",
                        .label = "doesn't contain",
                        .takes = "text",
                    },
                    .{
                        .id = "starts_with",
                        .label = "starts with",
                        .takes = "text",
                    },
                },
            },
            .{
                .name = "related",
                .label = "Related",
                .operators = &.{
                    .{
                        .id = "any_of",
                        .label = "is any of",
                        .takes = "records",
                    },
                    .{
                        .id = "none_of",
                        .label = "is none of",
                        .takes = "records",
                    },
                    .{
                        .id = "all_of",
                        .label = "is all of",
                        .takes = "records",
                    },
                },
            },
        },
        .orderable = &.{
            .{
                .name = "title",
                .label = "Title",
            },
            .{
                .name = "created",
                .label = "Created",
            },
            .{
                .name = "updated",
                .label = "Updated",
            },
            .{
                .name = "status",
                .label = "Status",
            },
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .type = "The content type, by handle",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .query = "The view the list starts at, as JSON",
        .layer = "Where it came from: `mine`, `everyone`, `plugin` or `core`",
        .everyone = "Whether administrators saved a default for everyone",
        .title_field = "The field the first column shows: the record's title",
        .columns = "Every column the list can show, the first 200",
        .filterable = "The fields offered to filter by, each with its operators, the first 200",
        .orderable = "What the list can be ordered by, the first 200",
    };
};

pub const SaveDefault = struct {
    pub const name = "view.save_default";
    pub const description = "Save the view a type's list starts at, for the caller or everyone";
    pub const details =
        \\`query` is the view as JSON (as `view create` takes it); its types become the type's
        \\own view. Saved for the caller, it wins over everyone's; `for_everyone` saves the
        \\one everyone starts at who saved none: administrators only.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        query: operation.Json,
        for_everyone: bool = false,
    };
    pub const Out = struct {
        saved: bool,
    };
    pub const example: In = .{
        .type = "post",
        .query = .{
            .text = "{\"order\":\"title\",\"per_page\":50}",
        },
    };
    pub const example_out: Out = .{
        .saved = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .type = "The content type, by handle",
        .query = "The view, as JSON",
        .for_everyone = "Everyone's default (administrators only)",
    };
};

pub const ResetDefault = struct {
    pub const name = "view.reset_default";
    pub const description = "Forget a saved default view: the caller's, or everyone's";
    pub const details =
        \\The caller's list starts at everyone's default again, or the plugin's. With
        \\`for_everyone` (administrators only), everyone's goes and the plugin's view is the
        \\start for those who saved none.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        for_everyone: bool = false,
    };
    pub const Out = struct {
        reset: bool,
    };
    pub const example: In = .{
        .type = "post",
    };
    // Nothing saved yet: nothing to forget.
    pub const example_out: Out = .{
        .reset = false,
    };
    pub const field_docs: operation.Docs(In) = .{
        .type = "The content type, by handle",
        .for_everyone = "Everyone's default (administrators only)",
    };
};
