//! The custom instructions: the notes a fresh install starts with (one for every app, plus
//! one for each kind of app: email, chat, notes, ...), the websites a note can be kept for,
//! and how the notes for one field are joined into the prompt's `[Writer's notes: …]`.
//! Shells show the defaults in their instructions editor as if the user had written them, so
//! the user can change or clear any of them; a note the user hasn't touched follows the
//! defaults of the installed version.

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};

pub const DEFAULTS: &str = include_str!("../data/default-instructions.json");

/// The notes `ft_default_instructions` hands the shells.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
pub struct DefaultInstructions {
    /// For every app.
    pub global: String,
    /// Added after `global` in the app with this bundle ID.
    pub apps: BTreeMap<String, String>,
}

#[derive(Deserialize)]
struct Group {
    note: String,
    apps: Vec<String>,
}

#[derive(Deserialize)]
struct File {
    global: String,
    groups: Vec<Group>,
}

/// Reads the `default-instructions.json` format: a global note and groups of apps that share
/// one note.
pub fn parse(json: &str) -> Result<DefaultInstructions, String> {
    let file: File = serde_json::from_str(json).map_err(|e| e.to_string())?;
    let mut apps = BTreeMap::new();
    for g in file.groups {
        for app in g.apps {
            if apps.insert(app.clone(), g.note.trim().to_string()).is_some() {
                return Err(format!("{app} is in two groups"));
            }
        }
    }
    Ok(DefaultInstructions { global: file.global.trim().to_string(), apps })
}

pub fn defaults() -> DefaultInstructions {
    parse(DEFAULTS).expect("bundled default instructions")
}

/// Most characters the joined notes take in the prompt header.
pub const NOTES_CAP: usize = 400;

/// Joins the notes for one field, least specific first (all apps, the app, the website), in
/// at most `cap` characters. When they don't fit, the earlier ones give way: the last note is
/// kept whole (only its end is cut when it alone is too long) and the one before it is cut
/// short at a word, ending in "…", or left out with any before it.
pub fn assemble(notes: &[&str], cap: usize) -> String {
    let mut kept: Vec<String> = Vec::new();
    let mut room = cap;
    for note in notes.iter().rev().map(|n| n.trim()).filter(|n| !n.is_empty()) {
        let sep = usize::from(!kept.is_empty());
        if room <= sep {
            break;
        }
        let n = note.chars().count();
        if n + sep <= room {
            kept.push(note.to_string());
            room -= n + sep;
            continue;
        }
        let cut = cut_at_word(note, room - sep);
        if !cut.is_empty() {
            kept.push(cut);
        }
        break;
    }
    kept.reverse();
    kept.join(" ")
}

/// The start of `text` in at most `max` characters, ending in "…": cut at a space when there
/// is one (text without spaces, such as Japanese, is cut anywhere); empty when nothing fits.
fn cut_at_word(text: &str, max: usize) -> String {
    if max < 2 {
        return String::new();
    }
    let end = text.char_indices().nth(max - 1).map_or(text.len(), |(i, _)| i);
    let mut head = &text[..end];
    // Back to the last space unless the cut fell between two words already.
    if !text[end..].starts_with(char::is_whitespace) {
        if let Some(i) = head.rfind(char::is_whitespace) {
            head = &head[..i];
        }
    }
    let head = head.trim_end_matches(|c: char| c.is_whitespace() || matches!(c, ',' | ';' | ':' | '-' | '\u{2014}'));
    if head.is_empty() {
        String::new()
    } else {
        format!("{head}\u{2026}")
    }
}

/// A web page's site, as the instructions editor offers it: `host` ("mail.google.com",
/// lowercase, no port, no leading "www.") and `domain`, the part a whole organisation shares
/// ("google.com"; the host itself when it has no shorter one).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Site {
    pub host: String,
    pub domain: String,
}

/// The site of an http(s) URL (or a bare host); None for other pages (file:, about:, ...).
pub fn site_of(url: &str) -> Option<Site> {
    let host = host_of(url);
    if host.is_empty() {
        return None;
    }
    let domain = base_domain(&host).to_string();
    Some(Site { host, domain })
}

