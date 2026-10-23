//! Text from other apps' windows (D42): what a document, slides or a web page open beside
//! the field says, for suggestions that quote it.
//!
//! The shell keeps a pool of other windows' text (windows visible on any display, and
//! windows viewed in the last 10 minutes) and sends it with `ft_engine_set_context` only
//! when the pool changes, never with each keystroke. Here each window's text is cut into
//! passages of about 300 characters, and for each prompt the passages most relevant to what
//! is being written are picked within a token budget. They become the prompt's first
//! section:
//!
//! ```text
//! [Also open: Microsoft Word — Q3 Budget Review.docx]
//! Total Q3 spend was $412,600 against a budget of $398,000, an overrun of $14,600 (3.7%).
//! …
//! Contractors: $68,900 (budget $52,000)
//! ```
//!
//! **Ranking.** BM25 (k1 1.2, b 0.75) of each passage against the words being written
//! (the last 300 characters count double), the focused window's screen text and its title
//! (both lighter). A passage's score is multiplied by its window's weight: 1.0 for a window
//! on screen, 0.8 falling to 0.5 over 10 minutes for a recently viewed one. Passages of
//! windows on screen also get a small prior, so before anything matches (an empty reply)
//! the window beside the field is offered in document order; a recently viewed window's
//! passages need words in common with the text.
//!
//! **Stability.** The section heads the prompt, so any change to it costs a full prefill.
//! The selection is recomputed only when the committed words, the screen text or the pool
//! change, and replaced only when the best selection scores clearly higher (25% and one
//! good term match more), a passage it holds left the pool, or it no longer fits the
//! budget. Windows keep the order in which they first came into the pool and passages
//! their document order, so a passage added later lands after the ones already cached.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::hash::{Hash, Hasher};

use serde::{Deserialize, Serialize};

use crate::words;

/// One window's text, as the shell read it.
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct Passage {
    /// The app's name ("Microsoft Word").
    pub app: String,
    pub bundle_id: String,
    pub window_title: String,
    /// The page's host for a browser window ("docs.example.com"); never the full URL.
    pub url_host: String,
    pub text: String,
    /// When the text was read, in seconds since 1970.
    pub captured_at: f64,
    /// On screen now (on any display); false for a window viewed recently.
    pub visible: bool,
    /// The display it was on (the shell's index); not used for ranking.
    pub display: i64,
}

/// `ft_engine_set_context`'s JSON.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct ContextUpdate {
    pub passages: Vec<Passage>,
}

/// Target passage length in characters.
const CHUNK_CHARS: usize = 300;
/// Most of a window's text that is kept (the shell sends what is on screen first).
const MAX_WINDOW_CHARS: usize = 12_000;
/// Most passages in the pool; windows past it are dropped.
const MAX_CHUNKS: usize = 600;
/// How long a recently viewed window is kept (the shell expires them; here it only scales
/// the weight).
pub const RECENT_SECS: f64 = 600.0;

const K1: f64 = 1.2;
const B: f64 = 0.75;
/// Score every passage of a window on screen starts with.
const VISIBLE_PRIOR: f64 = 0.6;
/// Passages scoring below this are never picked.
const MIN_SCORE: f64 = 0.5;
/// A new selection replaces the current one only above `current × RATIO + MARGIN`.
const SWITCH_RATIO: f64 = 1.25;
const SWITCH_MARGIN: f64 = 1.0;

/// Short, frequent words that say nothing about which passage is meant.
const STOPWORDS: &str = "a an the and or but if of to in on at by for with from as is are was were be been being \
it its it's this that these those there here i me my we our us you your he she him they them his her their not no \
so do does did done have has had will would can could should may might must shall than then too very just also \
into over about up down out off again more most some any each other such only own same both few all what which who \
whom when where why how hi hello dear thanks thank regards best yes ok okay please let get got one two \
है हैं था थे थी के का की को में से पर और भी यह वह एक नहीं तो ही";

fn stopwords() -> &'static HashSet<&'static str> {
    static SET: std::sync::OnceLock<HashSet<&'static str>> = std::sync::OnceLock::new();
    SET.get_or_init(|| STOPWORDS.split_whitespace().collect())
}

/// Rough token count for budgets before the model's tokenizer is at hand, fitted on the
/// multi-window corpus's other-app texts (Qwen3: 0.93 of this on the whole, at most 1.05 for
/// one document; Gemma 4 the same within 0.02): ASCII letters and single spaces five to a
/// token, one token per digit (Qwen3 splits numbers into digits), per ASCII punctuation mark
/// or line break, per run of spaces in a table, and per other character (Devanagari costs
/// Qwen3 about one token per character).
pub fn estimate_tokens(s: &str) -> usize {
    let (mut letters, mut singles, mut runs, mut spaces) = (0usize, 0usize, 0usize, 0usize);
    for c in s.chars() {
        if c == ' ' {
            spaces += 1;
            runs += usize::from(spaces == 2);
            letters += 1;
            continue;
        }
        spaces = 0;
        if c.is_ascii_alphabetic() {
            letters += 1;
        } else {
            singles += 1;
        }
    }
    letters.div_ceil(5) + singles + runs
}

