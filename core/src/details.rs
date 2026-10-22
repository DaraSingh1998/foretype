//! The user's own details (name, email, phone, …), entered in the shell's settings and kept
//! there encrypted. The core uses them two ways:
//!
//! - **Fill**: when the text before the caret clearly asks for a detail ("My email is ",
//!   "Phone: ", a sign-off line such as "Regards,\n"), the exact value is offered without the
//!   model, as long as it matches what the user has started typing.
//! - **Writer line**: optionally, one header line tells the model who is writing (name, job
//!   title, company), so continuations use the right name.
//!
//! Values never appear in logs: `Debug` prints only which fields are set.

use serde::Deserialize;

use crate::words;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Field {
    Name,
    Email,
    Phone,
    Company,
    JobTitle,
    Address,
    Website,
}

impl Field {
    pub const ALL: [Field; 7] =
        [Field::Name, Field::Email, Field::Phone, Field::Company, Field::JobTitle, Field::Address, Field::Website];

    /// The JSON key, also sent as the suggestion's `label`.
    pub fn key(self) -> &'static str {
        match self {
            Field::Name => "name",
            Field::Email => "email",
            Field::Phone => "phone",
            Field::Company => "company",
            Field::JobTitle => "job_title",
            Field::Address => "address",
            Field::Website => "website",
        }
    }

    /// Accepted whole with one Tab: an email, a phone number or an address is one unit. A
    /// name goes word by word like any suggestion, so Tab can take just the first name.
    pub fn whole(self) -> bool {
        self != Field::Name
    }
}

/// Sent by the shell through `ft_engine_set_details`. Fields the user switched off arrive
/// empty; all empty means the feature is off.
#[derive(Clone, Default, Deserialize)]
#[serde(default)]
pub struct UserDetails {
    pub name: String,
    pub email: String,
    pub phone: String,
    pub company: String,
    pub job_title: String,
    pub address: String,
    pub website: String,
    /// Add the writer line (name, job title, company) to the prompt header.
    pub in_prompt: bool,
}

impl std::fmt::Debug for UserDetails {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let set: Vec<&str> = Field::ALL.iter().filter(|x| !self.get(**x).is_empty()).map(|x| x.key()).collect();
        write!(f, "UserDetails {{ set: {set:?}, in_prompt: {} }}", self.in_prompt)
    }
}

/// Longest value the fill offers (a long address); longer ones are ignored.
pub const MAX_VALUE_CHARS: usize = 300;

impl UserDetails {
    /// The value for `field`, trimmed, on one line; empty when unset or too long.
    pub fn get(&self, field: Field) -> &str {
        let v = match field {
            Field::Name => &self.name,
            Field::Email => &self.email,
            Field::Phone => &self.phone,
            Field::Company => &self.company,
            Field::JobTitle => &self.job_title,
            Field::Address => &self.address,
            Field::Website => &self.website,
        }
        .trim();
        if v.contains('\n') || v.chars().count() > MAX_VALUE_CHARS {
            ""
        } else {
            v
        }
    }

    pub fn is_empty(&self) -> bool {
        Field::ALL.iter().all(|f| self.get(*f).is_empty())
    }

    /// "Priya Raman (Product Manager, Northwind)" for the prompt header, or empty without a
    /// name. Brackets are replaced so a value can't close the header's own markers.
    pub fn writer(&self) -> String {
        let clean = |s: &str| s.replace('[', "(").replace(']', ")");
        let name = clean(self.get(Field::Name));
        if name.is_empty() {
            return String::new();
        }
        let extra: Vec<String> =
            [Field::JobTitle, Field::Company].iter().map(|f| clean(self.get(*f))).filter(|s| !s.is_empty()).collect();
        if extra.is_empty() {
            name
        } else {
            format!("{name} ({})", extra.join(", "))
        }
    }
}

impl UserDetails {
    /// Pieces of the set values that debug logs must not show: every run of 4 or more
    /// letters or digits ("priya", "raman", "98765"), lowercased.
    fn secrets(&self) -> Vec<String> {
        let mut out: Vec<String> = Field::ALL
            .iter()
            .flat_map(|f| self.get(*f).split(|c: char| !c.is_alphanumeric()))
            .filter(|p| p.chars().count() >= 4)
            .map(str::to_ascii_lowercase)
            .collect();
        out.sort_by_key(|p| std::cmp::Reverse(p.len()));
        out.dedup();
        out
    }