/// The host of an http(s) URL or a bare host: lowercase, without user, port, trailing dot or
/// leading "www."; empty for other schemes.
pub fn host_of(url: &str) -> String {
    let url = url.trim();
    let rest = match url.split_once("://") {
        Some((scheme, rest)) if scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https") => rest,
        Some(_) => return String::new(),
        // "about:blank", "mailto:…": a scheme, not a host with a port.
        None => match url.split_once(':') {
            Some((scheme, after)) if scheme.chars().all(|c| c.is_ascii_alphabetic()) && !after.starts_with(|c: char| c.is_ascii_digit()) => {
                return String::new()
            }
            _ => url,
        },
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let hostport = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    let host = if hostport.starts_with('[') {
        hostport.split_inclusive(']').next().unwrap_or("")
    } else {
        hostport.split(':').next().unwrap_or("")
    };
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    match host.strip_prefix("www.") {
        Some(rest) if rest.contains('.') => rest.to_string(),
        _ => host,
    }
}

/// Second-level labels under a country code that are shared by many organisations
/// ("co.uk", "com.au", "gov.in"): the domain then takes one more label.
const SHARED_SECOND_LEVEL: &[&str] =
    &["ac", "co", "com", "edu", "gen", "go", "gob", "gov", "govt", "ind", "net", "ne", "nic", "nhs", "or", "org", "ltd", "plc", "sch"];

/// Hosting services whose every subdomain is someone else's site: a page there has no domain
/// shorter than its host.
const SHARED_HOSTS: &[&str] = &[
    "github.io", "gitlab.io", "pages.dev", "vercel.app", "netlify.app", "herokuapp.com", "web.app", "firebaseapp.com",
    "blogspot.com", "wordpress.com", "notion.site",
];

/// The domain a host's organisation shares: its last two labels ("google.com" for
/// "mail.google.com"), three under a shared country second level ("bbc.co.uk") or a hosting
/// service ("me.github.io"); an IP address is its own.
pub fn base_domain(host: &str) -> &str {
    if host.starts_with('[') || host.chars().all(|c| c.is_ascii_digit() || c == '.') {
        return host;
    }
    let labels: Vec<&str> = host.split('.').collect();
    let n = labels.len();
    let keep = if let Some(h) = SHARED_HOSTS.iter().find(|h| host == **h || host.ends_with(&format!(".{h}"))) {
        h.split('.').count() + 1
    } else if n >= 3 && labels[n - 1].len() == 2 && SHARED_SECOND_LEVEL.contains(&labels[n - 2]) {
        3
    } else {
        2
    };
    if keep >= n {
        return host;
    }
    let start: usize = labels[..n - keep].iter().map(|l| l.len() + 1).sum();
    &host[start..]
}

/// Whether a website note's key applies on `host` (`host_of`): "mail.google.com" on that host
/// only, "*.google.com" on google.com and every host under it.
pub fn site_matches(key: &str, host: &str) -> bool {
    if host.is_empty() {
        return false;
    }
    match key.strip_prefix("*.") {
        Some(domain) => {
            let domain = host_of(domain);
            !domain.is_empty() && (host == domain || host.strip_suffix(domain.as_str()).is_some_and(|h| h.ends_with('.')))
        }
        None => host_of(key) == host,
    }
}

/// The notes kept for the website at `url`: every key that applies there, the broadest first
/// (so the most specific comes last, after the app's note).
pub fn site_notes<'a>(sites: &'a HashMap<String, String>, url: &str) -> Vec<&'a str> {
    let host = host_of(url);
    let mut found: Vec<(usize, &str, &str)> = sites
        .iter()
        .filter(|(key, note)| !note.trim().is_empty() && site_matches(key, &host))
        .map(|(key, note)| {
            // An exact host outranks a domain; a longer domain outranks a shorter one.
            let rank = if key.starts_with("*.") { key.matches('.').count() } else { usize::MAX };
            (rank, key.as_str(), note.as_str())
        })
        .collect();
    found.sort();
    found.into_iter().map(|(_, _, note)| note).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_defaults_fit_the_prompt() {
        let d = defaults();
        assert!(!d.global.is_empty());
        let mut notes = vec![("every app".to_string(), d.global.clone())];
        notes.extend(d.apps.iter().map(|(app, note)| (app.clone(), format!("{} {}", d.global, note))));
        for (app, joined) in notes {
            // The header keeps 400 characters of the joined notes, and a bracket would read
            // as one of its own markers.
            assert!(joined.chars().count() <= 400, "{app}: {} characters", joined.chars().count());
            assert!(!joined.contains(['[', ']', '\n']), "{app}");
        }
    }

    #[test]
    fn groups_give_each_app_its_note() {
        let json = r#"{"global": " g ", "groups": [{"note": "mail note", "apps": ["a", "b"]}, {"note": "chat", "apps": ["c"]}]}"#;
        let d = parse(json).unwrap();
        assert_eq!(d.global, "g");
        assert_eq!(d.apps.get("b").map(String::as_str), Some("mail note"));
        assert_eq!(d.apps.len(), 3);
    }

    #[test]
    fn hosts_are_normalised() {
        assert_eq!(host_of("https://Mail.Google.com/mail/u/0/#inbox"), "mail.google.com");
        assert_eq!(host_of("https://www.example.co.uk:8443/a?b=c"), "example.co.uk");
        assert_eq!(host_of("http://user:pw@intranet.local./wiki"), "intranet.local");
        assert_eq!(host_of("http://[::1]:3000/"), "[::1]");
        assert_eq!(host_of("localhost:3000"), "localhost");
        assert_eq!(host_of("mail.google.com"), "mail.google.com");
        assert_eq!(host_of("https://www.com/"), "www.com");
        for not_web in ["file:///Users/me/notes.html", "about:blank", "chrome://settings", "mailto:a@b.com", ""] {
            assert_eq!(host_of(not_web), "", "{not_web}");
            assert_eq!(site_of(not_web), None, "{not_web}");
        }
    }

    #[test]
    fn base_domains() {
        assert_eq!(base_domain("mail.google.com"), "google.com");
        assert_eq!(base_domain("google.com"), "google.com");
        assert_eq!(base_domain("a.b.docs.example.org"), "example.org");
        assert_eq!(base_domain("news.bbc.co.uk"), "bbc.co.uk");
        assert_eq!(base_domain("mail.yahoo.co.in"), "yahoo.co.in");
        assert_eq!(base_domain("bbc.co.uk"), "bbc.co.uk");
        assert_eq!(base_domain("app.slack.ai"), "slack.ai");
        assert_eq!(base_domain("me.github.io"), "me.github.io");
        assert_eq!(base_domain("docs.me.github.io"), "me.github.io");
        assert_eq!(base_domain("192.168.1.10"), "192.168.1.10");
        assert_eq!(base_domain("localhost"), "localhost");
        assert_eq!(
            site_of("https://mail.google.com/mail"),
            Some(Site { host: "mail.google.com".into(), domain: "google.com".into() })
        );
    }

    #[test]
    fn site_keys_match_their_hosts() {
        assert!(site_matches("mail.google.com", "mail.google.com"));
        assert!(site_matches("Mail.Google.com", "mail.google.com"));
        assert!(site_matches("www.example.com", "example.com"));
        assert!(!site_matches("mail.google.com", "google.com"));
        assert!(!site_matches("mail.google.com", "docs.google.com"));
        assert!(site_matches("*.google.com", "google.com"));
        assert!(site_matches("*.google.com", "mail.google.com"));
        assert!(site_matches("*.google.com", "a.b.google.com"));
        assert!(!site_matches("*.google.com", "notgoogle.com"));
        assert!(!site_matches("*.google.com", "google.com.evil.net"));
        assert!(!site_matches("*.", "google.com"));
        assert!(!site_matches("mail.google.com", ""));
    }

    #[test]
    fn site_notes_broadest_first() {
        let sites: HashMap<String, String> = [
            ("mail.google.com", "Gmail: short replies."),
            ("*.google.com", "Google: plain words."),
            ("*.mail.google.com", "Mail and its subdomains."),
            ("docs.google.com", "Docs: full sentences."),
            ("*.example.com", "   "),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
        assert_eq!(
            site_notes(&sites, "https://mail.google.com/mail/u/0"),
            ["Google: plain words.", "Mail and its subdomains.", "Gmail: short replies."]
        );
        assert_eq!(site_notes(&sites, "https://calendar.google.com/"), ["Google: plain words."]);
        assert!(site_notes(&sites, "https://www.example.com/").is_empty());
        assert!(site_notes(&sites, "").is_empty());
        assert!(site_notes(&HashMap::new(), "https://mail.google.com/").is_empty());
    }

    #[test]
    fn notes_join_and_the_oldest_gives_way() {
        // Everything fits: joined with spaces, empty notes skipped.
        assert_eq!(assemble(&["All apps.", " ", "Mail.", "Gmail."], 400), "All apps. Mail. Gmail.");
        assert_eq!(assemble(&["", "", ""], 400), "");
        assert_eq!(assemble(&["  Only this.  "], 400), "Only this.");
        // The same text the notes made before website notes existed.
        let d = defaults();
        for note in d.apps.values() {
            assert_eq!(assemble(&[&d.global, note], NOTES_CAP), format!("{} {}", d.global, note));
        }
        // Too long: the website note stays whole, the note for all apps is cut at a word.
        let global = "I am a product manager at Northwind and I write short, friendly emails.";
        let app = "Mail: sign off with Best.";
        let site = "Gmail: reply above the quoted text.";
        let cap = site.len() + 1 + app.len() + 1 + 30;
        let joined = assemble(&[global, app, site], cap);
        assert!(joined.chars().count() <= cap, "{joined}");
        assert_eq!(joined, format!("I am a product manager at\u{2026} {app} {site}"));
        // Less room: the app note is cut, and the one for all apps left out.
        let joined = assemble(&[global, app, site], site.len() + 12);
        assert_eq!(joined, format!("Mail: sign\u{2026} {site}"));
        // No room for even a word of the earlier notes.
        assert_eq!(assemble(&[global, app, site], site.len() + 2), site);
        // The website note alone is too long: only its end goes.
        assert_eq!(assemble(&[global, "one two three four"], 10), "one two\u{2026}");
        assert_eq!(assemble(&["abcdefghijklmnop"], 10), "abcdefghi\u{2026}");
        assert_eq!(assemble(&["丁寧な言葉で短く書きます。", "メールでは敬語を使います。"], 20), "丁寧な言葉\u{2026} メールでは敬語を使います。");
        // Within the cap whatever the notes.
        let long = "word ".repeat(200);
        for parts in [vec![long.as_str(), app, site], vec![global, long.as_str(), site], vec![global, app, long.as_str()]] {
            assert!(assemble(&parts, NOTES_CAP).chars().count() <= NOTES_CAP);
        }
    }

    #[test]
    fn an_app_in_two_groups_is_an_error() {
        let json = r#"{"global": "g", "groups": [{"note": "a", "apps": ["x"]}, {"note": "b", "apps": ["x"]}]}"#;
        assert!(parse(json).is_err());
    }
}
