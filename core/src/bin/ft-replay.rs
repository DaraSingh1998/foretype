//! Replays typing through the core, the way a shell would, and reports latency and how
//! much typing the suggestions would have saved.
//!
//! The simulated user types one character at a time and presses Tab (accept next word)
//! whenever the visible suggestion's next word is exactly what they were about to type.
//!
//! --cpu runs without Metal offload. --beam N searches N phrases at once (default 1, greedy). --spell FILE replays the typo gate and autocorrect with
//! the macOS spell checker's verdicts (from tools/spell-map); without it neither fires.
//! usage (MODEL may be "-" with --backend llama-server|openai --url URL [--remote-model NAME]):
//!   ft-replay MODEL TEXT_FILE [--prime N] [--chars N] [--words N] [--app NAME] [--screen FILE] [-v]
//!   ft-replay MODEL --corpus CORPUS.jsonl [--words N] [--no-prefetch] [--only PREFIX] [--think MS]
//!       --think: simulated reaction time between seeing a suggestion and the next key
//!       (default 0: an instant user, which never lets a prefetch finish)
//!   ft-replay MODEL --corpus CORPUS.jsonl --details eval/details.json [--details-in-prompt]
//!       the user's own details per document id ("*" for the others; see eval/details.json):
//!       fills ("Regards,\n" -> the name), and with --details-in-prompt the writer line too.
//!   ft-replay MODEL --corpus CORPUS.jsonl --personal-loo [--only sw-] [--strength 0|1|2] [--no-examples]
//!       leave-one-out personalization: each document is replayed with the other selected
//!       documents as the user's writing history, with and without personalization.
//!   ft-replay MODEL --corpus CORPUS.jsonl --mid-line-eval [--typed N]
//!       mid-line check: at word starts in the middle of lines, with the next word's first N
//!       letters typed (default 1) and the rest of the line after the caret, counts how often
//!       the first suggested word is the word that was there.
//!   ft-replay MODEL --corpus CORPUS.jsonl --check-cache [--docs N] [--chars N] [--long]
//!       cache-reuse check: types each document (with a burst of backspaces every 9
//!       keystrokes) through an engine that reuses its cache and through one reset before
//!       every request, and counts the suggestions that differ. --long puts 1,400
//!       characters of other documents before the text and as screen context, so prompts
//!       pass 512 tokens (Gemma 4's sliding window). --fresh-batch N adds a third pass, fresh
//!       but prefilled in batches of N: it differs from the first fresh pass only in float
//!       rounding, which shows how much of a mismatch rate is noise rather than rollback.
//!   ft-replay MODEL --corpus CORPUS.jsonl --token-cost
//!       tokenizer cost: characters per token and tokens per word of the corpus text.
//!   ft-replay MODEL --corpus eval/corpus-multiwindow.jsonl --context-mode none|focused|other|both
//!       per document, its `screen` (text of the focused window around the field) and
//!       `context` (another app's window, `context_app` and `context_title`): `focused` sends
//!       `screen` as screen context, `other` sends `context` as the pool of other apps' text
//!       (`set_context`, a window on screen; the core picks passages into the prompt's
//!       other-apps section), `both` sends both. `other-screen` and `both-screen` are Phase A's
//!       stand-in: `context` (then `screen`) through screen context, under its 1,500-character
//!       cap. Default `none`.
//!       --distractors N adds the next N documents' `context` to the pool as windows viewed
//!       2, 4, … minutes ago (relevance ranking has to pick the right one); --other-recent
//!       makes the document's own window a recently viewed one (1 minute ago) instead of one
//!       on screen; --other-tokens N is the section's budget (default 512, as on 8 GB Macs).
//!   ft-replay MODEL --corpus eval/corpus-multiwindow.jsonl --ctx-bench [--n-ctx N] [--fill F] [--type N]
//!       long-context cost: per document, a prompt whose screen section holds other text,
//!       then the document's `context` and `screen`, filled to F of the window (default 0.9);
//!       the first suggestion from an empty cache (prefill + generation), then the next N
//!       keystrokes (default 40) reusing the cache; this process's resident memory and
//!       footprint after loading and at the end. Run one process per n_ctx (peak footprint
//!       is per process).
//!   ft-replay MODEL --restart-check
//!       swaps engines twice in one process as the app does when the model, the server or the
//!       context size changes (other apps' text on a 16 GB Mac): a new core (n_ctx 4096, then
//!       2048) is created while the old one is loaded and has just answered, the old one is
//!       freed on another thread, and the new one must load and answer.
//!   --n-ctx N: the context size in tokens for every mode (default 2048, as in the app).
//!   --instructions FILE (core/data/default-instructions.json format) or --default-instructions
//!       types with those custom instructions (corpus apps such as "Mail" stand in for their
//!       bundle IDs); without either, with none.

use std::collections::BTreeMap;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use foretype_core::context::{self, ContextInput};
use foretype_core::details::UserDetails;
use foretype_core::engine::{Engine, EngineConfig, GenError, GenOptions};
use foretype_core::instructions::{self, DefaultInstructions};
use foretype_core::others::{self, OtherApps, Passage, Query};
use foretype_core::session::AcceptMode;
use foretype_core::{words, Core, CoreConfig, Event, Settings, Snapshot};

fn pct(v: &[f64], p: f64) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    let mut v = v.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[((v.len() - 1) as f64 * p).round() as usize]
}

