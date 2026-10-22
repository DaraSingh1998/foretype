//! Word-boundary helpers shared by the context builder, token healing and accept logic.

/// Characters that can belong to the word currently being typed.
pub fn is_word_char(c: char) -> bool {
    is_letter(c) || matches!(c, '\'' | '\u{2019}' | '-' | '_')
}

/// Letters and digits, including the signs Unicode doesn't count as alphabetic but that sit
/// inside words in Indic scripts: the virama that joins consonants (क्या, "kya"), the nukta
/// (फ़) and the zero-width (non-)joiners around them. Without them a Hindi word splits in two
/// and token healing starts from half a syllable.
pub fn is_letter(c: char) -> bool {
    let cp = c as u32;
    c.is_alphanumeric()
        // Devanagari to Malayalam share one block layout: nukta at 0x3C, virama at 0x4D.
        || ((0x0900..=0x0D7F).contains(&cp) && matches!(cp & 0x7F, 0x3C | 0x4D))
        || matches!(cp, 0x0951..=0x0954 | 0x0D3B | 0x0DCA | 0x200C | 0x200D)
}

/// Splits the text before the caret into a stable committed prefix and the fragment the
/// model has to continue.
///
/// The fragment is the partial word at the caret plus the single space in front of it. Two
/// things follow from that: the prompt never ends in a bare space token (BPE vocabularies
/// attach the space to the next word, so a trailing space makes base models stumble), and
/// the committed prefix stays byte-identical for every keystroke inside a word, which keeps
/// the KV cache warm. Token healing then constrains generation to start with the fragment.
pub fn split_fragment(text: &str) -> (&str, &str) {
    let mut start = text.len();
    for (i, c) in text.char_indices().rev() {
        if is_word_char(c) {
            start = i;
        } else {
            break;
        }
    }
    let before = &text[..start];
    if let Some(rest) = before.strip_suffix(' ') {
        if !rest.is_empty() && !rest.ends_with(char::is_whitespace) {
            start -= 1;
        }
    }
    text.split_at(start)
}

/// The partial word being typed, without the leading space.
pub fn fragment_word(fragment: &str) -> &str {
    fragment.trim_start_matches(' ')
}

/// Prefix of `s` holding its first `n` words. Leading whitespace belongs to the word after it,
/// and the first word may be the rest of a word the user is still typing.
pub fn take_words(s: &str, n: usize) -> &str {
    if n == 0 {
        return "";
    }
    let mut count = 0;
    let mut in_word = false;
    for (i, c) in s.char_indices() {
        if c.is_whitespace() {
            if in_word {
                count += 1;
                in_word = false;
                if count == n {
                    return &s[..i];
                }
            }
        } else {
            in_word = true;
        }
    }
    s
}

/// Number of words in `s`, counted the same way as [`take_words`].
pub fn count_words(s: &str) -> usize {
    let mut count = 0;
    let mut in_word = false;
    for c in s.chars() {
        if c.is_whitespace() {
            in_word = false;
        } else if !in_word {
            in_word = true;
            count += 1;
        }
    }
    count
}

/// Drops a trailing word that generation may have cut off mid-way. The first word is kept
/// because it usually completes the word the user is typing.
pub fn drop_partial_last_word(s: &str) -> &str {
    match s.trim_end().rfind(char::is_whitespace) {
        Some(i) if s[..i].chars().any(|c| !c.is_whitespace()) => s[..i].trim_end(),
        _ => s,
    }
}

/// Cuts a raw continuation to at most `max_words` words, at the first sentence end when
/// `stop_at_sentence` is set, and without a trailing word that `truncated` generation may
/// have cut off.
pub fn limit(s: &str, max_words: usize, stop_at_sentence: bool, truncated: bool) -> String {
    let mut cut = take_words(s, max_words.max(1));
    let complete = cut.len() < s.len();
    if stop_at_sentence {
        let mut end = 0;
        let mut in_word = false;
        for (i, c) in cut.char_indices() {
            if c.is_whitespace() {
                if in_word && ends_sentence(&cut[..i]) {
                    end = i;
                    break;
                }
                in_word = false;
            } else {
                in_word = true;
            }
        }
        if end > 0 {
            cut = &cut[..end];
        }
    }
    let cut = if truncated && !complete { drop_partial_last_word(cut) } else { cut };
    cut.trim_end().to_string()
}

