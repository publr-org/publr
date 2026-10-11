//! Talking to language models is `publr_ai`: messages and tools, the provider interface and
//! the description a provider registers with, the JSON both travel as, and the loop that
//! runs a turn. Knows nothing about conversations, devices or plugins.

const publr_ai = @import("publr_ai");

pub const Role = publr_ai.Role;
pub const Part = publr_ai.Part;
pub const Image = publr_ai.Image;
pub const text_bytes_max = publr_ai.text_bytes_max;
pub const valid_text = publr_ai.valid_text;
pub const Message = publr_ai.Message;
pub const Tool = publr_ai.Tool;
pub const Request = publr_ai.Request;
pub const Response = publr_ai.Response;
pub const Usage = publr_ai.Usage;
pub const Stop = publr_ai.Stop;
pub const Provider = publr_ai.Provider;
pub const Description = publr_ai.Description;
pub const Model = publr_ai.Model;
pub const Key = publr_ai.Key;
pub const Error = publr_ai.Error;
pub const Tools = publr_ai.Tools;
pub const Answer = publr_ai.Answer;
pub const Observer = publr_ai.Observer;
pub const Step = publr_ai.Step;
pub const End = publr_ai.End;
pub const Outcome = publr_ai.Outcome;
pub const Scripted = publr_ai.Scripted;
pub const run = publr_ai.run;
pub const request_json = publr_ai.request_json;
pub const request_of = publr_ai.request_of;
pub const response_json = publr_ai.response_json;
pub const response_of = publr_ai.response_of;