#[derive(Default)]
struct Stats {
    chars: usize,
    keystrokes: usize,
    accepts: usize,
    accepted_chars: usize,
    shown: usize,
    model_ms: Vec<f64>,
    /// The first model suggestion of each replay: it pays for prefilling the whole header.
    first_ms: Vec<f64>,
    prefills: Vec<f64>,
    sources: BTreeMap<&'static str, usize>,
}

impl Stats {
    fn add(&mut self, o: &Stats) {
        self.chars += o.chars;
        self.keystrokes += o.keystrokes;
        self.accepts += o.accepts;
        self.accepted_chars += o.accepted_chars;
        self.shown += o.shown;
        self.model_ms.extend(&o.model_ms);
        self.first_ms.extend(&o.first_ms);
        self.prefills.extend(&o.prefills);
        for (k, v) in &o.sources {
            *self.sources.entry(k).or_default() += v;
        }
    }

    fn print(&self, label: &str) {
        println!(
            "{label}: {} chars, keystrokes saved {:.1}%, chars/accept {:.2}, accepts {}, model p50 {:.0} ms p90 {:.0} ms, first p50 {:.0} ms p90 {:.0} ms, sources {:?}",
            self.chars,
            100.0 * (1.0 - self.keystrokes as f64 / self.chars.max(1) as f64),
            if self.accepts > 0 { self.accepted_chars as f64 / self.accepts as f64 } else { 0.0 },
            self.accepts,
            pct(&self.model_ms, 0.5),
            pct(&self.model_ms, 0.9),
            pct(&self.first_ms, 0.5),
            pct(&self.first_ms, 0.9),
            self.sources
        );
    }
}

/// `--n-ctx N`, or the app's context size.
fn n_ctx_arg() -> u32 {
    let args: Vec<String> = std::env::args().collect();
    args.iter()
        .position(|a| a == "--n-ctx")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(EngineConfig::default().n_ctx)
}

/// The engine configuration for the modes that drive the engine directly.
fn engine_config(model: &str) -> EngineConfig {
    EngineConfig {
        model_path: model.to_string(),
        n_ctx: n_ctx_arg(),
        n_gpu_layers: if std::env::args().any(|a| a == "--cpu") { 0 } else { EngineConfig::default().n_gpu_layers },
        ..EngineConfig::default()
    }
}

/// This process's resident size, physical footprint and peak footprint in bytes. The
/// footprint is what Activity Monitor shows as Memory: dirty memory, Metal buffers
/// included, but not the clean file-backed pages of the memory-mapped model, which the
/// resident size does count.
#[cfg(target_os = "macos")]
fn memory() -> (u64, u64, u64) {
    extern "C" {
        fn proc_pid_rusage(pid: i32, flavor: i32, buffer: *mut u64) -> i32;
    }
    // struct rusage_info_v4 (RUSAGE_INFO_V4 = 4) as 64-bit words after the 16-byte UUID:
    // ri_resident_size is word 8, ri_phys_footprint 9, ri_lifetime_max_phys_footprint 30.
    let mut words = [0u64; 64];
    // SAFETY: the buffer is larger than rusage_info_v4 (37 words).
    let ok = unsafe { proc_pid_rusage(std::process::id() as i32, 4, words.as_mut_ptr()) } == 0;
    if ok {
        (words[8], words[9], words[30])
    } else {
        (0, 0, 0)
    }
}

#[cfg(not(target_os = "macos"))]
fn memory() -> (u64, u64, u64) {
    (0, 0, 0)
}

fn mb(bytes: u64) -> f64 {
    bytes as f64 / (1024.0 * 1024.0)
}

struct Replayer {
    core: Core,
    rx: mpsc::Receiver<Event>,
    rev: u64,
    verbose: bool,
    think: Duration,
    spell: Option<SpellMap>,
}

/// Spell checker verdicts precomputed by tools/spell-map (the app's own Speller).
#[derive(serde::Deserialize, Default)]
struct SpellMap {
    fragments: std::collections::HashMap<String, String>,
    corrections: std::collections::HashMap<String, String>,
}

impl SpellMap {
    /// Fills the snapshot's spell fields the way Speller.annotate does.
    fn annotate(&self, s: &mut Snapshot) {
        let text = s.text_before.as_str();
        let frag_start = text.char_indices().rev().take_while(|(_, c)| words::is_word_char(*c)).last().map_or(text.len(), |(i, _)| i);
        let fragment = &text[frag_start..];
        if fragment.chars().count() >= 3 && fragment.chars().all(words::is_letter) {
            s.spell_fragment = self.fragments.get(fragment).cloned().unwrap_or_default();
        } else if fragment.is_empty() && text.ends_with(' ') {
            let trimmed = text.trim_end_matches(' ');
            let w_start = trimmed.char_indices().rev().take_while(|(_, c)| words::is_word_char(*c)).last().map_or(trimmed.len(), |(i, _)| i);
            let word = &trimmed[w_start..];
            if text.len() - trimmed.len() <= 2 && word.chars().count() >= 2 && word.chars().all(words::is_letter) {
                if let Some(fix) = self.corrections.get(word) {
                    s.spell_word = word.to_string();
                    s.spell_correction = fix.clone();
                }
            }
        }
    }
}

