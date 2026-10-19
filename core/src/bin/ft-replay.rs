//! Replays typing of a text file through the core, the way a shell would, and reports
//! latency and how much typing the suggestions would have saved.
//!
//! The simulated user types one character at a time and presses Tab (accept next word)
//! whenever the visible suggestion's next word is exactly what they were about to type.
//!
//! usage: ft-replay MODEL.gguf TEXT_FILE [--prime N] [--chars N] [--words N] [--app NAME]
//!                  [--screen FILE] [-v]

use std::sync::mpsc;
use std::time::{Duration, Instant};

use foretype_core::session::AcceptMode;
use foretype_core::{words, Core, CoreConfig, Event, Settings, Snapshot};

fn pct(v: &mut [f64], p: f64) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[((v.len() - 1) as f64 * p).round() as usize]
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: ft-replay MODEL.gguf TEXT_FILE [--prime N] [--chars N] [--words N] [--app NAME] [-v]");
        std::process::exit(2);
    }
    let flag = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let verbose = args.iter().any(|a| a == "-v");
    let prime: usize = flag("--prime").and_then(|s| s.parse().ok()).unwrap_or(400);
    let max_chars: usize = flag("--chars").and_then(|s| s.parse().ok()).unwrap_or(600);
    let length_words: usize = flag("--words").and_then(|s| s.parse().ok()).unwrap_or(4);
    let app = flag("--app").unwrap_or_else(|| "Mail".into());
    let screen = flag("--screen").map(|p| std::fs::read_to_string(p).expect("read screen file")).unwrap_or_default();

    let text = std::fs::read_to_string(&args[2]).expect("read text file");
    let chars: Vec<char> = text.chars().collect();
    let prime = prime.min(chars.len());
    let end = (prime + max_chars).min(chars.len());

    let (tx, rx) = mpsc::channel::<Event>();
    let sink = Box::new(move |ev: &Event| {
        let _ = tx.send(ev.clone());
    });
    let core = Core::new(
        CoreConfig {
            model_path: args[1].clone(),
            settings: Settings { length_words, ..Settings::default() },
            ..CoreConfig::default()
        },
        sink,
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

    let mut rev = 0u64;
    let snapshot = |rev: u64, before: &str| Snapshot {
        revision: rev,
        field_key: 1,
        bundle_id: "com.apple.mail".into(),
        app_name: app.clone(),
        window_title: "Re: planning".into(),
        role: "AXTextArea".into(),
        text_before: before.to_string(),
        screen_context: screen.clone(),
        ..Snapshot::default()
    };

    let mut typed: String = chars[..prime].iter().collect();
    rev += 1;
    core.warm(snapshot(rev, &typed));
    std::thread::sleep(Duration::from_millis(1500));

    let mut i = prime;
    let (mut keystrokes, mut accepts, mut accepted_chars, mut shown) = (0usize, 0usize, 0usize, 0usize);
    let mut model_ms: Vec<f64> = Vec::new();
    let mut prefills: Vec<f64> = Vec::new();
    let mut sources = std::collections::BTreeMap::<&'static str, usize>::new();
    let t_all = Instant::now();

    while i < end {
        rev += 1;
        core.submit(snapshot(rev, &typed));
        // Wait for this revision's final word: a non-pending suggestion event.
        let mut suggestion = String::new();
        loop {
            match rx.recv_timeout(Duration::from_secs(5)) {
                Ok(Event::Suggestion { revision, text, source, ms, prefilled, .. }) if revision == rev => {
                    if source == "pending" {
                        continue;
                    }
                    *sources.entry(source).or_default() += 1;
                    if source == "model" {
                        model_ms.push(ms.unwrap_or(0.0));
                        prefills.push(prefilled.unwrap_or(0) as f64);
                    }
                    suggestion = text;
                    break;
                }
                Ok(_) => continue,
                Err(_) => break,
            }
        }
        if !suggestion.is_empty() {
            shown += 1;
        }
        let upcoming: String = chars[i..end].iter().collect();
        let next = words::take_words(&suggestion, 1);
        if !next.is_empty() && upcoming.starts_with(next) {
            if let Some((insert, _)) = core.accept(AcceptMode::NextWord) {
                if verbose {
                    eprintln!("  TAB {:?}  (showing {:?})", insert, suggestion);
                }
                accepts += 1;
                accepted_chars += insert.chars().count();
                keystrokes += 1;
                typed.push_str(&insert);
                i += insert.chars().count();
                continue;
            }
        }
        typed.push(chars[i]);
        i += 1;
        keystrokes += 1;
    }

    let total = end - prime;
    println!("replayed {total} chars in {:.1}s", t_all.elapsed().as_secs_f64());
    println!("keystrokes: {keystrokes} ({:.1}% saved)", 100.0 * (1.0 - keystrokes as f64 / total as f64));
    println!(
        "accepts: {accepts}, chars per accept: {:.2}, suggestions shown on {:.0}% of keystrokes",
        if accepts > 0 { accepted_chars as f64 / accepts as f64 } else { 0.0 },
        100.0 * shown as f64 / keystrokes.max(1) as f64
    );
    println!("sources: {sources:?}");
    let n = model_ms.len();
    println!(
        "model suggestions: {n}, latency p50 {:.1} ms, p90 {:.1} ms, max {:.1} ms; prefill tokens p50 {:.0}, max {:.0}",
        pct(&mut model_ms.clone(), 0.5),
        pct(&mut model_ms.clone(), 0.9),
        pct(&mut model_ms, 1.0),
        pct(&mut prefills.clone(), 0.5),
        pct(&mut prefills, 1.0)
    );
}
