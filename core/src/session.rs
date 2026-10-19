//! Suggestion state that lets most keystrokes skip inference: typing through a visible
//! suggestion, backspacing inside it, accepting word by word, and a small exact-match cache.

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

#[derive(Debug, Default)]
pub struct Session {
    field_key: u64,
    /// Text before the caret that the current suggestion continues.
    base: String,
    suggestion: String,
    cache: VecDeque<(u64, String, String)>,
    /// Text the user dismissed a suggestion for; no new suggestion until it changes.
    dismissed: Option<(u64, String)>,
}

impl Session {
    pub fn set(&mut self, field_key: u64, base: &str, suggestion: &str) {
        self.field_key = field_key;
        self.base = base.to_string();
        self.suggestion = suggestion.to_string();
        if !suggestion.is_empty() {
            self.cache.retain(|(k, b, _)| !(*k == field_key && b == base));
            self.cache.push_back((field_key, base.to_string(), suggestion.to_string()));
            if self.cache.len() > CACHE_SIZE {
                self.cache.pop_front();
            }
        }
    }

    pub fn clear(&mut self) {
        self.suggestion.clear();
        self.base.clear();
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
        if field_key != self.field_key || self.suggestion.is_empty() {
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
    /// before the host app reports the edit still inserts the following word.
    pub fn accept(&mut self, mode: AcceptMode) -> Option<(String, String)> {
        if self.suggestion.is_empty() {
            return None;
        }
        let insert = match mode {
            AcceptMode::NextWord => words::take_words(&self.suggestion, 1).to_string(),
            AcceptMode::All => self.suggestion.clone(),
        };
        let remaining = self.suggestion[insert.len()..].to_string();
        self.base.push_str(&insert);
        self.suggestion = if remaining.trim().is_empty() { String::new() } else { remaining.clone() };
        Some((insert, self.suggestion.clone()))
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
        assert_eq!(s.accept(AcceptMode::NextWord), Some(("tes".into(), " from Tuesday.".into())));
        assert_eq!(s.accept(AcceptMode::NextWord), Some((" from".into(), " Tuesday.".into())));
        // Host app reports the inserted text: the rest stays visible without inference.
        assert_eq!(s.type_through(1, "Thanks for the notes from").as_deref(), Some(" Tuesday."));
        assert_eq!(s.accept(AcceptMode::All), Some((" Tuesday.".into(), String::new())));
        assert_eq!(s.accept(AcceptMode::All), None);
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