impl Replayer {
    fn new(model: &str, settings: Settings, verbose: bool) -> Self {
        let (tx, rx) = mpsc::channel::<Event>();
        let arg = |name: &str| {
            let args: Vec<String> = std::env::args().collect();
            args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
        };
        let core = Core::new(
            CoreConfig {
                model_path: model.to_string(),
                settings,
                backend: arg("--backend").unwrap_or_else(|| "local".into()),
                backend_url: arg("--url").unwrap_or_default(),
                backend_model: arg("--remote-model").unwrap_or_default(),
                // --cpu: no Metal offload (CI runners may have no usable GPU).
                n_gpu_layers: if std::env::args().any(|a| a == "--cpu") { 0 } else { CoreConfig::default().n_gpu_layers },
                n_ctx: n_ctx_arg(),
                ..CoreConfig::default()
            },
            Box::new(move |ev: &Event| {
                let _ = tx.send(ev.clone());
            }),
        );
        loop {
            match rx.recv_timeout(Duration::from_secs(60)).expect("engine status") {
                Event::Status { state: "ready", detail } => {
                    eprintln!("engine ready ({detail})");
                    break;
                }
                Event::Status { state: "error", detail } => panic!("engine error: {detail}"),
                _ => {}
            }
        }
        let spell = arg("--spell").map(|p| serde_json::from_str(&std::fs::read_to_string(p).expect("read spell map")).expect("spell map json"));
        Self { core, rx, rev: 0, verbose, think: Duration::ZERO, spell }
    }

    /// Types `text[prime..prime+max]` after `text[..prime]` in field `field_key`.
    fn replay(&mut self, base: &Snapshot, text: &str, prime: usize, max: usize) -> Stats {
        let chars: Vec<char> = text.chars().collect();
        let prime = prime.min(chars.len());
        let end = (prime + max).min(chars.len());
        let mut typed: String = chars[..prime].iter().collect();
        let spell = self.spell.take();
        let snap = |rev: u64, before: &str| {
            let mut s = Snapshot { revision: rev, text_before: before.to_string(), ..base.clone() };
            if let Some(m) = &spell {
                m.annotate(&mut s);
            }
            s
        };
        if prime > 0 {
            self.rev += 1;
            self.core.warm(snap(self.rev, &typed));
            std::thread::sleep(Duration::from_millis(800));
        }
        let mut st = Stats { chars: end - prime, ..Stats::default() };
        let mut i = prime;
        while i < end {
            self.rev += 1;
            let rev = self.rev;
            self.core.submit(snap(rev, &typed));
            let mut suggestion = String::new();
            // A detail other than a name is accepted whole: take it only if all of it is next.
            let mut whole = false;
            loop {
                match self.rx.recv_timeout(Duration::from_secs(5)) {
                    Ok(Event::Suggestion { revision, text, source, ms, prefilled, reason, replace, label, .. }) if revision == rev => {
                        if source == "pending" {
                            continue;
                        }
                        let key = if reason.as_deref() == Some("typo") { "policy:typo" } else { source };
                        *st.sources.entry(key).or_default() += 1;
                        if replace.is_some() {
                            // An emoji or a correction: the simulated user, who types clean
                            // text, never takes one.
                            break;
                        }
                        if source == "model" {
                            if st.model_ms.is_empty() {
                                st.first_ms.push(ms.unwrap_or(0.0));
                            }
                            st.model_ms.push(ms.unwrap_or(0.0));
                            st.prefills.push(prefilled.unwrap_or(0) as f64);
                        }
                        whole = source == "details" && label.as_deref() != Some("name");
                        suggestion = text;
                        break;
                    }
                    Ok(_) => continue,
                    Err(_) => break,
                }
            }
            if !suggestion.is_empty() {
                st.shown += 1;
            }
            if !self.think.is_zero() {
                std::thread::sleep(self.think);
            }
            let upcoming: String = chars[i..end].iter().collect();
            let next = if whole { suggestion.as_str() } else { words::take_words(&suggestion, 1) };
            if !next.is_empty() && upcoming.starts_with(next) {
                if let Some(insert) = self.core.accept(AcceptMode::NextWord).map(|a| a.insert) {
                    if self.verbose {
                        eprintln!("  TAB {:?}  (showing {:?})", insert, suggestion);
                    }
                    st.accepts += 1;
                    st.accepted_chars += insert.chars().count();
                    st.keystrokes += 1;
                    typed.push_str(&insert);
                    i += insert.chars().count();
                    continue;
                }
            }
            typed.push(chars[i]);
            i += 1;
            st.keystrokes += 1;
        }
        // Let a trailing prefetch finish so it doesn't bleed into the next document.
        std::thread::sleep(Duration::from_millis(150));
        while self.rx.try_recv().is_ok() {}
        self.spell = spell;
        st
    }
}