    /// `text` for a debug log, with every piece of the user's details masked: a model
    /// suggestion can echo a detail it read in the document ("or priya.raman").
    pub fn redact(&self, text: &str) -> String {
        let mut out = text.to_string();
        for s in self.secrets() {
            // ASCII lowercasing keeps byte offsets; "***" can't start a new match.
            while let Some(i) = out.to_ascii_lowercase().find(&s) {
                out.replace_range(i..i + s.len(), "***");
            }
        }
        out
    }
}

/// A detail to offer at the caret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fill {
    pub field: Field,
    /// Text just before the caret to delete first: the typed start of the value when its
    /// case differs ("pri" for "Priya"). Empty for a plain continuation.
    pub replace: String,
    /// What to insert: the rest of the value, or all of it after `replace` is deleted. Starts
    /// with a space when the cue has none after it yet ("My email is").
    pub text: String,
}

/// Where a cue may stand.
#[derive(Clone, Copy, PartialEq, Eq)]
enum At {
    /// After a word boundary anywhere on the line ("…, my email is").
    Word,
    /// At the start of the line, after optional indentation or a list bullet ("Email:").
    LineStart,
    /// After a greeting on the same line ("Hi Priya, this is").
    AfterGreeting,
}

struct Cue {
    /// Lowercase, ASCII apostrophes; matched case-insensitively and with ’ for '.
    text: &'static str,
    at: At,
    /// Tried in order: the first whose value matches what was typed wins.
    fields: &'static [Field],
}

const NAME: &[Field] = &[Field::Name];
const EMAIL: &[Field] = &[Field::Email];
const PHONE: &[Field] = &[Field::Phone];
const EMAIL_PHONE: &[Field] = &[Field::Email, Field::Phone];
const PHONE_EMAIL: &[Field] = &[Field::Phone, Field::Email];
const COMPANY: &[Field] = &[Field::Company];
const JOB: &[Field] = &[Field::JobTitle];
const ADDRESS: &[Field] = &[Field::Address];
const WEBSITE: &[Field] = &[Field::Website];

macro_rules! cues {
    ($($at:ident $fields:ident [$($text:literal),* $(,)?])*) => {
        &[$($(Cue { text: $text, at: At::$at, fields: $fields },)*)*]
    };
}

/// Phrases that ask for a detail. Each must end where the value starts; a cue matches only
/// at a word boundary and only when nothing but spaces and the typed start of the value
/// follow it. Ambiguous ones ("I'm ", "it's", "this is " without a greeting, "Title:",
/// "Role:") are left out: a wrong fill is worse than none, and the model still suggests
/// there.
const CUES: &[Cue] = cues! {
    Word NAME ["my name is", "my name's", "my full name is", "hi, i'm", "hi i'm", "hello, i'm", "hello i'm",
               "hey, i'm", "hey i'm", "hi, i am", "hello, i am", "i'm called"]
    AfterGreeting NAME ["this is"]
    LineStart NAME ["name:", "full name:", "your name:", "my name:"]
    Word EMAIL ["my email is", "my email address is", "my e-mail is", "my e-mail address is", "my email id is",
                "my mail id is", "my mail is", "email me at", "e-mail me at", "mail me at", "email me on",
                "write to me at", "my email:"]
    Word EMAIL_PHONE ["reach me at", "contact me at", "get in touch at", "get hold of me at"]
    Word PHONE_EMAIL ["reach me on", "contact me on"]
    LineStart EMAIL ["email:", "e-mail:", "email address:", "e-mail address:", "email id:", "mail id:", "mail:"]
    Word PHONE ["my phone number is", "my phone no is", "my phone no. is", "my number is", "my phone is", "my mobile is",
                "my mobile number is", "my mobile no is", "my mobile no. is", "my cell is", "my cell number is",
                "my cell phone is", "my contact number is", "my contact no is", "my whatsapp is",
                "my whatsapp number is", "call me on", "call me at", "text me on", "text me at", "ring me on",
                "ring me at", "phone me on", "phone me at", "whatsapp me on", "whatsapp me at", "message me on",
                "my phone:", "my number:"]
    LineStart PHONE ["phone:", "phone number:", "phone no:", "phone no.:", "mobile:", "mobile number:", "mobile no:",
                     "mobile no.:", "mob:", "tel:", "telephone:", "cell:", "cell phone:", "contact number:",
                     "contact no:", "contact no.:", "whatsapp:", "ph:"]
    LineStart PHONE_EMAIL ["contact:"]
    Word COMPANY ["i work at", "i work for", "i'm working at", "i am working at", "i'm working for",
                  "i am working for", "my company is", "my company's name is", "my employer is", "i'm employed at",
                  "i am employed at", "i'm employed by", "i am employed by"]
    LineStart COMPANY ["company:", "company name:", "organization:", "organisation:", "employer:", "firm:"]
    Word JOB ["i work as", "i'm working as", "i am working as", "my role is", "my title is", "my job title is",
              "my designation is", "my position is", "my job is"]
    LineStart JOB ["job title:", "designation:"]
    Word ADDRESS ["my address is", "my home address is", "my postal address is", "my mailing address is",
                  "my shipping address is", "my delivery address is", "my office address is", "i live at",
                  "my address:"]
    LineStart ADDRESS ["address:", "home address:", "postal address:", "mailing address:", "shipping address:",
                       "delivery address:", "billing address:", "office address:"]
    Word WEBSITE ["my website is", "my site is", "my web site is", "my portfolio is", "my homepage is",
                  "my home page is", "my website:"]
    LineStart WEBSITE ["website:", "web site:", "web:", "portfolio:", "homepage:", "home page:"]
};

