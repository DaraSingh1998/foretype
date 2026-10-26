//! Suggestion state that lets most keystrokes skip inference: typing through a visible
//! suggestion, backspacing inside it, accepting word by word, and a small exact-match cache.
//! A suggestion can also *replace* text before the caret (an emoji for a typed `:name`, a
//! correction for a misspelled word); those are accepted whole and never typed through.
//! A continuation can carry alternatives (D50): other phrases for the same text, each with
//! its own first word, one of which an accept can take instead.

use std::collections::VecDeque;

use crate::{alternatives, words};

const CACHE_SIZE: usize = 64;
/// How far a backspace may reach back into the text the suggestion was made for.
const MAX_BACKSPACE_REUSE: usize = 24;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AcceptMode {
    NextWord,
    All,
}

/// What an accept inserts. `replace` is the text just before the caret to delete first
/// (empty for an ordinary continuation).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Accepted {
    pub insert: String,
    pub remaining: String,
    pub replace: String,
}

#[derive(Debug, Default)]
pub struct Session {
    field_key: u64,
    /// Text before the caret that the current suggestion continues.
    base: String,
    suggestion: String,
    /// Non-empty when `suggestion` replaces this text at the end of `base`.
    replace: String,
    /// Accepted in one go whatever the mode (a detail such as an email address).
    whole: bool,
    /// The model's continuation (not a replacement or one of the user's details): the only
    /// kind with alternatives.
    plain: bool,
    /// Other phrases for `base`, best first (`alternatives::distinct`).
    alternatives: Vec<String>,
    /// The alternatives for `base` were searched for on demand: asking again answers at once.
    searched: bool,
    /// (field, base, suggestion, alternatives).
    cache: VecDeque<(u64, String, String, Vec<String>)>,
    /// Text the user dismissed a suggestion for; no new suggestion until it changes.
    dismissed: Option<(u64, String)>,
}

impl Session {
    /// Shows `suggestion` (with its `alternatives`) for `base` and caches it.
    pub fn set(&mut self, field_key: u64, base: &str, suggestion: &str, alternatives: &[String]) {
        self.set_uncached(field_key, base, suggestion, alternatives);
        self.remember(field_key, base, suggestion, alternatives);
    }

    /// Shows a suggestion without caching it (mid-line: it depends on the text after the
    /// caret too, which the cache key doesn't hold).
    pub fn set_uncached(&mut self, field_key: u64, base: &str, suggestion: &str, alternatives: &[String]) {
        self.field_key = field_key;
        self.base = base.to_string();
        self.suggestion = suggestion.to_string();
        self.replace.clear();
        self.whole = false;
        self.plain = true;
        self.alternatives = alternatives.to_vec();
        self.searched = false;
    }

    /// Caches a suggestion for `base` without showing it (prefetch).
    pub fn remember(&mut self, field_key: u64, base: &str, suggestion: &str, alternatives: &[String]) {
        if suggestion.is_empty() {
            return;
        }
        self.cache.retain(|(k, b, _, _)| !(*k == field_key && b == base));
        self.cache.push_back((field_key, base.to_string(), suggestion.to_string(), alternatives.to_vec()));
        if self.cache.len() > CACHE_SIZE {
            self.cache.pop_front();
        }
    }

    /// Shows `text` in place of `replace`, the end of `base` (not cached: it depends on
    /// exactly what was typed).
    pub fn set_replacement(&mut self, field_key: u64, base: &str, replace: &str, text: &str) {
        self.field_key = field_key;
        self.base = base.to_string();
        self.suggestion = text.to_string();
        self.replace = replace.to_string();
        self.whole = false;
        self.plain = false;
        self.alternatives.clear();
        self.searched = false;
    }

    /// Shows one of the user's details: the rest of it after what was typed, or (when
    /// `replace` is set) all of it in place of a start typed in another case. Not cached:
    /// it is recomputed on every keystroke. `whole` accepts it in one go.
    pub fn set_fill(&mut self, field_key: u64, base: &str, replace: &str, text: &str, whole: bool) {
        self.set_replacement(field_key, base, replace, text);
        self.whole = whole;
    }

    pub fn clear(&mut self) {
        self.suggestion.clear();
        self.base.clear();
        self.replace.clear();
        self.whole = false;
        self.alternatives.clear();
        self.searched = false;
    }

