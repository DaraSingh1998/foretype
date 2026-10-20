//! `:shortcode` emoji suggestions, with GitHub/Slack-style names from gemoji (MIT,
//! `core/data/emoji.tsv`).
//!
//! A colon at the start of a word followed by two or more name characters offers the
//! best-matching emoji; accepting replaces the typed `:name` with it.
//!
//! Regenerate the table from gemoji's `db/emoji.json`:
//! `python3 -c "import json;[print(f'{a}\t{e[\"emoji\"]}') for e in json.load(open('emoji.json'))
//!  if float(e.get('unicode_version') or 0)<=15.0 for a in e['aliases']]" > core/data/emoji.tsv`

use std::sync::OnceLock;

const TABLE: &str = include_str!("../data/emoji.tsv");

/// Shortcodes people reach for most, preferred among prefix matches (gemoji has no usage
/// order; its own order is Unicode's).
const COMMON: &[&str] = &[
    "smile", "joy", "heart", "+1", "thumbsup", "pray", "fire", "tada", "rocket", "sob", "laughing", "wink", "blush",
    "heart_eyes", "thinking", "eyes", "clap", "ok_hand", "wave", "grin", "sweat_smile", "rofl", "slightly_smiling_face",
    "sunglasses", "100", "white_check_mark", "x", "warning", "star", "sparkles", "raised_hands", "muscle", "facepalm",
    "shrug", "cry", "scream", "rage", "sleeping", "partying_face", "kissing_heart", "hugs", "see_no_evil", "skull",
    "coffee", "beer", "birthday", "gift", "bulb", "memo", "calendar", "point_right", "point_up", "v", "crossed_fingers",
    "smiley", "grinning", "upside_down_face", "relieved", "confused", "neutral_face", "unamused", "roll_eyes",
    "grimacing", "nerd_face", "star_struck", "broken_heart", "green_heart", "blue_heart", "purple_heart",
    "yellow_heart", "thumbsdown", "-1", "raised_hand", "handshake", "point_down", "point_left", "trophy", "zap",
    "boom", "rainbow", "pizza", "computer", "email", "lock", "key", "hammer", "wrench", "gear", "dollar", "moneybag",
    "airplane", "car", "house", "dog", "cat", "unicorn", "bug", "seedling", "rose", "hourglass", "alarm_clock", "bell",
    "speech_balloon", "question", "exclamation", "heavy_check_mark", "arrow_right", "arrow_left", "recycle",
    "no_entry", "construction",
];

/// Characters a shortcode name may contain.
fn is_name_char(c: char) -> bool {
    c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '_' | '+' | '-')
}

fn table() -> &'static [(&'static str, &'static str)] {
    static T: OnceLock<Vec<(&'static str, &'static str)>> = OnceLock::new();
    T.get_or_init(|| TABLE.lines().filter_map(|l| l.split_once('\t')).collect())
}

/// The `:name` being typed at the end of `text_before`, colon included: a colon at the
/// start of a word (after whitespace, an opening bracket or nothing) followed by at least
/// two name characters. Times (`10:30`) and URLs (`https://`) don't qualify.
pub fn typed_shortcode(text_before: &str) -> Option<&str> {
    let start = text_before.rfind(':')?;
    let name = &text_before[start + 1..];
    if name.chars().count() < 2 || !name.chars().all(is_name_char) {
        return None;
    }
    let ok_before = text_before[..start].chars().next_back().is_none_or(|c| c.is_whitespace() || "([{\"'".contains(c));
    ok_before.then_some(&text_before[start..])
}

/// The best emoji for a typed name prefix (without the colon): an exact name first, then
/// the commonly used names, then the shortest name, then Unicode order.
pub fn lookup(prefix: &str) -> Option<(&'static str, &'static str)> {
    let rank = |name: &str| COMMON.iter().position(|c| *c == name).unwrap_or(COMMON.len());
    table()
        .iter()
        .enumerate()
        .filter(|(_, (name, _))| name.starts_with(prefix))
        .min_by_key(|(i, (name, _))| (*name != prefix, rank(name), name.len(), *i))
        .map(|(_, e)| *e)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_shortcodes_at_word_start_only() {
        assert_eq!(typed_shortcode("Great news :ta"), Some(":ta"));
        assert_eq!(typed_shortcode(":+1"), Some(":+1"));
        assert_eq!(typed_shortcode("(:fire"), Some(":fire"));
        assert_eq!(typed_shortcode("see you :s"), None, "one character is not enough");
        assert_eq!(typed_shortcode("at 10:30"), None);
        assert_eq!(typed_shortcode("https://ex"), None);
        assert_eq!(typed_shortcode("ok :) "), None);
        assert_eq!(typed_shortcode("note:ab"), None);
        assert_eq!(typed_shortcode("Big :Smile"), None, "names are lowercase");
    }

    #[test]
    fn ranks_exact_then_common_then_short() {
        assert_eq!(lookup("tada"), Some(("tada", "\u{1F389}")));
        assert_eq!(lookup("ta").map(|e| e.0), Some("tada"));
        assert_eq!(lookup("smi").map(|e| e.0), Some("smile"));
        assert_eq!(lookup("hea").map(|e| e.0), Some("heart"));
        assert_eq!(lookup("+1").map(|e| e.1), Some("\u{1F44D}"));
        assert_eq!(lookup("zzzzqq"), None);
    }

    #[test]
    fn common_names_exist_in_the_table() {
        let missing: Vec<_> = COMMON.iter().filter(|c| !table().iter().any(|(n, _)| n == *c)).collect();
        assert!(missing.is_empty(), "not in emoji.tsv: {missing:?}");
    }
}