/// A sign-off on a line of its own; the name goes on the next line.
const SIGN_OFFS: &[&str] = &[
    "regards", "best regards", "kind regards", "kindest regards", "warm regards", "warmest regards", "with regards",
    "with best regards", "with kind regards", "best", "all the best", "best wishes", "warm wishes",
    "with best wishes", "thanks", "thank you", "thanks again", "many thanks", "thanks so much", "thank you so much",
    "thanks and regards", "thanks & regards", "thanks and best regards", "with thanks", "with gratitude",
    "gratefully", "cheers", "sincerely", "yours sincerely", "sincerely yours", "yours faithfully", "faithfully",
    "yours truly", "truly", "respectfully", "yours respectfully", "warmly", "take care", "talk soon",
    "speak soon", "see you soon", "yours", "--",
];

const GREETINGS: &[&str] = &["hi", "hello", "hey", "dear", "good morning", "good afternoon", "good evening", "greetings"];

/// Most of a line searched for a cue, from the caret back.
const WINDOW_CHARS: usize = MAX_VALUE_CHARS + 60;

fn norm(c: char) -> char {
    match c {
        '\u{2019}' | '\u{2018}' | '\u{02BC}' => '\'',
        '\u{00A0}' | '\u{202F}' => ' ',
        '\u{FF1A}' => ':',
        c => c.to_ascii_lowercase(),
    }
}

/// The detail the text before the caret asks for, if one is set and matches what the user
/// has typed after the cue so far. `None` when nothing clearly asks for a detail.
pub fn fill(text_before: &str, details: &UserDetails) -> Option<Fill> {
    if details.is_empty() {
        return None;
    }
    let line_start = text_before.rfind('\n').map_or(0, |i| i + 1);
    let line = &text_before[line_start..];
    if line_start > 0 {
        if let Some(f) = sign_off(&text_before[..line_start - 1], line, details) {
            return Some(f);
        }
    }
    cue_fill(line, details)
}

/// "Regards,\n" (or "--\n") on the line before: the name, with the current line as its
/// typed start.
fn sign_off(before: &str, line: &str, details: &UserDetails) -> Option<Fill> {
    let prev = before.rsplit('\n').next().unwrap_or("").trim();
    let prev: String = prev.trim_end_matches([',', '!']).trim_end().chars().map(norm).collect();
    if !SIGN_OFFS.contains(&prev.as_str()) || line.starts_with(char::is_whitespace) {
        return None;
    }
    offer(Field::Name, details.get(Field::Name), line, "")
}