/// Types each document through two engines, one reusing its cache (prefix reuse, rollback,
/// snapshots) and one reset before every request, and compares their suggestions. Greedy
/// decoding makes them equal unless a rollback is wrong; batched and single-token decodes
/// can still differ in the last bits of a logit, so a dense model's mismatch rate is the
/// baseline to compare against.
fn check_cache(model: &str, docs: &[Doc], max_docs: usize, max_chars: usize, long: bool, fresh_batch: Option<u32>) {
    // Earlier writing and screen text for --long: the last documents of the corpus.
    let lead: String = if long {
        let all: Vec<&str> = docs.iter().rev().map(|d| d.text.as_str()).collect();
        let joined = all.join("\n\n");
        joined.chars().take(1400).collect::<String>() + "\n\n"
    } else {
        String::new()
    };
    // The keystroke sequence: (document index, text before the caret).
    let mut requests: Vec<(usize, String)> = Vec::new();
    for (di, d) in docs.iter().enumerate().take(max_docs) {
        let chars: Vec<char> = d.text.chars().take(max_chars).collect();
        let mut typed = lead.clone();
        let (mut i, mut step) = (0, 0);
        while i < chars.len() {
            step += 1;
            // Every 9th keystroke deletes up to 3 characters first (exercises rewinding).
            if step % 9 == 0 && typed.chars().count() > lead.chars().count() + 3 {
                for _ in 0..3 {
                    typed.pop();
                }
                i -= 3;
            } else {
                typed.push(chars[i]);
                i += 1;
            }
            if typed.trim().chars().count() >= 2 {
                requests.push((di, typed.clone()));
            }
        }
    }
    let prompts: Vec<_> = requests
        .iter()
        .map(|(di, typed)| {
            let app = app_of(&docs[*di].header);
            context::build(
                &ContextInput {
                    other_apps: "",
                    app_name: &app,
                    window_title: "",
                    url: "",
                    instructions: "",
                    writer: "",
                    screen_context: &lead,
                    examples: &[],
                    text_before: typed,
                },
                1600,
            )
        })
        .collect();
    // One engine at a time (a new one waits for the previous to be freed): the passes run in turn.
    let cfg = engine_config(model);
    let opts = GenOptions::default();
    let never = || false;
    let run = |reset: bool, n_batch: u32| {
        let mut e = Engine::load(&EngineConfig { n_batch, ..cfg.clone() }).expect("load model");
        if !reset {
            eprintln!("rollback: {:?}", e.rollback());
        }
        let out = prompts
            .iter()
            .map(|p| {
                if reset {
                    e.reset();
                }
                match e.complete(p, &opts, &never) {
                    Ok(c) => c,
                    Err(GenError::Cancelled) => unreachable!(),
                    Err(err) => panic!("complete: {err:?}"),
                }
            })
            .collect::<Vec<_>>();
        if !reset {
            eprintln!("snapshots held: {:.1} MB", e.snapshot_bytes() as f64 / 1e6);
        }
        out
    };
    let reuse = run(false, cfg.n_batch);
    let fresh = run(true, cfg.n_batch);
    if let Some(nb) = fresh_batch {
        let small = run(true, nb);
        let same = |a: &[foretype_core::engine::Completion], b: &[foretype_core::engine::Completion]| {
            100.0 * a.iter().zip(b).filter(|(x, y)| x.text == y.text).count() as f64 / a.len().max(1) as f64
        };
        println!(
            "fresh, batch {nb} vs batch {}: identical {:.1}%; reuse vs fresh batch {nb}: {:.1}%",
            cfg.n_batch,
            same(&fresh, &small),
            same(&reuse, &small)
        );
    }
    let mut same = 0;
    for (k, (a, b)) in reuse.iter().zip(&fresh).enumerate() {
        if a.text == b.text {
            same += 1;
        } else if std::env::args().any(|x| x == "-v") {
            let t = &requests[k].1;
            let tail: String = t.chars().rev().take(30).collect::<Vec<_>>().into_iter().rev().collect();
            eprintln!("  {}: ...{tail:?} | reuse {:?} | fresh {:?}", docs[requests[k].0].id, a.text, b.text);
        }
    }
    let prefilled: Vec<f64> = reuse.iter().map(|c| c.prefilled_tokens as f64).collect();
    let prompt_tokens: Vec<f64> = reuse.iter().map(|c| c.prompt_tokens as f64).collect();
    eprintln!("prompt tokens p50 {:.0}, max {:.0}", pct(&prompt_tokens, 0.5), pct(&prompt_tokens, 1.0));
    let ms_reuse: Vec<f64> = reuse.iter().map(|c| c.total_ms).collect();
    let ms_fresh: Vec<f64> = fresh.iter().map(|c| c.total_ms).collect();
    println!(
        "check-cache: {} requests, identical {same} ({:.1}%), prefilled p50 {:.0} p90 {:.0} tokens, reuse p50 {:.0} p90 {:.0} ms, fresh p50 {:.0} ms",
        reuse.len(),
        100.0 * same as f64 / reuse.len().max(1) as f64,
        pct(&prefilled, 0.5),
        pct(&prefilled, 0.9),
        pct(&ms_reuse, 0.5),
        pct(&ms_reuse, 0.9),
        pct(&ms_fresh, 0.5)
    );
}

fn mid_line_eval(model: &str, docs: &[Doc], typed: usize) {
    let mut e = Engine::load(&engine_config(model)).expect("load model");
    let opts = GenOptions { max_words: 3, ..GenOptions::default() };
    let never = || false;
    let (mut n, mut right, mut empty, mut ms) = (0usize, 0usize, 0usize, Vec::new());
    for d in docs {
        let app = app_of(&d.header);
        for line_start in std::iter::once(0).chain(d.text.match_indices('\n').map(|(i, _)| i + 1)) {
            let line_end = d.text[line_start..].find('\n').map_or(d.text.len(), |i| line_start + i);
            let line = &d.text[line_start..line_end];
            // Word starts with at least 3 words before them and 2 after on the line, every 5th.
            let starts: Vec<usize> = line.match_indices(' ').map(|(i, _)| i + 1).collect();
            for (k, &ws) in starts.iter().enumerate() {
                if k < 2 || k + 2 >= starts.len() || k % 5 != 0 {
                    continue;
                }
                let we = line[ws..].find(' ').map_or(line.len(), |i| ws + i);
                let word = &line[ws..we];
                if word.chars().count() <= typed || !word.chars().all(char::is_alphabetic) {
                    continue;
                }
                let typed_part: String = word.chars().take(typed).collect();
                let before = format!("{}{}", &d.text[..line_start + ws], typed_part);
                let mut prompt = context::build(
                    &ContextInput {
                        other_apps: "",
                        app_name: &app,
                        window_title: "",
                        url: "",
                        instructions: "",
                        writer: "",
                        screen_context: "",
                        examples: &[],
                        text_before: &before,
                    },
                    1600,
                );
                prompt.suffix = line[we..].chars().take(200).collect();
                let rest_of_word = &word[typed_part.len()..];
                let c = e.complete(&prompt, &opts, &never).expect("complete");
                n += 1;
                ms.push(c.total_ms);
                let first = c.text.split_whitespace().next().unwrap_or("").trim_matches(|ch: char| !ch.is_alphanumeric());
                if first == rest_of_word {
                    right += 1;
                }
                if c.text.trim().is_empty() {
                    empty += 1;
                }
                if std::env::args().any(|a| a == "-v") {
                    eprintln!("  {typed_part}|{rest_of_word} -> {:?}", c.text);
                }
            }
        }
    }
    let pct = |x: usize| 100.0 * x as f64 / n.max(1) as f64;
    println!(
        "mid-line-eval: {n} positions, {typed} letter(s) typed: word right {:.1}%, empty {:.1}%, p50 {:.0} ms",
        pct(right),
        pct(empty),
        crate::pct(&ms, 0.5)
    );
}

