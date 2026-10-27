//! Phrase lookup in the writing history (D54): when the last words typed are words the user
//! wrote before, what they wrote next then is offered, without the model. People repeat
//! themselves (a greeting, a sign-off, how they describe their work), and an exact phrase of
//! theirs beats the model's guess at it. TabType measured +13% characters saved for users who
//! repeat phrases.
//!
//! The index maps the hash of every three consecutive words (lower case, without the
//! punctuation around them) to where the word after them starts. A lookup takes the three
//! words before the word being typed, finds the places they were written, keeps those whose
//! next word starts with what is typed of the word, and returns the continuation written most
//! often (the most recent on a tie). It needs the same continuation twice, or one place that
//! matches five words or more, so a phrase written once in passing isn't pushed on the user.

use std::collections::HashMap;
use std::hash::{Hash, Hasher};

use crate::words;

/// Words of context a lookup matches at least.
const KEY_WORDS: usize = 3;
/// Context words that make a single earlier place enough.
const STRONG_WORDS: usize = 5;
/// The continuation must have been written this often, unless the context is strong.
const MIN_REPEATS: usize = 2;

/// One word of a text: where it starts and ends, and its key form.
struct Word {
    start: usize,
    end: usize,
    key: String,
}

fn key_of(w: &str) -> String {
    w.trim_matches(|c: char| !c.is_alphanumeric()).to_lowercase()
}

/// The text's words, by whitespace; a line break is a word of its own (empty key), so
/// context never runs across lines.
fn split(text: &str) -> Vec<Word> {
    let mut out = Vec::new();
    let mut start = None;
    for (i, c) in text.char_indices() {
        if c.is_whitespace() {
            if let Some(s) = start.take() {
                out.push(Word { start: s, end: i, key: key_of(&text[s..i]) });
            }
            if c == '\n' {
                out.push(Word { start: i, end: i + 1, key: String::new() });
            }
        } else if start.is_none() {
            start = Some(i);
        }
    }
    if let Some(s) = start {
        out.push(Word { start: s, end: text.len(), key: key_of(&text[s..]) });
    }
    out
}

fn hash_keys(words: &[Word]) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    for w in words {
        w.key.hash(&mut h);
    }
    h.finish()
}

/// The user's earlier texts, indexed by three-word context.
#[derive(Default)]
pub struct PhraseIndex {
    texts: Vec<String>,
    /// Words of each text.
    words: Vec<Vec<Word>>,
    /// Context hash → (text, index of the word after the context).
    index: HashMap<u64, Vec<(u32, u32)>>,
}

impl PhraseIndex {
    pub fn new<'a>(texts: impl IntoIterator<Item = &'a str>) -> Self {
        let mut p = Self::default();
        for t in texts {
            p.add(t);
        }
        p
    }

    pub fn add(&mut self, text: &str) {
        let ti = self.texts.len() as u32;
        let words = split(text);
        for i in KEY_WORDS..words.len() {
            let ctx = &words[i - KEY_WORDS..i];
            if ctx.iter().any(|w| w.key.is_empty()) || words[i].key.is_empty() {
                continue;
            }
            self.index.entry(hash_keys(ctx)).or_default().push((ti, i as u32));
        }
        self.texts.push(text.to_string());
        self.words.push(words);
    }

    pub fn is_empty(&self) -> bool {
        self.texts.is_empty()
    }

    /// What the user wrote after the words before the caret, as the text to insert after
    /// `text_before` (the rest of the word being typed, then up to `max_words` words in all,
    /// ending at a line break or a sentence's end). None when nothing qualifies.
    pub fn lookup(&self, text_before: &str, max_words: usize) -> Option<String> {
        if self.index.is_empty() || max_words == 0 {
            return None;
        }
        let (committed, fragment) = words::split_fragment(text_before);
        let typed = words::fragment_word(fragment);
        // A space typed after the last word: the next word starts fresh.
        let ctx = split(committed);
        if ctx.len() < KEY_WORDS {
            return None;
        }
        let tail = &ctx[ctx.len() - KEY_WORDS..];
        if tail.iter().any(|w| w.key.is_empty()) {
            return None;
        }
        let places = self.index.get(&hash_keys(tail))?;
        let typed_lower = typed.to_lowercase();
        // Continuation → (times written, most recent text, longest context matched, text).
        let mut found: HashMap<String, (usize, u32, usize, String)> = HashMap::new();
        for &(ti, wi) in places {
            let words = &self.words[ti as usize];
            let text = &self.texts[ti as usize];
            let wi = wi as usize;
            // The keys must really match (a hash can collide), then how far back they go.
            let mut matched = 0;
            while matched < wi && matched < ctx.len() && words[wi - 1 - matched].key == ctx[ctx.len() - 1 - matched].key {
                matched += 1;
            }
            if matched < KEY_WORDS {
                continue;
            }
            let next = &text[words[wi].start..words[wi].end];
            if !next.to_lowercase().starts_with(&typed_lower) || (!typed.is_empty() && next.len() < typed.len()) {
                continue;
            }
            let Some(cont) = continuation(text, words, wi, typed.len(), max_words) else { continue };
            if cont.trim().is_empty() {
                continue;
            }
            let e = found.entry(cont.to_lowercase()).or_insert((0, ti, 0, cont));
            e.0 += 1;
            e.1 = e.1.max(ti);
            e.2 = e.2.max(matched);
        }
        let (count, _, matched, text) = found.into_values().max_by_key(|(n, recent, m, _)| (*n, *m, *recent))?;
        if count < MIN_REPEATS && matched < STRONG_WORDS {
            return None;
        }
        // After a word with no space typed yet, the continuation starts with its space; after
        // a space, without.
        Some(if fragment.ends_with(' ') && typed.is_empty() { text.trim_start().to_string() } else { text })
    }
}