/// A cue phrase on the current line, nearest the caret.
fn cue_fill(line: &str, details: &UserDetails) -> Option<Fill> {
    // The line's last WINDOW_CHARS characters, normalized, with their byte offsets.
    let skip = line.chars().count().saturating_sub(WINDOW_CHARS);
    let chars: Vec<(usize, char)> = line.char_indices().skip(skip).map(|(i, c)| (i, norm(c))).collect();
    let mut best: Option<(usize, usize, &Cue)> = None; // (start, cue length, cue)
    for cue in CUES {
        let pat: Vec<char> = cue.text.chars().collect();
        if pat.len() > chars.len() {
            continue;
        }
        for start in (0..=chars.len() - pat.len()).rev() {
            if !chars[start..start + pat.len()].iter().map(|(_, c)| *c).eq(pat.iter().copied()) {
                continue;
            }
            let end = start + pat.len();
            // The cue starts a word and ends one: what follows is nothing or a space.
            if start > 0 && words::is_word_char(chars[start - 1].1) {
                continue;
            }
            if end < chars.len() && chars[end].1 != ' ' {
                continue;
            }
            let at = chars[start].0;
            if !placed(cue.at, &line[..at]) {
                continue;
            }
            if best.is_none_or(|(s, n, _)| start > s || (start == s && pat.len() > n)) {
                best = Some((start, pat.len(), cue));
            }
            break;
        }
    }
    let (start, n, cue) = best?;
    let end = chars.get(start + n).map_or(line.len(), |(i, _)| *i);
    let rest = &line[end..];
    let (typed, lead) = if rest.is_empty() { ("", " ") } else { (rest.trim_start_matches([' ', '\u{A0}', '\u{202F}']), "") };
    cue.fields.iter().find_map(|f| offer(*f, details.get(*f), typed, lead))
}

/// Whether a cue may stand after `before` (the line up to the cue).
fn placed(at: At, before: &str) -> bool {
    match at {
        At::Word => true,
        At::LineStart => {
            let b = before.trim_start();
            b.is_empty() || ["-", "*", "\u{2022}", "\u{2013}"].iter().any(|bullet| b.trim_end() == *bullet)
        }
        At::AfterGreeting => {
            let b: String = before.trim().chars().map(norm).collect();
            b.ends_with(',') && GREETINGS.iter().any(|g| b.strip_prefix(g).is_some_and(|r| r.starts_with([' ', ','])))
        }
    }
}