/// The lowercase index terms of a text: runs of letters and digits (`words::is_letter`),
/// two characters or more (any number counts), minus stopwords; an English plural `s` is
/// dropped so "contractors" finds "contractor".
fn terms(text: &str) -> impl Iterator<Item = String> + '_ {
    text.split(|c: char| !words::is_letter(c)).filter_map(|w| {
        if w.is_empty() {
            return None;
        }
        let lower = w.to_lowercase();
        let digits = lower.chars().any(|c| c.is_ascii_digit());
        if (lower.chars().count() < 2 && !digits) || stopwords().contains(lower.as_str()) {
            return None;
        }
        if lower.len() > 4 && lower.is_ascii() && lower.ends_with('s') && !lower.ends_with("ss") && !digits {
            return Some(lower[..lower.len() - 1].to_string());
        }
        Some(lower)
    })
}

fn hash_of<T: Hash>(t: T) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    t.hash(&mut h);
    h.finish()
}

/// What the text being written asks for: term → weight.
#[derive(Debug, Clone, Default)]
pub struct Query {
    /// Ordered, so scores add up the same way every time (ties stay ties).
    weights: BTreeMap<String, f64>,
    key: u64,
}

impl Query {
    /// `body`: the committed text before the caret (the prompt's body window); `screen`:
    /// the focused window's screen text; `title`: its window title.
    pub fn new(body: &str, screen: &str, title: &str) -> Self {
        let mut raw: BTreeMap<String, f64> = BTreeMap::new();
        let mut add = |text: &str, w: f64| {
            for t in terms(text) {
                *raw.entry(t).or_insert(0.0) += w;
            }
        };
        add(body, 1.0);
        // The sentence being written says most about what comes next.
        let tail_start = body.char_indices().rev().nth(299).map_or(0, |(i, _)| i);
        add(&body[tail_start..], 1.0);
        add(screen, 0.4);
        add(title, 0.5);
        // Repeats count, but less and less (BM25's k3 = 1.5).
        let weights = raw.into_iter().map(|(t, w)| (t, 2.5 * w / (1.5 + w))).collect();
        Self { weights, key: hash_of((body, screen, title)) }
    }
}

struct Window {
    /// "Microsoft Word — Q3 Budget Review.docx", cleaned for a header line.
    label: String,
    /// Who the window belongs to, for the shell's report view (`report`).
    app: String,
    bundle_id: String,
    weight: f64,
    prior: f64,
    /// When the window first came into the pool (its place in the section).
    seq: u64,
}

struct Chunk {
    /// Hash of the window's identity and the text: survives the pool being sent again.
    id: u64,
    window: usize,
    /// Position in its window's text.
    ordinal: usize,
    text: String,
    tokens: usize,
    len: usize,
}

/// The pool, its index and the current selection. Owned by the core behind a mutex.
#[derive(Default)]
pub struct OtherApps {
    windows: Vec<Window>,
    chunks: Vec<Chunk>,
    index: HashMap<u64, usize>,
    /// term → (chunk, term frequency).
    postings: HashMap<String, Vec<(usize, u32)>>,
    avg_len: f64,
    /// Window identity → first-seen sequence number (cleared with the pool).
    seen: HashMap<u64, u64>,
    next_seq: u64,
    generation: u64,
    /// Selected chunk ids and the section they render to.
    current: Vec<u64>,
    section: String,
    rendered_gen: u64,
    /// (pool generation, query, budget) of the last selection.
    memo: Option<(u64, u64, usize)>,
    /// How often the section changed (each change costs a full prefill).
    pub changes: u64,
    /// Sections rendered lately and the passages in them: the engine keeps serving the old
    /// one while a new one prefills (`section_alive`).
    recent: VecDeque<(String, Vec<u64>)>,
    /// The budget of the last selection, in estimated tokens (0 before the first).
    pub budget: usize,
}

/// One passage of a prompt's section, for the shell's "What Foretype sees" view.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ReportPassage {
    /// The window's header line ("Microsoft Word — Q3 Budget Review.docx").
    pub label: String,
    pub app: String,
    pub bundle_id: String,
    /// Its place in the window's text (0 is the first passage).
    pub ordinal: usize,
    /// Estimated tokens (`estimate_tokens`).
    pub tokens: usize,
    pub text: String,
}

