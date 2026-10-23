//! Builds the prompt for a base model used as a plain text continuer.
//!
//! The prompt is a byte-stable header (text from other apps' windows, text visible around
//! the field, app, window, the user's instructions) followed by the text before the caret. Everything that can change per keystroke sits at
//! the very end, so successive prompts share the longest possible token prefix and the
//! engine only prefills a token or two per keystroke.

use crate::words;

pub struct ContextInput<'a> {
    /// The other-apps section, rendered (`others::OtherApps::select`): `[Also open: …]`
    /// blocks ending in a blank line, or empty.
    pub other_apps: &'a str,
    pub app_name: &'a str,
    pub window_title: &'a str,
    pub url: &'a str,
    pub instructions: &'a str,
    /// Who is writing ("Priya Raman (Product Manager, Northwind)"), from the user's own
    /// details when they allow it; empty otherwise.
    pub writer: &'a str,
    /// On-screen text near the field (OCR of the focused window), refreshed by the shell
    /// only on focus changes and typing pauses so the header stays stable while typing.
    pub screen_context: &'a str,
    /// Short snippets of the user's earlier writing in this app (personalization).
    pub examples: &'a [String],
    pub text_before: &'a str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Prompt {
    /// Header plus committed text: what goes into the KV cache.
    pub prefix: String,
    /// Partial word (with its leading space) that generation must start with.
    pub fragment: String,
    /// Rest of the caret's line when completing mid-line (the suggestion is cut where it
    /// starts repeating it); empty at the end of a line.
    pub suffix: String,
    /// Bytes at the start of `prefix` that are the other-apps section: the part dropped
    /// first when a prompt doesn't fit the context.
    pub others: usize,
    /// Where the screen-text section ends (`others` when there is none) and where the whole
    /// header ends: `prefix[header..]` is the text being written.
    pub screen: usize,
    pub header: usize,
}

impl Prompt {
    /// A prompt with no header (tests, servers).
    pub fn plain(prefix: &str, fragment: &str) -> Self {
        Prompt { prefix: prefix.into(), fragment: fragment.into(), suffix: String::new(), others: 0, screen: 0, header: 0 }
    }

    /// The same prompt without its other-apps section.
    pub fn without_others(&self) -> Option<Prompt> {
        let n = self.others;
        (n > 0).then(|| Prompt { prefix: self.prefix[n..].to_string(), others: 0, screen: self.screen - n, header: self.header - n, ..self.clone() })
    }

    /// The other-apps section.
    pub fn others_section(&self) -> &str {
        &self.prefix[..self.others]
    }

    /// The header after the screen text: the place, examples, writer and notes lines.
    fn local(&self) -> &str {
        &self.prefix[self.screen..self.header]
    }

    /// This prompt with `header`'s header in place of its own (the text being written kept).
    pub fn with_header_of(&self, other: &Prompt) -> Prompt {
        Prompt {
            prefix: format!("{}{}", &other.prefix[..other.header], &self.prefix[self.header..]),
            others: other.others,
            screen: other.screen,
            header: other.header,
            ..self.clone()
        }
    }
}

/// The prompt to serve while `target`'s new header is prefilled in the background (D47):
/// `target` with the header of `live` (the prompt the serving slot holds) wherever the two
/// differ only in text read from screens. In the same field (`same_field`, and the place,
/// examples and notes lines equal): `live`'s whole header, other-apps section and screen
/// text. In another field: `live`'s other-apps section only (the pool is the same for every
/// field), with `target`'s own screen text and lines. None when that is `target` itself.
pub fn with_old_header(live: &Prompt, target: &Prompt, same_field: bool) -> Option<Prompt> {
    let p = if same_field && live.local() == target.local() {
        target.with_header_of(live)
    } else {
        let shift = |n: usize| n - target.others + live.others;
        Prompt {
            prefix: format!("{}{}", live.others_section(), &target.prefix[target.others..]),
            others: live.others,
            screen: shift(target.screen),
            header: shift(target.header),
            ..target.clone()
        }
    };
    (p.prefix != target.prefix).then_some(p)
}

/// Quantum by which the front of a long text window moves, so the prompt start stays fixed
/// for many keystrokes instead of sliding (and invalidating the cache) on every one.
const WINDOW_STEP: usize = 512;

/// Most screen text the header carries; the part nearest the end (closest to the field in
/// chat-like layouts, as the shell orders it) is kept.
const MAX_SCREEN_CHARS: usize = 1500;