/// How many tokens the model's vocabulary spends on the corpus text: scripts it encodes
/// poorly (Devanagari in a mostly-Latin BPE) cost more decode steps per word.
fn token_cost(model: &str, docs: &[Doc]) {
    let e = Engine::load(&engine_config(model)).expect("load model");
    let bos = e.tokenize("").len();
    let (mut chars, mut words, mut tokens) = (0usize, 0usize, 0usize);
    for d in docs {
        chars += d.text.chars().count();
        words += words::count_words(&d.text);
        tokens += e.tokenize(&d.text).len() - bos;
    }
    println!(
        "token-cost: {} docs, {chars} chars, {words} words, {tokens} tokens: {:.2} chars/token, {:.2} tokens/word",
        docs.len(),
        chars as f64 / tokens.max(1) as f64,
        tokens as f64 / words.max(1) as f64
    );
    // The other-apps section's budget is counted with `others::estimate_tokens` before the
    // tokenizer is at hand: how far off is it on each document's other window?
    let (mut est, mut real, mut worst) = (0usize, 0usize, 0f64);
    for d in docs.iter().filter(|d| !d.context.is_empty()) {
        let mut o = OtherApps::default();
        o.set_passages(&[passage_of(d, true, 0.0)], unix_now());
        let section = o.select(&Query::new("", "", ""), 2048).to_string();
        let (e_n, r_n) = (others::estimate_tokens(&section), e.tokenize(&section).len() - bos);
        if std::env::args().any(|a| a == "-v") {
            eprintln!("  {}: estimated {e_n}, tokenizer {r_n}", d.id);
        }
        est += e_n;
        real += r_n;
        worst = worst.max(r_n as f64 / e_n.max(1) as f64);
    }
    if real > 0 {
        println!("other-apps sections: estimated {est} tokens, tokenizer {real} ({:.2} of the estimate, worst {worst:.2})", real as f64 / est.max(1) as f64);
    }
}