impl OtherApps {
    pub fn is_empty(&self) -> bool {
        self.chunks.is_empty()
    }

    /// Windows and passages in the pool.
    pub fn size(&self) -> (usize, usize) {
        (self.windows.len(), self.chunks.len())
    }

    /// Replaces the pool. `now` (seconds since 1970) ages recently viewed windows. An empty
    /// list forgets everything, the order of windows included.
    pub fn set_passages(&mut self, passages: &[Passage], now: f64) {
        self.generation += 1;
        self.windows.clear();
        self.chunks.clear();
        self.index.clear();
        self.postings.clear();
        self.memo = None;
        if passages.is_empty() {
            self.seen.clear();
            self.current.clear();
            self.section.clear();
            self.recent.clear();
            return;
        }
        let mut lens = 0usize;
        for p in passages {
            if self.chunks.len() >= MAX_CHUNKS {
                break;
            }
            let ident = hash_of((&p.bundle_id, &p.app, &p.window_title, &p.url_host));
            let seq = *self.seen.entry(ident).or_insert_with(|| {
                self.next_seq += 1;
                self.next_seq
            });
            let weight = if p.visible {
                1.0
            } else {
                let age = (now - p.captured_at).clamp(0.0, RECENT_SECS);
                0.8 - 0.3 * age / RECENT_SECS
            };
            let w = self.windows.len();
            let text: String = p.text.chars().take(MAX_WINDOW_CHARS).collect();
            let mut added = false;
            for (ordinal, piece) in chunk(&text).into_iter().enumerate() {
                let id = hash_of((ident, &piece));
                if self.index.contains_key(&id) || self.chunks.len() >= MAX_CHUNKS {
                    continue;
                }
                let ci = self.chunks.len();
                let mut tf: HashMap<String, u32> = HashMap::new();
                for t in terms(&piece) {
                    *tf.entry(t).or_insert(0) += 1;
                }
                let len = tf.values().sum::<u32>() as usize;
                for (t, n) in tf {
                    self.postings.entry(t).or_default().push((ci, n));
                }
                lens += len;
                self.index.insert(id, ci);
                self.chunks.push(Chunk { id, window: w, ordinal, tokens: estimate_tokens(&piece), text: piece, len });
                added = true;
            }
            if added {
                self.windows.push(Window {
                    label: label(p),
                    app: p.app.clone(),
                    bundle_id: p.bundle_id.clone(),
                    weight,
                    prior: if p.visible { VISIBLE_PRIOR } else { 0.0 },
                    seq,
                });
            }
        }
        self.avg_len = (lens as f64 / self.chunks.len().max(1) as f64).max(1.0);
    }

    /// The section for this query within `budget` tokens, keeping the current selection
    /// unless another is clearly better (see the module notes). Empty when nothing fits.
    pub fn select(&mut self, q: &Query, budget: usize) -> &str {
        self.budget = budget;
        let key = (self.generation, q.key, budget);
        if self.memo == Some(key) {
            return &self.section;
        }
        self.memo = Some(key);
        if self.chunks.is_empty() || budget == 0 {
            if !self.current.is_empty() {
                self.changes += 1;
            }
            self.current.clear();
            self.section.clear();
            return &self.section;
        }
        let scores = self.scores(q);
        let candidate = self.pick(&scores, budget);
        let current: Option<Vec<usize>> = self.current.iter().map(|id| self.index.get(id).copied()).collect();
        // Nothing selected yet: anything is a gain.
        let keep = current.filter(|cur| !cur.is_empty()).is_some_and(|cur| {
            let total = |set: &[usize]| set.iter().map(|&i| scores[i]).sum::<f64>();
            self.cost(&cur) <= budget && total(&candidate) <= total(&cur) * SWITCH_RATIO + SWITCH_MARGIN
        });
        if keep {
            if self.rendered_gen != self.generation {
                // Same passages, perhaps a renamed window: render again (usually identical).
                let cur: Vec<usize> = self.current.iter().map(|id| self.index[id]).collect();
                self.section = self.render(&cur);
                self.rendered_gen = self.generation;
                self.remember();
            }
            return &self.section;
        }
        let ids: Vec<u64> = candidate.iter().map(|&i| self.chunks[i].id).collect();
        if ids != self.current {
            self.changes += 1;
        }
        self.current = ids;
        self.section = self.render(&candidate);
        self.rendered_gen = self.generation;
        self.remember();
        &self.section
    }

    fn remember(&mut self) {
        if self.section.is_empty() || self.recent.iter().any(|(s, _)| *s == self.section) {
            return;
        }
        self.recent.push_back((self.section.clone(), self.current.clone()));
        if self.recent.len() > 4 {
            self.recent.pop_front();
        }
    }

