//! Replays typing through the core, the way a shell would, and reports latency and how
//! much typing the suggestions would have saved.
//!
//! The simulated user types one character at a time and presses Tab (accept next word)
//! whenever the visible suggestion's next word is exactly what they were about to type.
//!
//! usage:
//!   ft-replay MODEL TEXT_FILE [--prime N] [--chars N] [--words N] [--app NAME] [--screen FILE] [-v]
//!   ft-replay MODEL --corpus CORPUS.jsonl [--words N] [--no-prefetch] [--only PREFIX] [--think MS]
//!       --think: simulated reaction time between seeing a suggestion and the next key
//!       (default 0: an instant user, which never lets a prefetch finish)
//!   ft-replay MODEL --corpus CORPUS.jsonl --personal-loo [--only sw-] [--strength 0|1|2] [--no-examples]
//!       leave-one-out personalization: each document is replayed with the other selected
//!       documents as the user's writing history, with and without personalization.

use std::collections::BTreeMap;
use std::sync::mpsc;
use std::time::{Duration, Instant};

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
        self.prefills.extend(&o.prefills);
        for (k, v) in &o.sources {
            *self.sources.entry(k).or_default() += v;
        }
    }

    fn print(&self, label: &str) {
        println!(
            "{label}: {} chars, keystrokes saved {:.1}%, chars/accept {:.2}, accepts {}, model p50 {:.0} ms p90 {:.0} ms, sources {:?}",
            self.chars,
            100.0 * (1.0 - self.keystrokes as f64 / self.chars.max(1) as f64),
            if self.accepts > 0 { self.accepted_chars as f64 / self.accepts as f64 } else { 0.0 },
            self.accepts,
            pct(&self.model_ms, 0.5),
            pct(&self.model_ms, 0.9),
            self.sources
        );
    }
}

struct Replayer {
    core: Core,
    rx: mpsc::Receiver<Event>,
    rev: u64,
    verbose: bool,
    think: Duration,
}

impl Replayer {
    fn new(model: &str, settings: Settings, verbose: bool) -> Self {
        let (tx, rx) = mpsc::channel::<Event>();
        let core = Core::new(
            CoreConfig { model_path: model.to_string(), settings, ..CoreConfig::default() },
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
        Self { core, rx, rev: 0, verbose, think: Duration::ZERO }
    }

    /// Types `text[prime..prime+max]` after `text[..prime]` in field `field_key`.
    fn replay(&mut self, base: &Snapshot, text: &str, prime: usize, max: usize) -> Stats {
        let chars: Vec<char> = text.chars().collect();
        let prime = prime.min(chars.len());
        let end = (prime + max).min(chars.len());
        let mut typed: String = chars[..prime].iter().collect();
        let snap = |rev: u64, before: &str| Snapshot { revision: rev, text_before: before.to_string(), ..base.clone() };
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
            loop {
                match self.rx.recv_timeout(Duration::from_secs(5)) {
                    Ok(Event::Suggestion { revision, text, source, ms, prefilled, .. }) if revision == rev => {
                        if source == "pending" {
                            continue;
                        }
                        *st.sources.entry(source).or_default() += 1;
                        if source == "model" {
                            st.model_ms.push(ms.unwrap_or(0.0));
                            st.prefills.push(prefilled.unwrap_or(0) as f64);
                        }
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
            let next = words::take_words(&suggestion, 1);
            if !next.is_empty() && upcoming.starts_with(next) {
                if let Some((insert, _)) = self.core.accept(AcceptMode::NextWord) {
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
        st
    }
}

#[derive(serde::Deserialize, Clone)]
struct Doc {
    id: String,
    #[serde(default)]
    header: String,
    text: String,
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
    let length_words: usize = flag("--words").and_then(|s| s.parse().ok()).unwrap_or(4);
    let settings = Settings { length_words, prefetch: !has("--no-prefetch"), ..Settings::default() };

    if let Some(corpus) = flag("--corpus") {
        let only = flag("--only").unwrap_or_default();
        let docs: Vec<Doc> = std::fs::read_to_string(&corpus)
            .expect("read corpus")
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| serde_json::from_str(l).expect("corpus line"))
            .filter(|d: &Doc| d.id.starts_with(&only))
            .collect();
        let mut r = Replayer::new(&model, settings.clone(), has("-v"));
        r.think = Duration::from_millis(flag("--think").and_then(|s| s.parse().ok()).unwrap_or(0));
        let snap_for = |i: usize, d: &Doc| Snapshot {
            field_key: 1000 + i as u64,
            bundle_id: app_of(&d.header),
            app_name: app_of(&d.header),
            role: "AXTextArea".into(),
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
        let mut total = Stats::default();
        let t = Instant::now();
        for (i, d) in docs.iter().enumerate() {
            total.add(&r.replay(&snap_for(i, d), &d.text, 0, usize::MAX));
        }
        total.print(&format!("{} docs in {:.0}s", docs.len(), t.elapsed().as_secs_f64()));
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
