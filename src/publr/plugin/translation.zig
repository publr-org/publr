//! The words a plugin brings in other languages: PO files, and what a language pack says of
//! its grammar.

/// A PO file a plugin brings: the admin's words in one language. A language pack is a
/// plugin of these alone; a plugin may bring its own words too.
pub const Translation = struct {
    /// `pl`, `pt-br`.
    locale: []const u8,
    /// The language in its own words: `Polski`.
    label: []const u8,
    /// The PO file, `@embedFile("i18n/pl.po")`.
    po: []const u8,
    /// Whose words it translates: `publr` for the core's, a plugin's name for that plugin's;
    /// empty for the declaring plugin's own. A plugin of translations alone may fill or fix
    /// any domain.
    domain: []const u8 = "",
    /// Publr's own translation of the core (`domain = "publr"`): it wins over any other.
    /// A plugin translating its own words wins for them without saying so.
    official: bool = false,
    /// What a language pack says of its grammar: the cases and genders a type's name is
    /// given in, for messages that decline it (`{type:accusative}`, `{type.gender, select,
    /// …}`). Empty for a language that does not decline nouns, or a plugin's own words.
    grammar: Grammar = .{},
};

pub const Grammar = struct {
    /// Each by key (`genitive`) and as people know it (`Dopełniacz (kogo? czego?)`); the
    /// first is the name itself.
    cases: []const Word = &.{},
    genders: []const Word = &.{},
};

pub const Word = struct {
    key: []const u8,
    label: []const u8,
};