/// What a long screen section costs: the first suggestion with the whole prompt to prefill,
/// the keystrokes after it, and memory, at one context size (`--n-ctx`).
fn ctx_bench(model: &str, docs: &[Doc], fill: f64, type_chars: usize) {
    let (rss0, foot0, _) = memory();
    let cfg = engine_config(model);
    let mut e = Engine::load(&cfg).expect("load model");
    let (rss_load, foot_load, _) = memory();
    let target = ((cfg.n_ctx as f64 * fill) as usize).min(cfg.n_ctx as usize - 64 - type_chars - 8);
    // Other text to fill the window with: every document's context and text, repeated.
    let pool: String = docs.iter().map(|d| format!("{}\n{}\n", d.context, d.text)).collect::<Vec<_>>().join("\n");
    let opts = GenOptions::default();
    let never = || false;
    let (mut prompt_tokens, mut first, mut prefill, mut tok_s, mut keys, mut decode) =
        (Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new());
    // The first suggestion's generation phase: its time, its length, and how many the
    // generation deadline cut.
    let (mut gen, mut first_words, mut cut) = (Vec::new(), Vec::new(), 0usize);
    for (k, d) in docs.iter().enumerate() {
        let app = app_of(&d.header);
        let chars: Vec<char> = d.text.chars().collect();
        let start = 40.min(chars.len());
        let prompt_for = |filler: &str, typed: &str| {
            let mut p = context::build(
                &ContextInput {
                    other_apps: "",
                    app_name: &app,
                    window_title: "",
                    url: "",
                    instructions: "",
                    writer: "",
                    screen_context: "",
                    examples: &[],
                    text_before: typed,
                },
                1600,
            );
            // The header's screen section without its 1,500-character cap.
            let screen: Vec<&str> = [filler, d.context.as_str(), d.screen.as_str()]
                .iter()
                .flat_map(|t| t.lines())
                .map(str::trim)
                .filter(|l| !l.is_empty() && !l.starts_with('['))
                .collect();
            p.prefix = format!("[Text visible on screen]\n{}\n[End of screen text]\n\n{}", screen.join("\n"), p.prefix);
            p
        };
        // Filler length for `target` tokens, from a different place in the pool per document.
        let rotated: String = pool.chars().cycle().skip(k * 997).take(cfg.n_ctx as usize * 8).collect();
        let typed0: String = chars[..start].iter().collect();
        let count = |n: usize| {
            let filler: String = rotated.chars().take(n).collect();
            e.tokenize(&prompt_for(&filler, &typed0).prefix).len()
        };
        let base = count(0);
        let want = target.saturating_sub(base);
        let mut n = want * 4;
        for _ in 0..8 {
            let t = count(n).saturating_sub(base);
            if t <= want && t + 24 >= want {
                break;
            }
            n = (n as f64 * want as f64 / t.max(1) as f64 * 0.995) as usize;
        }
        let filler: String = rotated.chars().take(n).collect();
        e.reset();
        let c = e.complete(&prompt_for(&filler, &typed0), &opts, &never).expect("complete");
        prompt_tokens.push(c.prompt_tokens as f64);
        first.push(c.total_ms);
        prefill.push(c.prefill_ms);
        tok_s.push(c.prefilled_tokens as f64 / (c.prefill_ms / 1000.0).max(1e-6));
        if c.generated_tokens > 0 {
            decode.push((c.total_ms - c.prefill_ms) / c.generated_tokens as f64);
        }
        gen.push(c.total_ms - c.prefill_ms);
        first_words.push(words::count_words(&c.text) as f64);
        cut += usize::from(c.stop == "deadline");
        for i in start..(start + type_chars).min(chars.len()) {
            let typed: String = chars[..=i].iter().collect();
            let c = e.complete(&prompt_for(&filler, &typed), &opts, &never).expect("complete");
            keys.push(c.total_ms);
        }
    }
    let (rss_end, foot_end, peak) = memory();
    println!(
        "ctx-bench n_ctx {}: {} docs, prompt p50 {:.0} tokens, first suggestion p50 {:.0} ms p90 {:.0} ms, prefill p50 {:.0} ms p90 {:.0} ms ({:.0} tok/s), generation p50 {:.0} ms p90 {:.0} ms, {:.1} words p50, {} cut by the deadline, keystrokes p50 {:.0} ms p90 {:.0} ms, decode {:.1} ms/token",
        cfg.n_ctx,
        docs.len(),
        pct(&prompt_tokens, 0.5),
        pct(&first, 0.5),
        pct(&first, 0.9),
        pct(&prefill, 0.5),
        pct(&prefill, 0.9),
        pct(&tok_s, 0.5),
        pct(&gen, 0.5),
        pct(&gen, 0.9),
        pct(&first_words, 0.5),
        cut,
        pct(&keys, 0.5),
        pct(&keys, 0.9),
        pct(&decode, 0.5)
    );
    println!(
        "memory n_ctx {}: before load resident {:.0} MB footprint {:.0} MB; loaded resident {:.0} MB footprint {:.0} MB; end resident {:.0} MB footprint {:.0} MB; peak footprint {:.0} MB",
        cfg.n_ctx,
        mb(rss0),
        mb(foot0),
        mb(rss_load),
        mb(foot_load),
        mb(rss_end),
        mb(foot_end),
        mb(peak)
    );
}

/// A core like the app's and its events; its worker starts loading the model at once.
fn new_core(model: &str, n_ctx: u32) -> (Core, mpsc::Receiver<Event>) {
    let (tx, rx) = mpsc::channel::<Event>();
    let core = Core::new(
        CoreConfig { model_path: model.to_string(), n_ctx, ..CoreConfig::default() },
        Box::new(move |ev: &Event| {
            let _ = tx.send(ev.clone());
        }),
    );
    (core, rx)
}

/// Milliseconds until `ready`, or the error status.
fn wait_ready(rx: &mpsc::Receiver<Event>, since: Instant) -> Result<f64, String> {
    loop {
        match rx.recv_timeout(Duration::from_secs(60)) {
            Ok(Event::Status { state: "ready", .. }) => return Ok(since.elapsed().as_secs_f64() * 1000.0),
            Ok(Event::Status { state: "error", detail }) => return Err(detail),
            Ok(_) => continue,
            Err(_) => return Err("no status in 60 s".into()),
        }
    }
}

/// Submits one snapshot and waits for the model's answer: Ok(text) or the error.
fn ask(core: &Core, rx: &mpsc::Receiver<Event>, revision: u64) -> Result<String, String> {
    core.submit(Snapshot {
        revision,
        field_key: 1,
        bundle_id: "com.apple.mail".into(),
        app_name: "Mail".into(),
        role: "AXTextArea".into(),
        text_before: "Hi Sam,\n\nThanks for the update on the project. I will send you the".into(),
        ..Snapshot::default()
    });
    loop {
        match rx.recv_timeout(Duration::from_secs(30)) {
            Ok(Event::Suggestion { revision: r, text, source: "model", .. }) if r == revision => return Ok(text),
            Ok(Event::Suggestion { revision: r, source: "error", reason, .. }) if r == revision => return Err(reason.unwrap_or_default()),
            Ok(Event::Status { state: "error", detail }) => return Err(detail),
            Ok(_) => continue,
            Err(_) => return Err("no suggestion in 30 s".into()),
        }
    }
}