/// The text after the typed `typed_len` bytes of word `wi`: the rest of that word, then the
/// next words (as written, with their spaces) up to `max_words` words in all, stopping after a
/// sentence's end or before a line break.
fn continuation(text: &str, words: &[Word], wi: usize, typed_len: usize, max_words: usize) -> Option<String> {
    let first = &words[wi];
    let mut out = String::new();
    out.push_str(text.get(first.start + typed_len..first.end)?);
    // The word being typed counts only when some of it is left to insert.
    let counted = usize::from(!out.is_empty());
    let mut prev_end = first.end;
    for (n, w) in (counted..).zip(&words[wi + 1..]) {
        if n >= max_words || (w.key.is_empty() && &text[w.start..w.end] == "\n") || words::ends_sentence(&out) {
            break;
        }
        out.push_str(&text[prev_end..w.end]);
        prev_end = w.end;
    }
    Some(if typed_len == 0 { format!(" {}", out.trim_start()) } else { out })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn idx(texts: &[&str]) -> PhraseIndex {
        PhraseIndex::new(texts.iter().copied())
    }

    #[test]
    fn a_repeated_phrase_is_offered() {
        let p = idx(&[
            "Hi team, the build is green. Let me know if you see anything odd.",
            "Deployed to staging. Let me know if you see any issues.",
            "Thanks all. Let me know if you see anything odd.",
        ]);
        // Mid-word: the rest of the word, then the next words.
        assert_eq!(p.lookup("All done. Let me know if you see any", 4).as_deref(), Some("thing odd."));
        // After a space.
        assert_eq!(p.lookup("All done. Let me know if you ", 3).as_deref(), Some("see anything odd."));
        // After a whole word with no space yet.
        assert_eq!(p.lookup("All done. Let me know if you", 2).as_deref(), Some(" see anything"));
    }

    #[test]
    fn once_is_not_enough_unless_the_context_is_long() {
        let p = idx(&["We should ship the parser on Friday after review."]);
        assert_eq!(p.lookup("I think we should ship the ", 4), None, "three words, once");
        assert_eq!(p.lookup("Agreed, we should ship the parser ", 3).as_deref(), Some("on Friday after"), "five words, once");
        assert_eq!(p.lookup("We should ship the parser ", 3).as_deref(), Some("on Friday after"));
    }

    #[test]
    fn nothing_for_another_word_or_across_lines() {
        let p = idx(&["see you on Monday then", "see you on Monday then"]);
        assert_eq!(p.lookup("I will see you on Tu", 3), None, "typed another word");
        assert_eq!(p.lookup("see\nyou on ", 3), None, "context crosses a line");
        assert_eq!(p.lookup("you on ", 3), None, "too little context");
        assert_eq!(p.lookup("I will see you on ", 2).as_deref(), Some("Monday then"));
        assert!(idx(&[]).lookup("I will see you on ", 2).is_none());
    }

    #[test]
    fn stops_at_a_line_break_and_a_sentence_end() {
        let p = idx(&["Best regards,\nPriya Raman", "Best regards,\nPriya Raman", "thanks for the update. See you", "thanks for the update. See you"]);
        assert_eq!(p.lookup("Many thanks for the ", 5).as_deref(), Some("update."));
    }
}