/// Cleans OCR text for the prompt: trims lines, drops empty ones and bracket lines that
/// could be mistaken for the header's own markers, and keeps the last `MAX_SCREEN_CHARS`.
fn screen_section(raw: &str) -> String {
    let lines: Vec<&str> = raw
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('['))
        .collect();
    let mut kept: Vec<&str> = Vec::new();
    let mut total = 0;
    for line in lines.iter().rev() {
        let n = line.chars().count() + 1;
        if total + n > MAX_SCREEN_CHARS {
            break;
        }
        total += n;
        kept.push(line);
    }
    kept.reverse();
    kept.join("\n")
}

/// The header without the other-apps section.
pub(crate) fn header(input: &ContextInput) -> String {
    header_parts(input).0
}

/// The header without the other-apps section, and the length of its screen-text part (at
/// its start).
fn header_parts(input: &ContextInput) -> (String, usize) {
    let mut place = input.app_name.trim().to_string();
    let title = truncate_chars(input.window_title.trim(), 80);
    if !title.is_empty() && title != place {
        place = if place.is_empty() { title.to_string() } else { format!("{place} \u{2014} {title}") };
    }
    let host = url_host(input.url);
    if !host.is_empty() {
        place = format!("{place} ({host})");
    }
    let mut h = String::new();
    let screen = screen_section(input.screen_context);
    if !screen.is_empty() {
        h.push_str("[Text visible on screen]\n");
        h.push_str(&screen);
        h.push_str("\n[End of screen text]\n\n");
    }
    let screen_len = h.len();
    let examples: Vec<String> = input
        .examples
        .iter()
        .map(|e| e.trim().replace('[', "(").replace(']', ")"))
        .filter(|e| !e.is_empty())
        .collect();
    if !examples.is_empty() {
        let app = input.app_name.trim();
        h.push_str(&format!("[Earlier writing by the same person{}]\n", if app.is_empty() { String::new() } else { format!(" in {app}") }));
        h.push_str(&examples.join("\n---\n"));
        h.push_str("\n[End of earlier writing]\n\n");
    }
    let writer = truncate_chars(input.writer.trim(), 160);
    if !writer.is_empty() {
        h.push_str(&format!("[Written by {writer}]\n"));
    }
    if !place.is_empty() {
        h.push_str(&format!("[Written in {place}]\n"));
    }
    let notes = truncate_chars(input.instructions.trim(), 400);
    if !notes.is_empty() {
        h.push_str(&format!("[Writer's notes: {notes}]\n"));
    }
    if !h.is_empty() {
        h.push('\n');
    }
    (h, screen_len)
}

/// Start index of the body window inside `text`. It only moves in `WINDOW_STEP` jumps and
/// lands just after whitespace, so the window boundary is stable while the user types.
fn window_start(text: &str, max_chars: usize) -> usize {
    if text.len() <= max_chars {
        return 0;
    }
    let over = text.len() - max_chars;
    let mut start = over.div_ceil(WINDOW_STEP) * WINDOW_STEP;
    start = start.min(text.len());
    while !text.is_char_boundary(start) {
        start += 1;
    }
    match text[start..].find(char::is_whitespace) {
        Some(off) => {
            let mut s = start + off;
            s += text[s..].chars().next().map_or(0, char::len_utf8);
            s
        }
        None => start,
    }
}

/// The body window: the end of `text_before` the prompt carries (see `window_start`).
pub fn body_window(text_before: &str, max_body_chars: usize) -> &str {
    &text_before[window_start(text_before, max_body_chars)..]
}

pub fn build(input: &ContextInput, max_body_chars: usize) -> Prompt {
    let body = body_window(input.text_before, max_body_chars);
    let (committed, fragment) = words::split_fragment(body);
    // The other-apps section heads the prompt (it changes least while typing in one field
    // and survives moving to another); it arrives cleaned and ends in a blank line.
    let others = input.other_apps;
    let (header, screen) = header_parts(input);
    Prompt {
        prefix: format!("{others}{header}{committed}"),
        fragment: fragment.to_string(),
        suffix: String::new(),
        others: others.len(),
        screen: others.len() + screen,
        header: others.len() + header.len(),
    }
}

/// The words in the prompt's own header markers. A suggestion that starts one ("[End of
/// screen t", "[Also open: Wo") is the model echoing the prompt's layout.
const MARKERS: &[&str] = &["Also open:", "Text visible on screen", "End of screen text", "End of earlier writing", "Earlier writing by", "Written in", "Written by", "Writer's notes"];