    /// Whether `section`, rendered here earlier, holds only passages still in the pool. Text
    /// of a window that left the pool (closed, expired, its app put on the never-read list)
    /// or of a cleared pool must not reach a prompt again, not even the old prompt served
    /// while a new section prefills (D42, D47). An empty section is always alive.
    pub fn section_alive(&self, section: &str) -> bool {
        section.is_empty()
            || self.recent.iter().find(|(s, _)| s == section).is_some_and(|(_, ids)| ids.iter().all(|id| self.index.contains_key(id)))
    }

    /// The passages of `section`, rendered here earlier, by id: `None` for a section this
    /// pool never rendered (or forgot). An empty section has none.
    pub fn ids_of(&self, section: &str) -> Option<Vec<u64>> {
        if section.is_empty() {
            return Some(Vec::new());
        }
        self.recent.iter().find(|(s, _)| s == section).map(|(_, ids)| ids.clone())
    }

    /// The passages with these ids that are still in the pool, in the section's order
    /// (windows as they first came, passages in document order). Text that left the pool is
    /// never shown again: the second value counts the passages that did.
    pub fn report(&self, ids: &[u64]) -> (Vec<ReportPassage>, usize) {
        let mut found: Vec<usize> = ids.iter().filter_map(|id| self.index.get(id).copied()).collect();
        found.sort_by_key(|&i| (self.windows[self.chunks[i].window].seq, self.chunks[i].ordinal));
        let passages = found
            .iter()
            .map(|&i| {
                let c = &self.chunks[i];
                let w = &self.windows[c.window];
                ReportPassage {
                    label: w.label.clone(),
                    app: w.app.clone(),
                    bundle_id: w.bundle_id.clone(),
                    ordinal: c.ordinal,
                    tokens: c.tokens,
                    text: c.text.clone(),
                }
            })
            .collect();
        (passages, ids.len() - found.len())
    }

    /// The current section, without selecting again (the engine's prefetch).
    pub fn section(&self) -> &str {
        &self.section
    }

    /// Labels and the start of each selected passage, for debug logs.
    pub fn describe(&self) -> String {
        let mut parts = Vec::new();
        for id in &self.current {
            let Some(&ci) = self.index.get(id) else { continue };
            let c = &self.chunks[ci];
            let start: String = c.text.chars().take(48).collect::<String>().replace('\n', " / ");
            parts.push(format!("{}#{}: {start:?}", self.windows[c.window].label, c.ordinal));
        }
        parts.join("; ")
    }

    fn scores(&self, q: &Query) -> Vec<f64> {
        let n = self.chunks.len() as f64;
        let mut bm25 = vec![0.0; self.chunks.len()];
        for (t, &qw) in &q.weights {
            let Some(post) = self.postings.get(t) else { continue };
            let df = post.len() as f64;
            let idf = (1.0 + (n - df + 0.5) / (df + 0.5)).ln();
            for &(ci, tf) in post {
                let tf = tf as f64;
                let dl = self.chunks[ci].len as f64;
                bm25[ci] += qw * idf * tf * (K1 + 1.0) / (tf + K1 * (1.0 - B + B * dl / self.avg_len));
            }
        }
        self.chunks
            .iter()
            .zip(bm25)
            .map(|(c, s)| {
                let w = &self.windows[c.window];
                (s + w.prior) * w.weight
            })
            .collect()
    }

    /// Tokens a set of passages costs in the section (an upper bound: each passage may be
    /// preceded by a "…" line, each window by its label line, plus the closing blank line).
    fn cost(&self, set: &[usize]) -> usize {
        let mut windows = HashSet::new();
        let mut total = 1;
        for &i in set {
            let c = &self.chunks[i];
            total += c.tokens + 3;
            if windows.insert(c.window) {
                total += label_tokens(&self.windows[c.window].label);
            }
        }
        total
    }

    /// The best passages that fit: highest score first, each that still fits is taken.
    fn pick(&self, scores: &[f64], budget: usize) -> Vec<usize> {
        let mut order: Vec<usize> = (0..self.chunks.len()).filter(|&i| scores[i] >= MIN_SCORE).collect();
        order.sort_by(|&a, &b| scores[b].total_cmp(&scores[a]).then(a.cmp(&b)));
        let mut picked = Vec::new();
        let mut windows = HashSet::new();
        let mut used = 1;
        for i in order {
            let c = &self.chunks[i];
            let mut cost = c.tokens + 3;
            if !windows.contains(&c.window) {
                cost += label_tokens(&self.windows[c.window].label);
            }
            if used + cost > budget {
                continue;
            }
            used += cost;
            windows.insert(c.window);
            picked.push(i);
        }
        picked
    }

