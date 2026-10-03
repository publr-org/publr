//! GROQ as Publr reads it: `publr_groq`, the language; what a query reads comes from the
//! dataset `operations/record/query_dataset.zig` gives it.

const groq = @import("publr_groq");

pub const execute = groq.execute;
pub const Error = groq.Error;
pub const Problem = groq.Problem;
pub const Value = groq.Value;
pub const Dataset = groq.Dataset;
pub const DatasetError = groq.DatasetError;
pub const Hint = groq.Hint;
pub const Found = groq.Found;
pub const values = groq.values;
pub const evaluation = groq.evaluation;
pub const datetimes = groq.datetimes;