/// Cuts a suggestion where it starts echoing a header marker: a "[" followed by at least
/// three characters of a marker (or a whole marker and more). Trailing spaces before the
/// cut go too.
pub fn strip_marker_echo(text: &str) -> &str {
    for (i, _) in text.match_indices('[') {
        let after = &text[i + 1..];
        let n = after.chars().count();
        let echo = MARKERS.iter().any(|m| {
            if after.starts_with(m) {
                return true;
            }
            n >= 3 && m.starts_with(after.trim_end_matches(|c: char| c == '\n'))
        });
        if echo {
            return text[..i].trim_end_matches(' ');
        }
    }
    text
}

fn truncate_chars(s: &str, n: usize) -> &str {
    match s.char_indices().nth(n) {
        Some((i, _)) => &s[..i],
        None => s,
    }
}

fn url_host(url: &str) -> &str {
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    rest.split(['/', '?', '#']).next().unwrap_or("")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input<'a>(text: &'a str) -> ContextInput<'a> {
        ContextInput {
            other_apps: "",
            app_name: "Mail",
            window_title: "Re: planning",
            url: "",
            instructions: "",
            writer: "",
            screen_context: "",
            examples: &[],
            text_before: text,
        }
    }

    #[test]
    fn header_and_fragment() {
        let p = build(&input("Hi Priya,\n\nThanks for the no"), 2000);
        assert_eq!(p.prefix, "[Written in Mail \u{2014} Re: planning]\n\nHi Priya,\n\nThanks for the");
        assert_eq!(p.fragment, " no");
    }

    #[test]
    fn url_host_only() {
        let mut i = input("Hello wor");
        i.app_name = "Safari";
        i.window_title = "Inbox";
        i.url = "https://mail.example.com/u/0/#inbox?x=1";
        assert!(build(&i, 2000).prefix.starts_with("[Written in Safari \u{2014} Inbox (mail.example.com)]"));
    }

    #[test]
    fn screen_context_goes_first_and_is_cleaned() {
        let mut i = input("Sounds good, see you on Thur");
        i.screen_context = "  Priya: are we still on for Thursday?  \n\n[ignored marker]\nMe: yes, 3pm\n";
        let p = build(&i, 2000);
        assert_eq!(
            p.prefix,
            "[Text visible on screen]\nPriya: are we still on for Thursday?\nMe: yes, 3pm\n[End of screen text]\n\n\
             [Written in Mail \u{2014} Re: planning]\n\nSounds good, see you on"
        );
        assert_eq!(p.fragment, " Thur");
        let long: String = (0..400).map(|n| format!("line {n}\n")).collect();
        i.screen_context = &long;
        let p = build(&i, 2000);
        assert!(p.prefix.contains("line 399\n[End of screen text]"));
        assert!(!p.prefix.contains("line 1\n"));
    }

    #[test]
    fn other_apps_section_heads_the_prompt() {
        let mut i = input("Total spend was four");
        i.other_apps = "[Also open: Microsoft Word \u{2014} Q3.docx]\nTotal Q3 spend was $412,600.\n\n";
        i.screen_context = "Martin: could you send the Q3 numbers?";
        let p = build(&i, 2000);
        assert_eq!(
            p.prefix,
            "[Also open: Microsoft Word \u{2014} Q3.docx]\nTotal Q3 spend was $412,600.\n\n\
             [Text visible on screen]\nMartin: could you send the Q3 numbers?\n[End of screen text]\n\n\
             [Written in Mail \u{2014} Re: planning]\n\nTotal spend was"
        );
        assert_eq!(p.fragment, " four");
        assert_eq!(p.others, i.other_apps.len());
        assert!(p.prefix[p.others..].starts_with("[Text visible on screen]"));
        assert_eq!(build(&input("Hi"), 2000).others, 0);
    }

    #[test]
    fn header_offsets() {
        let mut i = input("Total spend was four");
        i.other_apps = "[Also open: Word \u{2014} Q3.docx]\nTotal Q3 spend was $412,600.\n\n";
        i.screen_context = "Martin: could you send the Q3 numbers?";
        let p = build(&i, 2000);
        assert_eq!(&p.prefix[..p.others], i.other_apps);
        assert!(p.prefix[p.others..p.screen].starts_with("[Text visible on screen]") && p.prefix[..p.screen].ends_with("[End of screen text]\n\n"));
        assert_eq!(&p.prefix[p.screen..p.header], "[Written in Mail \u{2014} Re: planning]\n\n");
        assert_eq!(&p.prefix[p.header..], "Total spend was");
        let bare = build(&input("Hi"), 2000);
        assert_eq!((bare.others, bare.screen), (0, 0));
        assert_eq!(&bare.prefix[bare.header..], "");
        let q = p.without_others().unwrap();
        assert_eq!(&q.prefix[q.screen..q.header], "[Written in Mail \u{2014} Re: planning]\n\n");
    }

    #[test]
    fn the_old_header_serves_while_the_new_one_prefills() {
        let mut a = input("Thanks Martin, the total was");
        a.other_apps = "[Also open: Word \u{2014} Q3.docx]\nTotal Q3 spend was $412,600.\n\n";
        a.screen_context = "Martin: could you send the Q3 numbers?";
        let live = build(&a, 2000);
        // Same field, new screen text and a new section: the old header, the new body.
        let mut b = input("Thanks Martin, the total was $412,600 and the");
        b.other_apps = "[Also open: Excel \u{2014} Q3.xlsx]\nContractors: $68,900\n\n";
        b.screen_context = "Martin: could you send the Q3 numbers?\nMartin: and contractors?";
        let target = build(&b, 2000);
        let old = with_old_header(&live, &target, true).unwrap();
        assert_eq!(old.prefix, format!("{}Thanks Martin, the total was $412,600 and", &live.prefix[..live.header]));
        assert_eq!((old.others, old.screen, old.header), (live.others, live.screen, live.header));
        assert_eq!(old.fragment, " the");
        // Another field: only the other-apps section is the old one.
        let mut c = input("Hi team");
        c.app_name = "Slack";
        c.other_apps = b.other_apps;
        let target = build(&c, 2000);
        let old = with_old_header(&live, &target, false).unwrap();
        assert_eq!(old.prefix, format!("{}{}", a.other_apps, &target.prefix[target.others..]));
        assert_eq!(&old.prefix[old.screen..old.header], &target.prefix[target.screen..target.header]);
        assert_eq!(&old.prefix[old.header..], "Hi");
        // Another field with the same lines (two drafts in one app): never its screen text.
        let mut d = input("Hi team");
        d.other_apps = b.other_apps;
        d.screen_context = "Someone else's thread";
        let target = build(&d, 2000);
        let old = with_old_header(&live, &target, false).unwrap();
        assert!(old.prefix.starts_with(a.other_apps) && old.prefix.contains("Someone else's thread") && !old.prefix.contains("Martin:"));
        // Nothing to substitute.
        assert!(with_old_header(&live, &live, true).is_none());
        let same = build(&input("Thanks Martin, the total was $412"), 2000);
        assert!(with_old_header(&build(&input("Thanks"), 2000), &same, true).is_none());
    }

    #[test]
    fn marker_echoes_are_cut() {
        assert_eq!(strip_marker_echo(" the figures [End of screen t"), " the figures");
        assert_eq!(strip_marker_echo(" [Also open: Word"), "");
        assert_eq!(strip_marker_echo(" [Wri"), "");
        assert_eq!(strip_marker_echo(" see [1] and [2]"), " see [1] and [2]");
        assert_eq!(strip_marker_echo(" at the [End of the day]"), " at the [End of the day]");
        assert_eq!(strip_marker_echo(" [Wr"), " [Wr");
        assert_eq!(strip_marker_echo(" going next week"), " going next week");
    }

    #[test]
    fn examples_section() {
        let ex = vec!["Thanks Priya [noted], talk Thursday.".to_string()];
        let mut i = input("Hi Sam");
        i.examples = &ex;
        let p = build(&i, 2000);
        assert!(p.prefix.starts_with(
            "[Earlier writing by the same person in Mail]\nThanks Priya (noted), talk Thursday.\n[End of earlier writing]\n\n[Written in Mail"
        ));
    }

    #[test]
    fn writer_line_before_the_place() {
        let mut i = input("Best,\nPri");
        i.writer = "Priya Raman (Product Manager, Northwind)";
        let p = build(&i, 2000);
        assert_eq!(
            p.prefix,
            "[Written by Priya Raman (Product Manager, Northwind)]\n[Written in Mail \u{2014} Re: planning]\n\nBest,\n"
        );
        assert_eq!(p.fragment, "Pri");
    }

    #[test]
    fn long_window_is_stable_across_keystrokes() {
        let base: String = "lorem ipsum dolor sit amet ".repeat(200);
        let a = build(&input(&format!("{base}consec")), 1500);
        let b = build(&input(&format!("{base}consect")), 1500);
        let c = build(&input(&format!("{base}consectetur adip")), 1500);
        assert_eq!(a.prefix, b.prefix);
        assert!(c.prefix.starts_with(&a.prefix));
        assert!(a.prefix.len() < 1700);
    }
}