    /// Windows in first-seen order, passages in document order, "…" where text was left out.
    fn render(&self, set: &[usize]) -> String {
        let mut groups: BTreeMap<u64, Vec<usize>> = BTreeMap::new();
        for &i in set {
            groups.entry(self.windows[self.chunks[i].window].seq).or_default().push(i);
        }
        let mut out = String::new();
        for (_, mut members) in groups {
            members.sort_by_key(|&i| self.chunks[i].ordinal);
            let w = &self.windows[self.chunks[members[0]].window];
            out.push_str(&format!("[Also open: {}]\n", w.label));
            let mut prev: Option<usize> = None;
            for i in members {
                let c = &self.chunks[i];
                if prev.is_some_and(|p| c.ordinal != p + 1) {
                    out.push_str("\u{2026}\n");
                }
                out.push_str(&c.text);
                out.push('\n');
                prev = Some(c.ordinal);
            }
        }
        if !out.is_empty() {
            out.push('\n');
        }
        out
    }
}

fn label_tokens(label: &str) -> usize {
    estimate_tokens(label) + 5
}

/// "App — Title (host)" for a header line: no brackets or line breaks, title ≤ 80 chars.
fn label(p: &Passage) -> String {
    let clean = |s: &str| s.replace(['[', '{'], "(").replace([']', '}'], ")").split_whitespace().collect::<Vec<_>>().join(" ");
    let app = clean(&p.app);
    let title: String = clean(&p.window_title).chars().take(80).collect();
    let mut place = app.clone();
    if !title.is_empty() && title != app {
        place = if place.is_empty() { title } else { format!("{place} \u{2014} {title}") };
    }
    let host = clean(&p.url_host);
    if !host.is_empty() {
        place = if place.is_empty() { host } else { format!("{place} ({host})") };
    }
    if place.is_empty() {
        "another window".into()
    } else {
        place
    }
}

/// Cuts a window's text into passages of about `CHUNK_CHARS`: lines are trimmed, empty
/// lines and lines starting with "[" (which could pass for the prompt's own markers) are
/// dropped, long lines split at sentence ends and then at spaces, and short lines packed
/// together (a slide's bullets, a sheet's rows) with their line breaks.
pub fn chunk(text: &str) -> Vec<String> {
    let mut pieces: Vec<(String, bool)> = Vec::new();
    for line in text.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('[')) {
        for (k, piece) in split_long(line).into_iter().enumerate() {
            pieces.push((piece, k == 0));
        }
    }
    let mut out = Vec::new();
    let mut cur = String::new();
    for (piece, line_start) in pieces {
        let sep = if line_start { "\n" } else { " " };
        if !cur.is_empty() && cur.chars().count() + 1 + piece.chars().count() > CHUNK_CHARS {
            out.push(std::mem::take(&mut cur));
        }
        if !cur.is_empty() {
            cur.push_str(sep);
        }
        cur.push_str(&piece);
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    // A single unbroken run (a long URL) can't be split at a space: cap it.
    for c in &mut out {
        if c.chars().count() > 2 * CHUNK_CHARS {
            *c = c.chars().take(2 * CHUNK_CHARS).collect();
        }
    }
    out
}

