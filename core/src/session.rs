//! Suggestion state that lets most keystrokes skip inference: typing through a visible
//! suggestion, backspacing inside it, accepting word by word, and a small exact-match cache.
//! A suggestion can also *replace* text before the caret (an emoji for a typed `:name`, a
//! correction for a misspelled word); those are accepted whole and never typed through.

use std::collections::VecDeque;

use crate::words;

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
    cache: VecDeque<(u64, String, String)>,
    /// Text the user dismissed a suggestion for; no new suggestion until it changes.
    dismissed: Option<(u64, String)>,
}

impl Session {
    pub fn set(&mut self, field_key: u64, base: &str, suggestion: &str) {
        self.field_key = field_key;
        self.base = base.to_string();
        self.suggestion = suggestion.to_string();
        self.replace.clear();
        self.whole = false;
        if !suggestion.is_empty() {
            self.cache.retain(|(k, b, _)| !(*k == field_key && b == base));
            self.cache.push_back((field_key, base.to_string(), suggestion.to_string()));
            if self.cache.len() > CACHE_SIZE {
                self.cache.pop_front();
            }
        }
    }

    /// Shows a suggestion without caching it (mid-line: it depends on the text after the
    /// caret too, which the cache key doesn't hold).
    pub fn set_uncached(&mut self, field_key: u64, base: &str, suggestion: &str) {
        self.field_key = field_key;
        self.base = base.to_string();
        self.suggestion = suggestion.to_string();
        self.replace.clear();
        self.whole = false;
    }

    /// Caches a suggestion for `base` without showing it (prefetch).
    pub fn remember(&mut self, field_key: u64, base: &str, suggestion: &str) {
        if suggestion.is_empty() {
            return;
        }
        self.cache.retain(|(k, b, _)| !(*k == field_key && b == base));
        self.cache.push_back((field_key, base.to_string(), suggestion.to_string()));
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

    /// Reuses the visible suggestion if `text_before` is the suggestion's base with some of
    /// the suggestion typed (or a few characters backspaced). Returns what is still left to
    /// show and re-bases the session on the new text.
    pub fn type_through(&mut self, field_key: u64, text_before: &str) -> Option<String> {
        if field_key != self.field_key || self.suggestion.is_empty() || !self.replace.is_empty() || self.whole {
            return None;
        }
        let remaining = if let Some(typed) = text_before.strip_prefix(self.base.as_str()) {
            let rest = self.suggestion.strip_prefix(typed)?;
            if rest.trim().is_empty() {
                return None;
            }
            rest.to_string()
        } else if let Some(deleted) = self.base.strip_prefix(text_before) {
            if deleted.chars().count() > MAX_BACKSPACE_REUSE || deleted.contains('\n') || text_before.is_empty() {
                return None;
            }
            format!("{deleted}{}", self.suggestion)
        } else {
            return None;
        };
        self.base = text_before.to_string();
        self.suggestion = remaining.clone();
        Some(remaining)
    }

    pub fn cached(&self, field_key: u64, text_before: &str) -> Option<String> {
        self.cache
            .iter()
            .rev()
            .find(|(k, b, _)| *k == field_key && b == text_before)
            .map(|(_, _, s)| s.clone())
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
        Some(Accepted { insert, remaining: self.suggestion.clone(), replace: String::new() })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn type_through_and_backspace() {
        let mut s = Session::default();
        s.set(1, "We should keep", " going next week.");
        assert_eq!(s.type_through(1, "We should keep g").as_deref(), Some("oing next week."));
        assert_eq!(s.type_through(1, "We should keep goi").as_deref(), Some("ng next week."));
        assert_eq!(s.type_through(1, "We should keep go").as_deref(), Some("ing next week."));
        assert_eq!(s.type_through(1, "We should keep gx"), None);
        assert_eq!(s.type_through(2, "We should keep go"), None);
    }

    #[test]
    fn consumed_suggestion_needs_inference() {
        let mut s = Session::default();
        s.set(1, "Hi", " there");
        assert_eq!(s.type_through(1, "Hi there"), None);
    }

    #[test]
    fn accept_word_by_word() {
        let mut s = Session::default();
        s.set(1, "Thanks for the no", "tes from Tuesday.");
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

    #[test]
    fn replacement_is_accepted_whole_and_not_typed_through() {
        let mut s = Session::default();
        s.set_replacement(1, "Great news :ta", ":ta", "\u{1F389}");
        assert_eq!(s.type_through(1, "Great news :tad"), None);
        let a = s.accept(AcceptMode::NextWord).unwrap();
        assert_eq!((a.insert.as_str(), a.replace.as_str(), a.remaining.as_str()), ("\u{1F389}", ":ta", ""));
        assert_eq!(s.accept(AcceptMode::All), None);
        s.set(1, "Hi", " there");
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
        s.set(1, "Hello", " world");
        s.set(1, "Hello w", "orld");
        assert_eq!(s.cached(1, "Hello").as_deref(), Some(" world"));
        s.dismiss(1, "Hello w");
        assert!(s.is_dismissed(1, "Hello w"));
        assert!(!s.is_dismissed(1, "Hello wo"));
        assert!(!s.is_dismissed(1, "Hello w"));
    }
}