    pub fn dismiss(&mut self, field_key: u64, text_before: &str) {
        self.dismissed = Some((field_key, text_before.to_string()));
        self.clear();
    }

    pub fn is_dismissed(&mut self, field_key: u64, text_before: &str) -> bool {
        match &self.dismissed {
            Some((k, t)) if *k == field_key && t == text_before => true,
            Some(_) => {
                self.dismissed = None;
                false
            }
            None => false,
        }
    }

    pub fn current(&self) -> Option<(&str, &str)> {
        (!self.suggestion.is_empty()).then_some((self.base.as_str(), self.suggestion.as_str()))
    }

    /// The alternatives to the suggestion showing.
    pub fn alternatives(&self) -> &[String] {
        &self.alternatives
    }

    /// For an on-demand request: the continuation showing for exactly this text, its
    /// alternatives and whether they were searched for on demand already. None when nothing
    /// shows for it, or what shows is a replacement or a detail (no alternatives to those).
    pub fn alternatives_for(&self, field_key: u64, text_before: &str) -> Option<(String, Vec<String>, bool)> {
        let continuation = !self.suggestion.is_empty() && self.plain;
        (continuation && field_key == self.field_key && text_before == self.base)
            .then(|| (self.suggestion.clone(), self.alternatives.clone(), self.searched))
    }

    /// Stores an on-demand search's alternatives, if `suggestion` still shows for `base`.
    pub fn set_alternatives(&mut self, field_key: u64, base: &str, suggestion: &str, alternatives: &[String]) -> bool {
        if self.alternatives_for(field_key, base).is_none() || self.suggestion != suggestion {
            return false;
        }
        self.alternatives = alternatives.to_vec();
        self.searched = true;
        true
    }

    /// Reuses the visible suggestion if `text_before` is the suggestion's base with some of
    /// the suggestion typed (or a few characters backspaced). Returns what is still left to
    /// show and re-bases the session on the new text.
    pub fn type_through(&mut self, field_key: u64, text_before: &str) -> Option<String> {
        if field_key != self.field_key || self.suggestion.is_empty() || !self.replace.is_empty() || self.whole {
            return None;
        }
        // Alternatives follow along: those the typed text agrees with lose it from their start;
        // after a backspace all get the deleted text back.
        let (remaining, others) = if let Some(typed) = text_before.strip_prefix(self.base.as_str()) {
            let rest = self.suggestion.strip_prefix(typed)?;
            if rest.trim().is_empty() {
                return None;
            }
            let others = self.alternatives.iter().filter_map(|a| a.strip_prefix(typed)).map(str::to_string).collect::<Vec<_>>();
            (rest.to_string(), others)
        } else if let Some(deleted) = self.base.strip_prefix(text_before) {
            if deleted.chars().count() > MAX_BACKSPACE_REUSE || deleted.contains('\n') || text_before.is_empty() {
                return None;
            }
            (format!("{deleted}{}", self.suggestion), self.alternatives.iter().map(|a| format!("{deleted}{a}")).collect())
        } else {
            return None;
        };
        self.base = text_before.to_string();
        // Deleting a whole word can give two of them the same first word again.
        self.alternatives = alternatives::distinct(&remaining, others);
        self.searched = false;
        self.suggestion = remaining.clone();
        Some(remaining)
    }

    /// The cached suggestion for this text, with its alternatives.
    pub fn cached(&self, field_key: u64, text_before: &str) -> Option<(String, Vec<String>)> {
        self.cache
            .iter()
            .rev()
            .find(|(k, b, _, _)| *k == field_key && b == text_before)
            .map(|(_, _, s, a)| (s.clone(), a.clone()))
    }