/// A line longer than a passage, as sentences (and those over the length, as runs of words).
fn split_long(line: &str) -> Vec<String> {
    if line.chars().count() <= CHUNK_CHARS {
        return vec![line.to_string()];
    }
    let mut sentences = Vec::new();
    let mut start = 0;
    let mut it = line.char_indices().peekable();
    while let Some((i, c)) = it.next() {
        let next_is_space = it.peek().is_none_or(|&(_, n)| n == ' ');
        if matches!(c, '.' | '!' | '?' | '\u{0964}') && next_is_space {
            let end = i + c.len_utf8();
            sentences.push(&line[start..end]);
            start = end;
        }
    }
    sentences.push(&line[start..]);
    let mut out = Vec::new();
    for s in sentences.into_iter().map(str::trim).filter(|s| !s.is_empty()) {
        if s.chars().count() <= CHUNK_CHARS {
            out.push(s.to_string());
            continue;
        }
        let mut cur = String::new();
        for w in s.split(' ').filter(|w| !w.is_empty()) {
            if !cur.is_empty() && cur.chars().count() + 1 + w.chars().count() > CHUNK_CHARS {
                out.push(std::mem::take(&mut cur));
            }
            if !cur.is_empty() {
                cur.push(' ');
            }
            cur.push_str(w);
        }
        if !cur.is_empty() {
            out.push(cur);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const BUDGET: &str = "Q3 Budget Review: Operations\nPrepared by Finance, October 2026\nSummary\n\
Total Q3 spend was $412,600 against a budget of $398,000, an overrun of $14,600 (3.7%).\n\
Most of the overrun came from contractor hours on the warehouse migration, which ran three weeks longer than planned.\n\
By category\nSalaries and benefits: $251,300 (budget $252,000)\nContractors: $68,900 (budget $52,000)\n\
Software licences: $37,400 (budget $39,500)\nTravel: $11,200 (budget $14,000)\nEquipment: $43,800 (budget $40,500)\n\
Recommendations\n1. Freeze new contractor engagements until the migration is signed off.\n\
2. Move the equipment refresh for the Leeds office into Q1.\n3. Keep the travel underspend as a buffer for Q4.";

    const RECIPE: &str = "Lemon drizzle cake\nPreheat the oven to 180C. Cream the butter and sugar until pale, \
then beat in the eggs one at a time. Fold in the flour and the zest of two lemons.\n\
Bake for 45 minutes, until a skewer comes out clean. Mix the juice of the lemons with icing sugar and pour it over the warm cake.";

    const LAUNCH: &str = "Spring Launch Plan\nTimeline\nBeta opens to 500 customers: 3 March\nPricing page goes live: 17 March\n\
Public launch and press briefing: 24 March\nFirst customer webinar: 2 April\nOwners\nBeta: Lena (Product)\n\
Pricing page: Omar (Web)\nPress: Grace (Comms)\nRisks\nPayment provider certification may slip by one week.";

    fn window(app: &str, title: &str, text: &str, visible: bool, age: f64) -> Passage {
        Passage {
            app: app.into(),
            bundle_id: format!("com.example.{}", app.to_lowercase().replace(' ', "")),
            window_title: title.into(),
            text: text.into(),
            captured_at: 1_000_000.0 - age,
            visible,
            ..Passage::default()
        }
    }

    fn pool(passages: &[Passage]) -> OtherApps {
        let mut o = OtherApps::default();
        o.set_passages(passages, 1_000_000.0);
        o
    }

    #[test]
    fn chunks_are_about_300_chars_and_drop_marker_lines() {
        let long: String = (0..30).map(|i| format!("Sentence number {i} says something about the plan. ")).collect();
        let text = format!("[Text visible on screen]\nTitle line\n\n  {long}\n[End of screen text]\nLast line");
        let chunks = chunk(&text);
        assert!(chunks.len() >= 5, "{chunks:?}");
        assert!(chunks.iter().all(|c| c.chars().count() <= CHUNK_CHARS), "{chunks:?}");
        assert!(chunks.iter().all(|c| !c.lines().any(|l| l.starts_with('['))));
        assert!(chunks[0].starts_with("Title line\nSentence number 0"));
        assert!(chunks.last().unwrap().ends_with("Last line"));
        // Short lines are packed together, keeping their line breaks.
        let launch = chunk(LAUNCH);
        assert_eq!(launch.len(), 2, "{launch:?}");
        assert!(launch[0].contains("Timeline\nBeta opens"));
        // One run with no spaces is capped.
        assert_eq!(chunk(&"x".repeat(5000))[0].chars().count(), 2 * CHUNK_CHARS);
    }

    #[test]
    fn an_old_section_is_alive_only_while_its_passages_are_in_the_pool() {
        let launch = window("Keynote", "Spring Launch Plan.key", LAUNCH, true, 0.0);
        let mut o = pool(&[launch.clone()]);
        let old = o.select(&Query::new("", "", ""), 512).to_string();
        assert!(!old.is_empty() && o.section_alive(&old));
        assert!(o.section_alive(""));
        assert!(!o.section_alive("[Also open: Something else]\nnever rendered here\n\n"));
        // Another window joins: the old section's passages are still there.
        o.set_passages(&[launch.clone(), window("Notes", "Cake", RECIPE, true, 0.0)], 1_000_000.0);
        let _ = o.select(&Query::new("lemon cake oven", "", ""), 512);
        assert!(o.section_alive(&old));
        // The window closed (or its app was put on the never-read list): dead.
        o.set_passages(&[window("Notes", "Cake", RECIPE, true, 0.0)], 1_000_000.0);
        assert!(!o.section_alive(&old));
        // A cleared pool forgets every section.
        let mut o = pool(&[launch]);
        let old = o.select(&Query::new("", "", ""), 512).to_string();
        o.set_passages(&[], 1_000_000.0);
        assert!(!o.section_alive(&old));
    }

    #[test]
    fn report_lists_a_sections_passages_while_they_are_in_the_pool() {
        let budget = window("Microsoft Word", "Q3 Budget Review.docx", BUDGET, true, 0.0);
        let launch = window("Keynote", "Spring Launch Plan.key", LAUNCH, true, 0.0);
        let mut o = pool(&[budget.clone(), launch.clone()]);
        let section = o.select(&Query::new("Contractors cost $68,900, the warehouse migration", "", ""), 512).to_string();
        assert_eq!(o.budget, 512);
        let ids = o.ids_of(&section).expect("rendered here");
        assert_eq!(o.ids_of(""), Some(Vec::new()));
        assert_eq!(o.ids_of("[Also open: Something else]\nnever rendered\n\n"), None);
        let (passages, gone) = o.report(&ids);
        assert_eq!(gone, 0);
        assert_eq!(passages.len(), ids.len());
        // In the section's order, each with its window and its share of the budget.
        let mut at = 0;
        for p in &passages {
            let found = section[at..].find(&p.text).map(|i| at + i);
            assert!(found.is_some(), "{:?} not after byte {at} of {section}", p.text);
            at = found.unwrap() + p.text.len();
            assert!(p.tokens > 0 && p.tokens == estimate_tokens(&p.text));
            assert!(section.contains(&format!("[Also open: {}]", p.label)));
        }
        assert_eq!(passages[0].app, "Microsoft Word");
        assert_eq!(passages[0].bundle_id, "com.example.microsoftword");
        // The Word window closes: its passages aren't shown any more, only counted.
        o.set_passages(&[launch], 1_000_000.0);
        let (left, gone) = o.report(&ids);
        assert!(left.iter().all(|p| p.app == "Keynote"));
        assert_eq!(left.len() + gone, ids.len());
        assert!(gone > 0);
        // A cleared pool: nothing.
        o.set_passages(&[], 1_000_000.0);
        assert_eq!(o.report(&ids).0, Vec::new());
        assert_eq!(o.ids_of(&section), None);
    }

    #[test]
    fn terms_skip_stopwords_and_fold_plurals() {
        let t: Vec<String> = terms("The contractors cost $68,900 in Q3 — क्या हाल है").collect();
        assert_eq!(t, ["contractor", "cost", "68", "900", "q3", "क्या", "हाल"]);
    }

    #[test]
    fn ranking_prefers_the_passage_being_written_about() {
        let mut o = pool(&[
            window("Notes", "Cake", RECIPE, false, 60.0),
            window("Microsoft Word", "Q3 Budget Review.docx", BUDGET, false, 60.0),
        ]);
        let q = Query::new("Hi Martin,\n\nContractors cost more than the budget, mostly on the warehouse migration", "", "");
        let s = o.select(&q, 120).to_string();
        assert!(s.starts_with("[Also open: Microsoft Word \u{2014} Q3 Budget Review.docx]\n"), "{s}");
        assert!(s.contains("warehouse migration"), "{s}");
        assert!(!s.contains("Lemon"), "{s}");
        assert!(estimate_tokens(&s) <= 120, "{} tokens: {s}", estimate_tokens(&s));
    }

    #[test]
    fn recently_viewed_windows_need_a_match_visible_ones_do_not() {
        let mut o = pool(&[window("Notes", "Cake", RECIPE, false, 30.0), window("Keynote", "Spring Launch Plan.key", LAUNCH, true, 0.0)]);
        // Nothing typed yet: the window on screen is offered, the recent one is not.
        let s = o.select(&Query::new("", "", ""), 512).to_string();
        assert!(s.contains("Beta opens to 500 customers"), "{s}");
        assert!(!s.contains("oven"), "{s}");
        // Writing about the cake brings the recent window in.
        let s = o.select(&Query::new("I baked the lemon drizzle cake: the oven at 180C, butter and sugar, then the lemons", "", ""), 512).to_string();
        assert!(s.contains("oven"), "{s}");
        // The window on screen came into the pool second, so it stays after the recipe.
        let recipe_at = s.find("[Also open: Notes").unwrap();
        let launch_at = s.find("[Also open: Keynote").unwrap_or(usize::MAX);
        assert!(recipe_at < launch_at, "{s}");
    }

    #[test]
    fn a_visible_window_outweighs_the_same_text_seen_minutes_ago() {
        let mut o = pool(&[window("Safari", "Plan A", LAUNCH, false, 500.0), window("Chrome", "Plan B", LAUNCH, true, 0.0)]);
        let s = o.select(&Query::new("The pricing page goes live on", "", ""), 90).to_string();
        assert!(s.starts_with("[Also open: Chrome \u{2014} Plan B]"), "{s}");
        assert!(!s.contains("Safari"), "{s}");
    }

    #[test]
    fn budget_is_respected_and_zero_means_none() {
        let big: String = (0..40).map(|i| format!("Paragraph {i} about the warehouse migration budget and contractors.\n")).collect();
        let mut o = pool(&[window("Microsoft Word", "Long.docx", &big, true, 0.0)]);
        let q = Query::new("the warehouse migration budget", "", "");
        for budget in [120, 250, 512] {
            let s = o.select(&q, budget).to_string();
            assert!(!s.is_empty());
            assert!(estimate_tokens(&s) <= budget, "budget {budget}: {} tokens", estimate_tokens(&s));
        }
        assert_eq!(o.select(&q, 0), "");
        // Too small for even one passage and its label.
        assert_eq!(o.select(&q, 12), "");
    }

    #[test]
    fn selection_is_sticky_until_a_clear_gain() {
        let mut o = pool(&[
            window("Microsoft Word", "Q3 Budget Review.docx", BUDGET, true, 0.0),
            window("Keynote", "Spring Launch Plan.key", LAUNCH, true, 0.0),
        ]);
        let mut body = String::from("Hi Martin, here is the short version. Total Q3 spend was $412,600 against a budget");
        let first = o.select(&Query::new(&body, "", ""), 110).to_string();
        let changes = o.changes;
        // More words about the same passages: the section stays byte-identical.
        for more in [" of $398,000", ", so we are over", " by $14,600", ", or 3.7%."] {
            body.push_str(more);
            assert_eq!(o.select(&Query::new(&body, "", ""), 110), first);
        }
        assert_eq!(o.changes, changes);
        // The same pool sent again: still the same.
        o.set_passages(
            &[window("Microsoft Word", "Q3 Budget Review.docx", BUDGET, true, 0.0), window("Keynote", "Spring Launch Plan.key", LAUNCH, true, 0.0)],
            1_000_010.0,
        );
        assert_eq!(o.select(&Query::new(&body, "", ""), 110), first);
        assert_eq!(o.changes, changes);
        // A clearly different topic switches.
        body.push_str("\n\nAlso, the launch: the beta opens to 500 customers on 3 March, the pricing page goes live on 17 March, the public launch and press briefing");
        let next = o.select(&Query::new(&body, "", ""), 110).to_string();
        assert_ne!(next, first);
        assert!(next.contains("press briefing"), "{next}");
        assert_eq!(o.changes, changes + 1);
    }

    #[test]
    fn a_passage_leaving_the_pool_forces_a_new_selection() {
        let mut o = pool(&[window("Microsoft Word", "Q3 Budget Review.docx", BUDGET, true, 0.0)]);
        let q = Query::new("Contractors cost $68,900", "", "");
        assert!(o.select(&q, 512).contains("Contractors"));
        o.set_passages(&[window("Keynote", "Spring Launch Plan.key", LAUNCH, true, 0.0)], 1_000_000.0);
        let s = o.select(&q, 512).to_string();
        assert!(!s.contains("Contractors") && s.contains("Spring Launch Plan"), "{s}");
        o.set_passages(&[], 1_000_000.0);
        assert_eq!(o.select(&q, 512), "");
        assert!(o.is_empty());
    }

    #[test]
    fn labels_are_escaped_and_gaps_marked() {
        let mut p = window("Safari", "Notes [draft]\nv2", "[1] first\nreal text about apples and pears", true, 0.0);
        p.url_host = "docs.example.com".into();
        let mut o = pool(&[p]);
        let s = o.select(&Query::new("apples", "", ""), 200).to_string();
        assert_eq!(s, "[Also open: Safari \u{2014} Notes (draft) v2 (docs.example.com)]\nreal text about apples and pears\n\n");
        // Passages that aren't next to each other are separated by an ellipsis line.
        // About 250 characters each, so every paragraph is a passage of its own.
        let para = |i: usize| {
            let topic = if i == 2 || i == 9 { "the zebra crossing on the high street" } else { "nothing to see" };
            let mut p = format!("Paragraph {i}: {topic}.");
            while p.len() < 250 {
                p.push_str(" more words follow");
            }
            p + "\n"
        };
        let text: String = (0..12).map(para).collect();
        let mut o = pool(&[window("Pages", "Report", &text, false, 0.0)]);
        let s = o.select(&Query::new("the zebra crossing on the high street", "", ""), 400).to_string();
        assert!(s.contains("Paragraph 2") && s.contains("Paragraph 9"), "{s}");
        assert!(s.contains("\n\u{2026}\nParagraph 9"), "{s}");
    }

    #[test]
    fn estimate_errs_high_for_english_and_counts_devanagari_per_char() {
        assert_eq!(estimate_tokens(""), 0);
        assert_eq!(estimate_tokens("abcdefg"), 2);
        assert_eq!(estimate_tokens("$412,600"), 8);
        assert_eq!(estimate_tokens("नमस्ते"), 6);
    }
}