/// `--restart-check`: the app's engine swap (`startEngine` then `Controller.replaceEngine`),
/// twice in one process: the new core starts loading while the old one holds a loaded model
/// that has just answered, and the old one is freed on another thread.
fn restart_check(model: &str) -> bool {
    let t = Instant::now();
    let (mut core, mut rx) = new_core(model, 2048);
    let ready = wait_ready(&rx, t);
    let answer = ask(&core, &rx, 1);
    println!("restart-check: first engine ready {ready:?}, suggestion {answer:?}");
    let mut ok = ready.is_ok() && answer.is_ok();
    for (round, n_ctx) in [(1u64, 4096u32), (2, 2048)] {
        let t = Instant::now();
        let (next, next_rx) = new_core(model, n_ctx);
        let old = std::mem::replace(&mut core, next);
        rx = next_rx;
        let freeing = std::thread::spawn(move || drop(old));
        let ready = wait_ready(&rx, t);
        freeing.join().expect("free the old core");
        let answer = ask(&core, &rx, 10 + round);
        println!("restart-check: swap {round} (n_ctx {n_ctx}): ready {ready:?}, suggestion {answer:?}");
        ok &= ready.is_ok() && answer.is_ok();
    }
    println!("{}", if ok { "restart-check passed" } else { "restart-check FAILED" });
    ok
}

#[derive(serde::Deserialize, Clone)]
struct Doc {
    id: String,
    #[serde(default)]
    header: String,
    text: String,
    /// Text of another app's window the writer is looking at (eval/corpus-multiwindow.jsonl).
    #[serde(default)]
    context: String,
    /// Text of the focused window around the field.
    #[serde(default)]
    screen: String,
    /// The other window's app and title.
    #[serde(default)]
    context_app: String,
    #[serde(default)]
    context_title: String,
}

fn unix_now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

/// The other window of a document as the shell would send it.
fn passage_of(d: &Doc, visible: bool, age_s: f64) -> Passage {
    let app = if d.context_app.is_empty() { "Other app".to_string() } else { d.context_app.clone() };
    Passage {
        bundle_id: format!("corpus.{}", app.to_lowercase().replace(' ', "-")),
        app,
        window_title: d.context_title.clone(),
        text: d.context.clone(),
        captured_at: unix_now() - age_s,
        visible,
        ..Passage::default()
    }
}

/// Bundle IDs of the corpus's named apps, for per-app instructions.
const CORPUS_APPS: &[(&str, &str)] = &[
    ("Mail", "com.apple.mail"),
    ("Slack", "com.tinyspeck.slackmacgap"),
    ("Teams", "com.microsoft.teams2"),
    ("Messages", "com.apple.MobileSMS"),
    ("Notes", "com.apple.Notes"),
    ("a document", "com.apple.TextEdit"),
];

/// Settings carrying `notes`: the corpus snapshots use app names as bundle IDs, so each
/// app's note is also filed under its name.
fn with_notes(settings: Settings, notes: &DefaultInstructions) -> Settings {
    let mut apps: std::collections::HashMap<String, String> = notes.apps.clone().into_iter().collect();
    for (name, bundle) in CORPUS_APPS {
        if let Some(note) = notes.apps.get(*bundle) {
            apps.insert(name.to_string(), note.clone());
        }
    }
    Settings { instructions: notes.global.clone(), app_instructions: apps, ..settings }
}

