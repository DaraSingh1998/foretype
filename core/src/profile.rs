//! A personalization profile derived from the user's writing history: which (non-trivial)
//! words they use and how often, plus a picker for short examples of their past writing in
//! the same app. The engine turns the word list into a decode-time bias, which nudges word
//! choice towards the user's vocabulary without fine-tuning anything; deleting the history
//! restores the unmodified model immediately.

use std::collections::{HashMap, HashSet};

use crate::history::Record;
use crate::words;

/// Very common English words: frequent in everyone's writing, so biasing them says nothing
/// about the user and only distorts the model.
const STOPWORDS: &str = "the and that have for not with you this but his from they say her she will one all \
would there their what out about who get which when make can like time just him know take people into year your \
good some could them see other than then now look only come its over think also back after use two how our work \
first well way even new want because any these give day most are was were been has had did does doing done being \
very much more many such each both few those here where why while should might must shall into onto upon also \
just really still again ever never always maybe please thanks thank hello dear best regards yes okay sure";

#[derive(Debug, Default, Clone)]
pub struct Profile {
    /// Lowercased word -> (count, most recent spelling as written).
    words: HashMap<String, (u32, String)>,
    stop: HashSet<&'static str>,
}

impl Profile {
    pub fn new() -> Self {
        Self { words: HashMap::new(), stop: STOPWORDS.split_whitespace().collect() }
    }

    pub fn from_records(records: &[Record]) -> Self {
        let mut p = Self::new();
        for r in records {
            p.add_text(&r.text);
        }
        p
    }

    pub fn add_text(&mut self, text: &str) {
        for raw in text.split(|c: char| !(words::is_letter(c) || c == '\'' || c == '\u{2019}' || c == '-')) {
            let w = raw.trim_matches(|c: char| c == '\'' || c == '\u{2019}' || c == '-');
            if w.chars().count() < 4 || w.chars().any(|c| c.is_ascii_digit()) {
                continue;
            }
            let key = w.to_lowercase();
            if self.stop.contains(key.as_str()) {
                continue;
            }
            let e = self.words.entry(key).or_insert((0, String::new()));
            e.0 += 1;
            e.1 = w.to_string();
        }
    }

    pub fn word_count(&self) -> usize {
        self.words.len()
    }

    /// True if the user has written this (lowercased) word.
    pub fn knows(&self, lower: &str) -> bool {
        self.words.contains_key(lower)
    }

    /// True if one of the user's (lowercased) words starts with `lower_prefix`.
    pub fn has_prefix(&self, lower_prefix: &str) -> bool {
        self.words.keys().any(|w| w.starts_with(lower_prefix))
    }

    /// Words used at least `min_count` times with a weight in (0, 1]: log-scaled by count.
    pub fn weighted_words(&self, limit: usize, min_count: u32) -> Vec<(String, f32)> {
        let mut v: Vec<(&String, u32)> = self
            .words
            .values()
            .filter(|(c, _)| *c >= min_count)
            .map(|(c, w)| (w, *c))
            .collect();
        v.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
        v.truncate(limit);
        let max = v.first().map_or(1, |x| x.1).max(2) as f32;
        v.into_iter().map(|(w, c)| (w.clone(), ((1.0 + c as f32).ln() / (1.0 + max).ln()).min(1.0))).collect()
    }
}

fn word_set(text: &str) -> HashSet<String> {
    text.split(|c: char| !words::is_letter(c))
        .filter(|w| w.chars().count() >= 4)
        .map(str::to_lowercase)
        .collect()
}

/// Up to `max` short snippets of the user's earlier writing in `app`, most similar to
/// `text_before` first (shared words), then most recent; at most `max_chars` each.
pub fn examples(records: &[Record], app: &str, text_before: &str, max: usize, max_chars: usize) -> Vec<String> {
    let current = word_set(text_before);
    let mut scored: Vec<(usize, u64, &Record)> = records
        .iter()
        .filter(|r| r.app == app && r.text.chars().count() >= 30)
        .filter(|r| !text_before.contains(r.text.trim()))
        .map(|r| (word_set(&r.text).intersection(&current).count(), r.ts, r))
        .collect();
    scored.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.cmp(&a.1)));
    scored
        .into_iter()
        .take(max)
        .map(|(_, _, r)| {
            let t = r.text.trim();
            if t.chars().count() <= max_chars {
                t.to_string()
            } else {
                let cut: String = t.chars().take(max_chars).collect();
                let end = cut.rfind(char::is_whitespace).unwrap_or(cut.len());
                format!("{}\u{2026}", cut[..end].trim_end())
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_skips_stopwords_and_short_words() {
        let p = Profile::from_records(&[
            Record { ts: 1, app: "a".into(), text: "Priya, the reconciliation report is with Priya and Marco.".into() },
            Record { ts: 2, app: "a".into(), text: "Ask Priya about the reconciliation numbers.".into() },
        ]);
        let w = p.weighted_words(10, 2);
        assert_eq!(w[0].0, "Priya");
        assert!(w.iter().any(|(x, _)| x == "reconciliation"));
        assert!(!w.iter().any(|(x, _)| x == "the" || x == "with" || x == "Marco"));
        assert!(w.iter().all(|(_, s)| *s > 0.0 && *s <= 1.0));
    }

    #[test]
    fn profile_keeps_hindi_words_whole() {
        let p = Profile::from_records(&[Record { ts: 1, app: "a".into(), text: "क्या तुम दफ़्तर आ रहे हो?".into() }]);
        assert!(p.knows("क्या") && p.knows("दफ़्तर"));
        assert!(!p.knows("फ़"));
    }

    #[test]
    fn examples_prefer_same_app_and_overlap() {
        let recs = vec![
            Record { ts: 1, app: "mail".into(), text: "Thanks for the planning notes, I will send the timeline Thursday.".into() },
            Record { ts: 2, app: "mail".into(), text: "Lunch tomorrow works for me, see you at the usual place then.".into() },
            Record { ts: 3, app: "slack".into(), text: "planning notes timeline Thursday review is all set for today".into() },
        ];
        let ex = examples(&recs, "mail", "Hi Priya, about the timeline for the planning review", 1, 200);
        assert_eq!(ex, vec!["Thanks for the planning notes, I will send the timeline Thursday.".to_string()]);
        let ex = examples(&recs, "mail", "", 2, 20);
        assert_eq!(ex.len(), 2);
        assert!(ex[0].ends_with('\u{2026}') && ex[0].chars().count() <= 21);
    }
}