/// The fill for `value` when `typed` is its start: the rest as a continuation when the case
/// agrees, the whole value replacing `typed` when it doesn't. Nothing when the value is
/// unset, doesn't match, or is already typed in full.
fn offer(field: Field, value: &str, typed: &str, lead: &str) -> Option<Fill> {
    if value.is_empty() || typed.chars().count() >= value.chars().count() {
        return None;
    }
    if let Some(rest) = value.strip_prefix(typed) {
        return Some(Fill { field, replace: String::new(), text: format!("{lead}{rest}") });
    }
    let n = typed.chars().count();
    let same = value.chars().take(n).flat_map(char::to_lowercase).eq(typed.chars().flat_map(char::to_lowercase));
    same.then(|| Fill { field, replace: typed.to_string(), text: value.to_string() })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn me() -> UserDetails {
        UserDetails {
            name: "Priya Raman".into(),
            email: "priya.raman@example.com".into(),
            phone: "+91 98765 43210".into(),
            company: "Northwind Labs".into(),
            job_title: "Product Manager".into(),
            address: "12 Lake Road, Pune 411001".into(),
            website: "https://priya.example.com".into(),
            in_prompt: false,
        }
    }

    /// (field key, replace, text) for compact assertions.
    fn f(text: &str) -> Option<(&'static str, String, String)> {
        fill(text, &me()).map(|f| (f.field.key(), f.replace, f.text))
    }

    fn cont(field: &'static str, text: &str) -> Option<(&'static str, String, String)> {
        Some((field, String::new(), text.into()))
    }

    #[test]
    fn phrases_ask_for_a_detail() {
        assert_eq!(f("Sure, my email is "), cont("email", "priya.raman@example.com"));
        assert_eq!(f("My email is pri"), cont("email", "ya.raman@example.com"));
        assert_eq!(f("Hi Sam,\nMy Email Is "), cont("email", "priya.raman@example.com"));
        assert_eq!(f("You can call me on "), cont("phone", "+91 98765 43210"));
        assert_eq!(f("my phone number is +91 9"), cont("phone", "8765 43210"));
        assert_eq!(f("Hello, I\u{2019}m "), cont("name", "Priya Raman"));
        assert_eq!(f("Hi Sam, this is "), cont("name", "Priya Raman"));
        assert_eq!(f("I work at "), cont("company", "Northwind Labs"));
        assert_eq!(f("and I work as a"), None, "the job title doesn't start with \"a\"");
        assert_eq!(f("I work as "), cont("job_title", "Product Manager"));
        assert_eq!(f("My address is "), cont("address", "12 Lake Road, Pune 411001"));
        assert_eq!(f("Portfolio: https://pr"), cont("website", "iya.example.com"));
    }

    #[test]
    fn no_space_yet_offers_one() {
        assert_eq!(f("My email is"), cont("email", " priya.raman@example.com"));
        assert_eq!(f("Email:"), cont("email", " priya.raman@example.com"));
    }

    #[test]
    fn labels_at_line_start() {
        assert_eq!(f("Contact details\nEmail: "), cont("email", "priya.raman@example.com"));
        assert_eq!(f("  - Phone: +91"), cont("phone", " 98765 43210"));
        assert_eq!(f("Contact: pri"), cont("email", "ya.raman@example.com"), "phone first, but the email matches");
        assert_eq!(f("Contact: "), cont("phone", "+91 98765 43210"));
        assert_eq!(f("Send me an email: "), None, "a label mid-sentence");
        assert_eq!(f("Name:\u{A0}"), cont("name", "Priya Raman"));
    }

    #[test]
    fn reach_me_at_picks_the_matching_detail() {
        assert_eq!(f("Reach me at "), cont("email", "priya.raman@example.com"));
        assert_eq!(f("Reach me at +9"), cont("phone", "1 98765 43210"));
        assert_eq!(f("reach me on "), cont("phone", "+91 98765 43210"));
    }

    #[test]
    fn sign_offs_offer_the_name() {
        assert_eq!(f("See you then.\n\nRegards,\n"), cont("name", "Priya Raman"));
        assert_eq!(f("Thanks!\nPri"), cont("name", "ya Raman"));
        assert_eq!(f("Best regards,\nPriya"), cont("name", " Raman"));
        assert_eq!(f("Kind Regards\n"), cont("name", "Priya Raman"));
        assert_eq!(f("--\n"), cont("name", "Priya Raman"));
        assert_eq!(f("Cheers,\nSam"), None, "someone else signs");
        assert_eq!(f("Thanks for the notes,\n"), None, "not a sign-off line");
        assert_eq!(f("Regards, "), None, "the name goes on the next line");
        assert_eq!(f("Regards,\nPriya Raman"), None, "already typed in full");
        assert_eq!(f("Regards,\n\n"), None, "a blank line after it");
    }

    #[test]
    fn case_mismatch_replaces_the_typed_start() {
        assert_eq!(f("my name is priya"), Some(("name", "priya".into(), "Priya Raman".into())));
        assert_eq!(f("Regards,\nPRI"), Some(("name", "PRI".into(), "Priya Raman".into())));
    }

    #[test]
    fn nothing_to_fill() {
        assert_eq!(f("My email is x"), None, "typed something else");
        assert_eq!(f("My email is priya.raman@example.com"), None, "complete");
        assert_eq!(f("My email is priya.raman@example.com and"), None, "moved on");
        assert_eq!(f("The army name is "), None, "not at a word boundary");
        assert_eq!(f("my email is\n"), None, "the cue was on the previous line");
        assert_eq!(f("my emailing list is "), None);
        assert_eq!(f("my email isn"), None, "the cue word goes on");
        assert_eq!(f("I'm "), None, "too common to mean a name");
        assert_eq!(f("This is "), None, "no greeting before it");
        assert_eq!(f("Title: "), None, "ambiguous label");
        assert_eq!(f(""), None);
        let mut d = me();
        d.email.clear();
        assert_eq!(fill("My email is ", &d), None, "not set (or switched off)");
        assert_eq!(fill("Regards,\n", &UserDetails::default()), None, "no details");
        d.address = "line one\nline two".into();
        assert_eq!(fill("My address is ", &d), None, "multi-line values are not offered");
    }

    #[test]
    fn nearest_cue_wins() {
        assert_eq!(
            f("My email is priya.raman@example.com and my number is "),
            cont("phone", "+91 98765 43210")
        );
        assert_eq!(f("My number is +91 98765 43210, my email is p"), cont("email", "riya.raman@example.com"));
    }

    #[test]
    fn writer_line_and_redacted_debug() {
        let d = me();
        assert_eq!(d.writer(), "Priya Raman (Product Manager, Northwind Labs)");
        assert_eq!(UserDetails { name: "Sam [QA]".into(), ..Default::default() }.writer(), "Sam (QA)");
        assert_eq!(UserDetails { company: "Acme".into(), ..Default::default() }.writer(), "");
        let dbg = format!("{d:?}");
        assert!(!dbg.contains("Priya") && !dbg.contains("example.com") && dbg.contains("\"email\""), "{dbg}");
        assert_eq!(d.redact(" or Priya.RAMAN at +91 98765 43210, see you"), " or ***.*** at +91 *** ***, see you");
        assert_eq!(UserDetails::default().redact("Priya"), "Priya");
    }
}