/// True when `s` ends a sentence: `.` `!` `?` `…`, or the danda `।` and double danda `॥` of
/// Hindi and other Indic scripts.
pub fn ends_sentence(s: &str) -> bool {
    let t = s.trim_end_matches(['"', '\u{201D}', ')', '\'']);
    t.ends_with(['.', '!', '?', '\u{2026}', '\u{964}', '\u{965}'])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fragment_includes_leading_space() {
        assert_eq!(split_fragment("Thanks for the no"), ("Thanks for the", " no"));
        assert_eq!(split_fragment("Thanks for the "), ("Thanks for the", " "));
        assert_eq!(split_fragment("Hello"), ("", "Hello"));
        assert_eq!(split_fragment("Hello, wor"), ("Hello,", " wor"));
        assert_eq!(split_fragment("Hi  "), ("Hi  ", ""));
        assert_eq!(split_fragment("line\n"), ("line\n", ""));
        assert_eq!(split_fragment("line\nWor"), ("line\n", "Wor"));
        assert_eq!(split_fragment("Hello,"), ("Hello,", ""));
        assert_eq!(split_fragment(""), ("", ""));
        assert_eq!(split_fragment("caf\u{e9} cr\u{e8}"), ("caf\u{e9}", " cr\u{e8}"));
    }

    #[test]
    fn committed_prefix_is_stable_within_a_word() {
        let a = split_fragment("We should keep go").0;
        let b = split_fragment("We should keep goi").0;
        let c = split_fragment("We should keep ").0;
        assert_eq!(a, b);
        assert_eq!(a, c);
    }

    #[test]
    fn words() {
        assert_eq!(take_words("ably the best", 1), "ably");
        assert_eq!(take_words(" world. How are", 1), " world.");
        assert_eq!(take_words(" world. How are", 2), " world. How");
        assert_eq!(take_words(" one", 3), " one");
        assert_eq!(count_words(" world. How are"), 3);
        assert_eq!(drop_partial_last_word(" world. How ar"), " world. How");
        assert_eq!(drop_partial_last_word("ably"), "ably");
        assert_eq!(drop_partial_last_word(" ably"), " ably");
        assert!(ends_sentence(" see you then."));
        assert!(ends_sentence(" really?\""));
        assert!(!ends_sentence(" e.g"));
        assert_eq!(limit(" do the first part of it", 4, true, false), " do the first part");
        assert_eq!(limit("tes. Then we go on", 4, true, false), "tes.");
        assert_eq!(limit(" the reconcil", 4, true, true), " the");
        assert_eq!(limit(" one two three four five", 4, true, true), " one two three four");
    }

    #[test]
    fn danda_ends_a_sentence() {
        assert!(ends_sentence(" ठीक है।"));
        assert!(ends_sentence(" ठीक है ।"));
        assert!(ends_sentence(" सत्यमेव जयते॥"));
        assert!(ends_sentence(" ठीक है।\""));
        assert!(!ends_sentence(" ठीक है"));
        assert_eq!(limit(" ठीक है। कल मिलते", 4, true, false), " ठीक है।");
        assert_eq!(limit(" ठीक है। कल मिलते", 4, false, false), " ठीक है। कल मिलते");
        // A danda written after a space counts as a word of its own.
        assert_eq!(limit(" ठीक है । कल मिलते", 4, true, false), " ठीक है ।");
    }

    #[test]
    fn indic_signs_stay_inside_words() {
        // Virama in क्या, nukta and virama in दफ़्तर.
        assert!("क्या".chars().all(is_word_char) && "दफ़्तर".chars().all(is_word_char));
        assert!(!is_word_char('।') && !is_word_char('॥'));
        assert_eq!(split_fragment("तुम क्या"), ("तुम", " क्या"));
        assert_eq!(split_fragment("दफ़्तर। क्"), ("दफ़्तर।", " क्"));
        assert_eq!(split_fragment("नमस्ते"), ("", "नमस्ते"));
        // Bengali and Gujarati viramas and a zero-width joiner count; the abbreviation sign doesn't.
        assert!(is_letter('\u{9CD}') && is_letter('\u{ACD}') && is_letter('\u{200D}'));
        assert!(!is_letter('\u{970}'));
    }
}