    /// Text to insert for an accept, advancing the session past it so a second Tab pressed
    /// before the host app reports the edit still inserts the following word. A replacement
    /// or a whole fill is accepted whole whatever the mode.
    pub fn accept(&mut self, mode: AcceptMode) -> Option<Accepted> {
        if self.suggestion.is_empty() {
            return None;
        }
        if !self.replace.is_empty() || self.whole {
            self.whole = false;
            let replace = std::mem::take(&mut self.replace);
            let insert = std::mem::take(&mut self.suggestion);
            let kept = self.base.len().saturating_sub(replace.len());
            self.base.truncate(kept);
            self.base.push_str(&insert);
            return Some(Accepted { insert, remaining: String::new(), replace });
        }
        let insert = match mode {
            AcceptMode::NextWord => words::take_words(&self.suggestion, 1).to_string(),
            AcceptMode::All => self.suggestion.clone(),
        };
        let remaining = self.suggestion[insert.len()..].to_string();
        self.base.push_str(&insert);
        self.suggestion = if remaining.trim().is_empty() { String::new() } else { remaining.clone() };
        // They were for the text before this accept.
        self.alternatives.clear();
        self.searched = false;
        Some(Accepted { insert, remaining: self.suggestion.clone(), replace: String::new() })
    }

    /// Takes the next word of alternative `index` (Option+1 is 0), which becomes the
    /// suggestion: its rest shows after the caret and Tab goes on with it.
    pub fn accept_alternative(&mut self, index: usize) -> Option<Accepted> {
        let alt = self.alternatives.get(index)?.clone();
        if self.suggestion.is_empty() || !self.plain {
            return None;
        }
        self.suggestion = alt;
        self.accept(AcceptMode::NextWord)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn type_through_and_backspace() {
        let mut s = Session::default();
        s.set(1, "We should keep", " going next week.", &[]);
        assert_eq!(s.type_through(1, "We should keep g").as_deref(), Some("oing next week."));
        assert_eq!(s.type_through(1, "We should keep goi").as_deref(), Some("ng next week."));
        assert_eq!(s.type_through(1, "We should keep go").as_deref(), Some("ing next week."));
        assert_eq!(s.type_through(1, "We should keep gx"), None);
        assert_eq!(s.type_through(2, "We should keep go"), None);
    }

    #[test]
    fn consumed_suggestion_needs_inference() {
        let mut s = Session::default();
        s.set(1, "Hi", " there", &[]);
        assert_eq!(s.type_through(1, "Hi there"), None);
    }

    #[test]
    fn accept_word_by_word() {
        let mut s = Session::default();
        s.set(1, "Thanks for the no", "tes from Tuesday.", &[]);
        assert_eq!(s.accept(AcceptMode::NextWord), Some(ok("tes", " from Tuesday.")));
        assert_eq!(s.accept(AcceptMode::NextWord), Some(ok(" from", " Tuesday.")));
        // Host app reports the inserted text: the rest stays visible without inference.
        assert_eq!(s.type_through(1, "Thanks for the notes from").as_deref(), Some(" Tuesday."));
        assert_eq!(s.accept(AcceptMode::All), Some(ok(" Tuesday.", "")));
        assert_eq!(s.accept(AcceptMode::All), None);
    }

    fn ok(insert: &str, remaining: &str) -> Accepted {
        Accepted { insert: insert.into(), remaining: remaining.into(), replace: String::new() }
    }

    fn alts(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn an_alternative_takes_its_next_word_and_becomes_the_suggestion() {
        let mut s = Session::default();
        s.set(1, "See you", " tomorrow at noon", &alts(&[" soon, I hope", " next week"]));
        assert_eq!(s.alternatives(), alts(&[" soon, I hope", " next week"]));
        assert_eq!(s.accept_alternative(2), None, "there is no third one");
        assert_eq!(s.accept_alternative(1), Some(ok(" next", " week")));
        assert!(s.alternatives().is_empty(), "they were for the text before the accept");
        // Tab goes on with it, and the host app's report of the edit types through it.
        assert_eq!(s.type_through(1, "See you next").as_deref(), Some(" week"));
        assert_eq!(s.accept(AcceptMode::NextWord), Some(ok(" week", "")));
        assert_eq!(s.accept_alternative(0), None);
    }

    #[test]
    fn alternatives_follow_typing_and_backspace() {
        let mut s = Session::default();
        s.set(1, "Let's meet", " then", &alts(&[" there", " today", " at noon"]));
        assert_eq!(s.type_through(1, "Let's meet th").as_deref(), Some("en"));
        assert_eq!(s.alternatives(), alts(&["ere"]), "only those that start with what was typed");
        assert_eq!(s.type_through(1, "Let's meet t").as_deref(), Some("hen"));
        assert_eq!(s.alternatives(), alts(&["here"]));
        assert_eq!(s.type_through(1, "Let's meet then").as_deref(), None, "the suggestion is used up");
        // Backspacing over a whole word can leave two with the same first word: one goes.
        s.set(1, "Hi there w", "orld", &alts(&["ork", "e"]));
        assert_eq!(s.type_through(1, "Hi").as_deref(), Some(" there world"));
        assert_eq!(s.alternatives(), Vec::<String>::new());
    }

    #[test]
    fn alternatives_are_cached_and_asked_for_on_demand() {
        let mut s = Session::default();
        s.set(1, "Hello", " world", &alts(&[" there"]));
        s.set(1, "Hello w", "orld", &[]);
        assert_eq!(s.cached(1, "Hello"), Some((" world".into(), alts(&[" there"]))));
        // On demand: only for exactly the text showing, and remembered as searched.
        assert_eq!(s.alternatives_for(1, "Hello"), None);
        assert_eq!(s.alternatives_for(1, "Hello w"), Some(("orld".into(), vec![], false)));
        assert!(!s.set_alternatives(1, "Hello w", "ork", &alts(&["ide"])), "another suggestion shows now");
        assert!(s.set_alternatives(1, "Hello w", "orld", &alts(&["ide"])));
        assert_eq!(s.alternatives_for(1, "Hello w"), Some(("orld".into(), alts(&["ide"]), true)));
        // A replacement or a detail has none, and clears them.
        s.set_fill(1, "Regards,\n", "", "Priya Raman", false);
        assert_eq!(s.alternatives_for(1, "Regards,\n"), None, "a name goes word by word but is no continuation");
        s.set_replacement(1, "Great news :ta", ":ta", "\u{1F389}");
        assert_eq!(s.alternatives_for(1, "Great news :ta"), None);
        assert!(s.alternatives().is_empty());
        assert_eq!(s.accept_alternative(0), None);
    }

    #[test]
    fn replacement_is_accepted_whole_and_not_typed_through() {
        let mut s = Session::default();
        s.set_replacement(1, "Great news :ta", ":ta", "\u{1F389}");
        assert_eq!(s.type_through(1, "Great news :tad"), None);
        let a = s.accept(AcceptMode::NextWord).unwrap();
        assert_eq!((a.insert.as_str(), a.replace.as_str(), a.remaining.as_str()), ("\u{1F389}", ":ta", ""));
        assert_eq!(s.accept(AcceptMode::All), None);
        s.set(1, "Hi", " there", &[]);
        assert_eq!(s.accept(AcceptMode::All).unwrap().replace, "");
    }

    #[test]
    fn whole_fill_takes_one_tab_and_a_name_goes_word_by_word() {
        let mut s = Session::default();
        s.set_fill(1, "Call me on ", "", "+91 98765 43210", true);
        assert_eq!(s.type_through(1, "Call me on +"), None, "recomputed per keystroke instead");
        assert_eq!(s.accept(AcceptMode::NextWord), Some(ok("+91 98765 43210", "")));
        assert_eq!(s.accept(AcceptMode::NextWord), None);
        s.set_fill(1, "Regards,\n", "", "Priya Raman", false);
        assert_eq!(s.accept(AcceptMode::NextWord), Some(ok("Priya", " Raman")));
        s.set_fill(1, "my name is pri", "pri", "Priya Raman", false);
        let a = s.accept(AcceptMode::NextWord).unwrap();
        assert_eq!((a.insert.as_str(), a.replace.as_str()), ("Priya Raman", "pri"));
        assert_eq!(s.cached(1, "Call me on "), None);
    }

    #[test]
    fn cache_and_dismiss() {
        let mut s = Session::default();
        s.set(1, "Hello", " world", &[]);
        s.set(1, "Hello w", "orld", &[]);
        assert_eq!(s.cached(1, "Hello").map(|(t, _)| t).as_deref(), Some(" world"));
        s.dismiss(1, "Hello w");
        assert!(s.is_dismissed(1, "Hello w"));
        assert!(!s.is_dismissed(1, "Hello wo"));
        assert!(!s.is_dismissed(1, "Hello w"));
    }
}