/// "An email written in Mail:" -> "Mail".
fn app_of(header: &str) -> String {
    header
        .split(" in ")
        .last()
        .map(|s| s.trim().trim_end_matches(':').trim().to_string())
        .filter(|s| !s.is_empty() && s.len() < 40)
        .unwrap_or_else(|| "Notes".into())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("see the usage at the top of ft-replay.rs");
        std::process::exit(2);
    }
    let flag = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let has = |name: &str| args.iter().any(|a| a == name);
    let model = args[1].clone();
    if has("--restart-check") {
        std::process::exit(if restart_check(&model) { 0 } else { 1 });
    }
    let length_words: usize = flag("--words").and_then(|s| s.parse().ok()).unwrap_or(4);
    let beam_width: usize = flag("--beam").and_then(|s| s.parse().ok()).unwrap_or(1);
    let mut settings = Settings { length_words, beam_width, prefetch: !has("--no-prefetch"), ..Settings::default() };
    let notes = match flag("--instructions") {
        Some(p) => Some(instructions::parse(&std::fs::read_to_string(p).expect("read instructions")).expect("instructions json")),
        None => has("--default-instructions").then(instructions::defaults),
    };
    if let Some(n) = &notes {
        settings = with_notes(settings, n);
    }

    if let Some(corpus) = flag("--corpus") {
        let only = flag("--only").unwrap_or_default();
        let docs: Vec<Doc> = std::fs::read_to_string(&corpus)
            .expect("read corpus")
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| serde_json::from_str(l).expect("corpus line"))
            .filter(|d: &Doc| d.id.starts_with(&only))
            .collect();
        if has("--mid-line-eval") {
            let typed = flag("--typed").and_then(|s| s.parse().ok()).unwrap_or(1);
            return mid_line_eval(&model, &docs, typed);
        }
        if has("--token-cost") {
            return token_cost(&model, &docs);
        }
        if has("--ctx-bench") {
            let fill = flag("--fill").and_then(|s| s.parse().ok()).unwrap_or(0.9);
            let type_chars = flag("--type").and_then(|s| s.parse().ok()).unwrap_or(40);
            return ctx_bench(&model, &docs, fill, type_chars);
        }
        if has("--check-cache") {
            let n_docs = flag("--docs").and_then(|s| s.parse().ok()).unwrap_or(6);
            let n_chars = flag("--chars").and_then(|s| s.parse().ok()).unwrap_or(250);
            let fresh_batch = flag("--fresh-batch").and_then(|s| s.parse().ok());
            return check_cache(&model, &docs, n_docs, n_chars, has("--long"), fresh_batch);
        }
        let mut r = Replayer::new(&model, settings.clone(), has("-v"));
        r.think = Duration::from_millis(flag("--think").and_then(|s| s.parse().ok()).unwrap_or(0));
        let context_mode = flag("--context-mode").unwrap_or_else(|| "none".into());
        let screen_for = |d: &Doc| match context_mode.as_str() {
            "none" | "other" => String::new(),
            "focused" | "both" => d.screen.clone(),
            "other-screen" => d.context.clone(),
            "both-screen" => format!("{}\n\n{}", d.context, d.screen),
            m => panic!("--context-mode {m}: expected none, focused, other, both, other-screen or both-screen"),
        };
        let distractors: usize = flag("--distractors").and_then(|s| s.parse().ok()).unwrap_or(0);
        let pool_for = |i: usize, d: &Doc| -> Vec<Passage> {
            if !matches!(context_mode.as_str(), "other" | "both") || d.context.is_empty() {
                return Vec::new();
            }
            let mut pool: Vec<Passage> = (1..=distractors)
                .map(|k| &docs[(i + k) % docs.len()])
                .filter(|o| o.id != d.id && !o.context.is_empty())
                .enumerate()
                .map(|(k, o)| passage_of(o, false, 120.0 * (k + 1) as f64))
                .collect();
            pool.push(if has("--other-recent") { passage_of(d, false, 60.0) } else { passage_of(d, true, 0.0) });
            pool
        };
        if let Some(n) = flag("--other-tokens").and_then(|s| s.parse().ok()) {
            settings.other_apps_tokens = n;
            r.core.configure(settings.clone());
        }
        let snap_for = |i: usize, d: &Doc| Snapshot {
            field_key: 1000 + i as u64,
            bundle_id: app_of(&d.header),
            app_name: app_of(&d.header),
            role: "AXTextArea".into(),
            screen_context: screen_for(d),
            ..Snapshot::default()
        };
        if has("--personal-loo") {
            let strength: u8 = flag("--strength").and_then(|s| s.parse().ok()).unwrap_or(1);
            let (mut off, mut on) = (Stats::default(), Stats::default());
            for (i, d) in docs.iter().enumerate() {
                let base = snap_for(i, d);
                r.core.configure(Settings { personalize: false, ..settings.clone() });
                let a = r.replay(&Snapshot { field_key: 5000 + i as u64, ..base.clone() }, &d.text, 0, usize::MAX);
                r.core.clear_history().unwrap();
                let others: Vec<(String, String)> = docs
                    .iter()
                    .enumerate()
                    .filter(|(j, _)| *j != i)
                    .map(|(_, o)| (app_of(&o.header), o.text.clone()))
                    .collect();
                r.core.import_history(others).unwrap();
                r.core.configure(Settings {
                    personalize: true,
                    personalize_strength: strength,
                    personal_examples: !has("--no-examples"),
                    ..settings.clone()
                });
                let b = r.replay(&Snapshot { field_key: 9000 + i as u64, ..base }, &d.text, 0, usize::MAX);
                println!(
                    "{:<14} off {:>5.1}%  on {:>5.1}%",
                    d.id,
                    100.0 * (1.0 - a.keystrokes as f64 / a.chars.max(1) as f64),
                    100.0 * (1.0 - b.keystrokes as f64 / b.chars.max(1) as f64)
                );
                off.add(&a);
                on.add(&b);
            }
            off.print("personalization off");
            on.print(&format!("personalization on (strength {strength})"));
            return;
        }
        // --details: the user's details for each document, by id ("*" for the rest).
        let details: Option<std::collections::HashMap<String, UserDetails>> = flag("--details")
            .map(|p| serde_json::from_str(&std::fs::read_to_string(p).expect("read details")).expect("details json"));
        let mut total = Stats::default();
        let t = Instant::now();
        for (i, d) in docs.iter().enumerate() {
            if let Some(all) = &details {
                let mine = all.get(&d.id).or_else(|| all.get("*")).cloned().unwrap_or_default();
                r.core.set_details(UserDetails { in_prompt: has("--details-in-prompt"), ..mine });
            }
            r.core.set_context(pool_for(i, d));
            let changes = r.core.context_changes();
            let st = r.replay(&snap_for(i, d), &d.text, 0, usize::MAX);
            if r.verbose {
                eprintln!("{}: section changed {} times", d.id, r.core.context_changes() - changes);
            }
            total.add(&st);
        }
        total.print(&format!("{} docs in {:.0}s", docs.len(), t.elapsed().as_secs_f64()));
        if matches!(context_mode.as_str(), "other" | "both") {
            println!("other-apps section: changed {} times in {} docs", r.core.context_changes(), docs.len());
        }
        return;
    }

    let prime: usize = flag("--prime").and_then(|s| s.parse().ok()).unwrap_or(400);
    let max_chars: usize = flag("--chars").and_then(|s| s.parse().ok()).unwrap_or(600);
    let app = flag("--app").unwrap_or_else(|| "Mail".into());
    let screen = flag("--screen").map(|p| std::fs::read_to_string(p).expect("read screen file")).unwrap_or_default();
    let text = std::fs::read_to_string(&args[2]).expect("read text file");
    let mut r = Replayer::new(&model, settings, has("-v"));
    let base = Snapshot {
        field_key: 1,
        bundle_id: "com.apple.mail".into(),
        app_name: app,
        window_title: "Re: planning".into(),
        role: "AXTextArea".into(),
        screen_context: screen,
        ..Snapshot::default()
    };
    let t = Instant::now();
    let st = r.replay(&base, &text, prime, max_chars);
    st.print(&format!("replayed in {:.1}s", t.elapsed().as_secs_f64()));
}
