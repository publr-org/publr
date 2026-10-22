const publr = @import("publr");

/// Sample review
///
/// A note that goes through review before it shows: a flow of the type's own.
pub const Review = struct {
    /// Text
    text: []const u8,
};

pub const Status = enum {
    draft,
    /// Waiting for review
    in_review,
    published,
};

/// A review says something of its own: not the word "spam".
fn not_spam(review: Review, problems: *publr.Problems(Review)) void {
    if (publr.text.equals(review.text, "spam")) {
        problems.add(.text, "A review says something of its own.");
    }
}

const flow = [_]publr.record.Transition(Status){
    .{
        .name = .submit,
        .from = &.{.draft},
        .to = .in_review,
        .label = "Submit for review",
    },
    .{
        .name = .approve,
        .from = &.{.in_review},
        .to = .published,
        .label = "Approve",
        .authorize = publr.authorize.user_has_role(&.{"editor"}),
    },
};

pub const record = publr.record.define(Review, .{
    .name = "sampler.sample_review",
    .validate = not_spam,
    .status = .{
        .list = Status,
        .start = .draft,
        .flow = &flow,
    },
});
