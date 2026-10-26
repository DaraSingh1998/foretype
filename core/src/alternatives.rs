//! Word alternatives (D50): other phrases the beam search considered for the same text,
//! offered next to the suggestion in a numbered card. Option+N takes an alternative's next
//! word, so each one must start with a word that neither the suggestion nor an earlier
//! alternative starts with, compared without case and trailing punctuation ("meeting" and
//! "meeting." are the same choice).

use crate::words;

/// Most alternatives offered with a suggestion (Option+1 to Option+3).
pub const MAX: usize = 3;

/// The word an accept takes first, as alternatives are compared: without the spaces before
/// it, punctuation after it or case. With a partial word typed it is the word's rest ("ting"
/// after "mee").
pub fn first_word_key(text: &str) -> String {
    let word = words::take_words(text, 1).trim_start();
    word.trim_end_matches(|c: char| !words::is_word_char(c)).to_lowercase()
}

/// Up to `MAX` of `candidates` (best first) to offer with `shown`: none blank, each starting
/// with its own word. Nothing when `shown` is blank (no suggestion, no card).
pub fn distinct<I: IntoIterator<Item = String>>(shown: &str, candidates: I) -> Vec<String> {
    if shown.trim().is_empty() {
        return Vec::new();
    }
    let mut seen = vec![first_word_key(shown)];
    let mut out = Vec::new();
    for c in candidates {
        if out.len() == MAX {
            break;
        }
        if c.trim().is_empty() {
            continue;
        }
        let key = first_word_key(&c);
        if seen.contains(&key) {
            continue;
        }
        seen.push(key);
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn alternatives_start_with_their_own_word() {
        let got = distinct(" the meeting", v(&[" the call", " a call", " our team", " A quick", " this week", " it"]));
        assert_eq!(got, v(&[" a call", " our team", " this week"]), "same first word (any case) goes; three at most");
    }

    #[test]
    fn trailing_punctuation_is_not_a_different_word() {
        assert_eq!(distinct(" soon", v(&[" soon.", " soon, and", " today."])), v(&[" today."]));
        assert_eq!(distinct(" Thanks", v(&[" Thanks!", " Cheers,"])), v(&[" Cheers,"]));
        // An apostrophe or a hyphen belongs to the word.
        assert_eq!(distinct(" don", v(&[" don't", " well-known"])), v(&[" don't", " well-known"]));
    }

    #[test]
    fn the_rest_of_a_partial_word_counts_as_its_first_word() {
        // Typed "mee": "ting" and "t" are different words to take.
        assert_eq!(distinct("ting tomorrow", v(&["t you", "ting, then", "k"])), v(&["t you", "k"]));
        assert_eq!(first_word_key("ting, then"), "ting");
    }

    #[test]
    fn blank_candidates_and_blank_suggestions_give_nothing() {
        assert_eq!(distinct(" hello", v(&["", "  ", " there"])), v(&[" there"]));
        assert!(distinct("", v(&[" there"])).is_empty());
        assert!(distinct("   ", v(&[" there"])).is_empty());
    }

    #[test]
    fn hindi_words_compare_whole() {
        // क्या ends in a virama-joined syllable: one word, not two.
        assert_eq!(distinct(" क्या", v(&[" क्या?", " कब", " क्यों"])), v(&[" कब", " क्यों"]));
    }
}
