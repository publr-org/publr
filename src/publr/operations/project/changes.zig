//! The keys of the dependency index that every listing records, raised when a change cannot
//! be pinned to one type: what a plugin keeping copies of a project in sync raises too.

/// The key every listing render records, raised when a change cannot be pinned to a type.
pub const all_records_key = "records";
/// The same for terms: every term listing reads it, a term gone for good raises it.
pub const all_terms_key = "terms";
