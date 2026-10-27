//! Privacy filters (D52). Text that reaches the prompt from outside the field being written
//! in (screen text, other apps' windows) and the writing history have their secrets masked
//! (`redact`), so a key visible in a terminal can't be suggested into a chat. Fields that
//! ask for a secret (a one-time code, a card number: `sensitive_field`) get no suggestions,
//! and neither does an address being typed (`typing_address`), where a guess is noise.
//!
//! Hand-written scanners, no regex engine: a few hundred lines of screen text are checked on
//! every keystroke.
//!
//! What `redact` masks:
//! - private key blocks (`-----BEGIN … PRIVATE KEY-----` to its `END` line);
//! - tokens with a known key prefix (`sk-`, `ghp_`, `AKIA`, `xoxb-`, `AIza`, …) and JWTs;
//! - long random-looking tokens: 32+ characters mixing upper case, lower case and digits
//!   with high entropy, or 32+ hex digits (a git hash is hidden too);
//! - the value of an assignment to a secret name (`API_KEY=…`, `"password": "…"`,
//!   `Bearer …`);
//! - card numbers (13–19 digits passing Luhn), IBANs (mod 97), US social security numbers
//!   (`123-45-6789`), Aadhaar numbers (`1234 5678 9012`, Verhoeff);
//! - 4–8 digit codes next to a word like "OTP", "code" or "PIN" ("Your OTP is 482913").

use std::borrow::Cow;

/// What a masked secret becomes.
pub const MASK: &str = "\u{2022}\u{2022}\u{2022}";

/// `text` with its secrets replaced by `MASK` (borrowed when there are none).
pub fn redact(text: &str) -> Cow<'_, str> {
    let mut spans = Vec::new();
    pem_blocks(text, &mut spans);
    tokens(text, &mut spans);
    numbers(text, &mut spans);
    ibans(text, &mut spans);
    if spans.is_empty() {
        return Cow::Borrowed(text);
    }
    spans.sort_unstable();
    let mut out = String::with_capacity(text.len());
    let mut at = 0;
    let mut i = 0;
    while i < spans.len() {
        let (s, mut e) = spans[i];
        while i + 1 < spans.len() && spans[i + 1].0 <= e {
            i += 1;
            e = e.max(spans[i].1);
        }
        if s >= at {
            out.push_str(&text[at..s]);
            out.push_str(MASK);
            at = e;
        } else if e > at {
            at = e;
        }
        i += 1;
    }
    out.push_str(&text[at..]);
    Cow::Owned(out)
}

/// Words in a field's label or placeholder that mean it asks for a secret.
const SENSITIVE_LABELS: &[&str] = &[
    "otp", "one time", "verification code", "security code", "auth code", "authentication code",
    "2fa", "two factor", "mfa", "passcode", "pin", "cvv", "cvc", "cvv2", "csc", "card number",
    "credit card", "debit card", "cc number", "card no", "expiry", "expiration date", "iban",
    "account number", "routing number", "sort code", "ssn", "social security", "aadhaar",
    "api key", "secret", "token", "private key", "recovery code", "backup code", "seed phrase",
    "recovery phrase", "mnemonic", "password", "passphrase",
];

/// True when a field's label or placeholder says it asks for a secret: a one-time code, a
/// PIN, a card number, a password (not every password field is a secure one).
pub fn sensitive_field(label: &str) -> bool {
    let norm = format!(" {} ", normalize(label));
    !norm.trim().is_empty() && SENSITIVE_LABELS.iter().any(|l| norm.contains(&format!(" {l} ")))
}

/// Lower case, every run of non-alphanumerics one space.
fn normalize(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if c.is_alphanumeric() {
            out.extend(c.to_lowercase());
        } else if !out.ends_with(' ') {
            out.push(' ');
        }
    }
    out.trim().to_string()
}

/// True when the caret is at the end of a URL or an email address (`www.exa`,
/// `https://git`, `priya@exa`). A mention (`@sam`) is not an address.
pub fn typing_address(text_before: &str) -> bool {
    if text_before.ends_with(char::is_whitespace) {
        return false;
    }
    let token = text_before.rsplit(char::is_whitespace).next().unwrap_or("");
    let token = token.trim_start_matches(['(', '<', '"', '\'', '[', '{']).to_lowercase();
    if token.contains("://") || token.starts_with("www.") {
        return true;
    }
    matches!(token.find('@'), Some(i) if token[..i].chars().any(char::is_alphanumeric))
}

/// `-----BEGIN … PRIVATE KEY-----` through its `-----END …-----` line (or the end of the
/// text, when the block is cut off).
fn pem_blocks(text: &str, spans: &mut Vec<(usize, usize)>) {
    const BEGIN: &str = "-----BEGIN ";
    let mut from = 0;
    while let Some(i) = text[from..].find(BEGIN) {
        let s = from + i;
        let after = s + BEGIN.len();
        let Some(j) = text[after..].find("-----") else { break };
        let head_end = after + j + 5;
        if j > 60 || !text[after..after + j].contains("PRIVATE KEY") {
            from = head_end;
            continue;
        }
        let e = text[head_end..]
            .find("-----END ")
            .and_then(|k| {
                let k = head_end + k + 9;
                text[k..].find("-----").map(|m| k + m + 5)
            })
            .unwrap_or(text.len());
        spans.push((s, e));
        from = e;
    }
}

/// Key prefixes and the least the rest of the token must hold.
const KEY_PREFIXES: &[(&str, usize)] = &[
    ("sk-", 20), ("sk_live_", 16), ("sk_test_", 16), ("rk_live_", 16), ("rk_test_", 16),
    ("whsec_", 16), ("ghp_", 30), ("gho_", 30), ("ghu_", 30), ("ghs_", 30), ("ghr_", 30),
    ("github_pat_", 30), ("glpat-", 16), ("xoxb-", 16), ("xoxp-", 16), ("xoxa-", 16),
    ("xoxr-", 16), ("xoxs-", 16), ("xapp-", 16), ("AKIA", 16), ("ASIA", 16), ("AIza", 30),
    ("ya29.", 20), ("hf_", 30), ("npm_", 30), ("pypi-", 30), ("SG.", 30), ("shpat_", 20),
    ("dop_v1_", 30), ("eyJ", 30),
];

/// Names whose assigned value is a secret (compared lower case, `-` as `_`).
const SECRET_NAMES: &[&str] = &[
    "password", "passwd", "pwd", "passphrase", "secret", "token", "apikey", "api_key",
    "access_key", "secret_key", "private_key", "client_secret", "auth", "authorization",
    "credentials",
];

fn is_secret_name(name: &str) -> bool {
    let n = name.trim_matches(|c: char| !c.is_alphanumeric()).to_ascii_lowercase().replace('-', "_");
    !n.is_empty()
        && SECRET_NAMES
            .iter()
            .any(|k| n == *k || n.ends_with(&format!("_{k}")) || (k.len() >= 5 && n.ends_with(k)))
}

fn key_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | '+' | '/' | '=')
}

/// Characters that wrap a token without being part of it.
fn wrapper(c: char) -> bool {
    matches!(c, '"' | '\'' | '`' | '(' | ')' | '<' | '>' | '[' | ']' | '{' | '}' | ',' | ';')
}

/// Byte range of `token` (at `start`) without its wrappers and a trailing `.` or `:`.
fn core(token: &str, start: usize) -> (usize, usize) {
    let t = token.trim_start_matches(wrapper);
    let s = start + token.len() - t.len();
    let t = t.trim_end_matches(|c: char| wrapper(c) || c == '.' || c == ':');
    (s, s + t.len())
}

/// Known key prefixes, JWTs and long random-looking tokens.
fn looks_like_key(t: &str) -> bool {
    // Segments of a URL or an assignment are judged one by one.
    has_key_prefix(t) || t.split(['=', '&', '?', '#', ':', '/', '.', ',', ';', '"', '\'']).any(|s| has_key_prefix(s) || random_looking(s))
}

fn has_key_prefix(t: &str) -> bool {
    KEY_PREFIXES.iter().any(|(p, min)| {
        t.strip_prefix(p).is_some_and(|rest| rest.chars().count() >= *min && rest.chars().all(key_char))
    })
}

fn random_looking(seg: &str) -> bool {
    let n = seg.chars().count();
    if n < 32 || !seg.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '+') {
        return false;
    }
    let digits = seg.chars().filter(char::is_ascii_digit).count();
    let upper = seg.chars().any(|c| c.is_ascii_uppercase());
    let lower = seg.chars().any(|c| c.is_ascii_lowercase());
    if seg.chars().all(|c| c.is_ascii_hexdigit()) {
        return digits >= 6 && n - digits >= 6;
    }
    upper && lower && digits > 0 && entropy(seg) >= 4.0
}

/// Shannon entropy in bits per character.
fn entropy(s: &str) -> f64 {
    let mut counts = [0u32; 128];
    let mut n = 0.0;
    for b in s.bytes().filter(u8::is_ascii) {
        counts[b as usize] += 1;
        n += 1.0;
    }
    counts.iter().filter(|c| **c > 0).map(|c| *c as f64 / n).map(|p| -p * p.log2()).sum()
}

/// Whitespace-separated tokens: keys, and the values of assignments to secret names.
fn tokens(text: &str, spans: &mut Vec<(usize, usize)>) {
    let toks: Vec<(usize, &str)> = text
        .split(char::is_whitespace)
        .scan(0usize, |pos, t| {
            let start = *pos;
            *pos += t.len() + text[*pos + t.len()..].chars().next().map_or(0, char::len_utf8);
            Some((start, t))
        })
        .filter(|(_, t)| !t.is_empty())
        .collect();
    // The next token holds the value of an assignment to a secret name.
    let mut value_next = false;
    for (i, &(start, raw)) in toks.iter().enumerate() {
        let (s, e) = core(raw, start);
        let t = &text[s..e];
        if std::mem::take(&mut value_next) {
            if raw == "=" || raw == ":" {
                value_next = true;
                continue;
            }
            // `Authorization: Bearer …`: the scheme stays, the credential after it goes.
            let scheme = t.eq_ignore_ascii_case("bearer") || t.eq_ignore_ascii_case("basic");
            if !scheme && t.chars().count() >= 5 {
                spans.push((s, e));
                continue;
            }
        }
        if t.is_empty() {
            continue;
        }
        if t.eq_ignore_ascii_case("bearer") || t.eq_ignore_ascii_case("basic") {
            if let Some(&(ns, next)) = toks.get(i + 1) {
                let (vs, ve) = core(next, ns);
                if ve - vs >= 8 {
                    spans.push((vs, ve));
                }
            }
            continue;
        }
        // `name=value`, `name: value`, `"name": "value"`, `name = value`: only the value goes.
        let raw_trim = raw.trim_start_matches(wrapper);
        let raw_off = start + raw.len() - raw_trim.len();
        match raw_trim.find(['=', ':']) {
            Some(p) if p > 0 && is_secret_name(&raw_trim[..p]) => {
                let vstart = raw_off + p + 1;
                let (vs, ve) = core(&text[vstart..start + raw.len()], vstart);
                if ve == vs {
                    value_next = true;
                } else if ve - vs >= 5 {
                    spans.push((vs, ve));
                }
                continue;
            }
            None if is_secret_name(raw_trim) && toks.get(i + 1).is_some_and(|(_, n)| *n == "=" || *n == ":") => {
                value_next = true;
                continue;
            }
            _ => {}
        }
        if looks_like_key(t) {
            spans.push((s, e));
        }
    }
}

/// Words that make a nearby 4–8 digit number a code.
const CODE_CUES: &[&str] = &["otp", "code", "codes", "pin", "passcode", "password", "verification", "2fa", "mfa", "token"];

/// Digit runs (single spaces or dashes may separate groups): card numbers, social security
/// and Aadhaar numbers, and codes next to a cue word.
fn numbers(text: &str, spans: &mut Vec<(usize, usize)>) {
    let b = text.as_bytes();
    let mut i = 0;
    while i < b.len() {
        let starts = b[i].is_ascii_digit() && (i == 0 || !prev_alnum(text, i));
        if !starts {
            i += 1;
            continue;
        }
        let s = i;
        let mut digits = String::new();
        let mut groups = vec![0usize];
        let mut seps = Vec::new();
        let mut e = i;
        while i < b.len() {
            if b[i].is_ascii_digit() {
                digits.push(b[i] as char);
                *groups.last_mut().unwrap() += 1;
                i += 1;
                e = i;
            } else if (b[i] == b' ' || b[i] == b'-') && i + 1 < b.len() && b[i + 1].is_ascii_digit() && e == i {
                seps.push(b[i]);
                groups.push(0);
                i += 1;
            } else {
                break;
            }
        }
        if text[e..].chars().next().is_some_and(char::is_alphanumeric) {
            continue;
        }
        let n = digits.len();
        let card = (13..=19).contains(&n) && luhn(&digits);
        let ssn = groups == [3, 2, 4] && seps == *b"--";
        let aadhaar = groups == [4, 4, 4] && verhoeff(&digits);
        let code = (4..=8).contains(&n) && groups.len() <= 2 && near_cue(text, s, e);
        if card || ssn || aadhaar || code {
            spans.push((s, e));
        }
    }
}

fn prev_alnum(text: &str, i: usize) -> bool {
    text[..i].chars().next_back().is_some_and(|c| c.is_alphanumeric() || c == '.' || c == ',')
}

/// A cue word on the same line within a few words before or after `s..e`.
fn near_cue(text: &str, s: usize, e: usize) -> bool {
    let line_start = text[..s].rfind('\n').map_or(0, |p| p + 1);
    let line_end = text[e..].find('\n').map_or(text.len(), |p| e + p);
    let before = normalize(&text[line_start..s]);
    let after = normalize(&text[e..line_end]);
    let near = |words: Vec<&str>| words.iter().any(|w| CODE_CUES.contains(w));
    near(before.split(' ').rev().take(5).collect()) || near(after.split(' ').take(5).collect())
}

fn luhn(digits: &str) -> bool {
    let sum: u32 = digits
        .bytes()
        .rev()
        .enumerate()
        .map(|(i, d)| {
            let d = (d - b'0') as u32;
            if i % 2 == 1 {
                let x = d * 2;
                if x > 9 { x - 9 } else { x }
            } else {
                d
            }
        })
        .sum();
    sum.is_multiple_of(10)
}

fn verhoeff(digits: &str) -> bool {
    const D: [[u8; 10]; 10] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
        [1, 2, 3, 4, 0, 6, 7, 8, 9, 5],
        [2, 3, 4, 0, 1, 7, 8, 9, 5, 6],
        [3, 4, 0, 1, 2, 8, 9, 5, 6, 7],
        [4, 0, 1, 2, 3, 9, 5, 6, 7, 8],
        [5, 9, 8, 7, 6, 0, 4, 3, 2, 1],
        [6, 5, 9, 8, 7, 1, 0, 4, 3, 2],
        [7, 6, 5, 9, 8, 2, 1, 0, 4, 3],
        [8, 7, 6, 5, 9, 3, 2, 1, 0, 4],
        [9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
    ];
    const P: [[u8; 10]; 8] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
        [1, 5, 7, 6, 2, 8, 3, 0, 9, 4],
        [5, 8, 0, 3, 7, 9, 6, 1, 4, 2],
        [8, 9, 1, 6, 0, 4, 3, 5, 2, 7],
        [9, 4, 5, 3, 1, 2, 6, 8, 7, 0],
        [4, 2, 8, 6, 5, 7, 3, 9, 0, 1],
        [2, 7, 9, 3, 8, 0, 6, 4, 1, 5],
        [7, 0, 4, 6, 9, 1, 3, 2, 5, 8],
    ];
    let mut c = 0u8;
    for (i, d) in digits.bytes().rev().enumerate() {
        c = D[c as usize][P[i % 8][(d - b'0') as usize] as usize];
    }
    c == 0
}

/// IBANs, printed whole or in groups of four: two letters, two check digits, then up to 30
/// letters and digits, checked with mod 97.
fn ibans(text: &str, spans: &mut Vec<(usize, usize)>) {
    let b = text.as_bytes();
    let mut i = 0;
    while i + 4 <= b.len() {
        let head = b[i].is_ascii_uppercase()
            && b[i + 1].is_ascii_uppercase()
            && b[i + 2].is_ascii_digit()
            && b[i + 3].is_ascii_digit()
            && (i == 0 || !prev_alnum(text, i));
        if !head {
            i += 1;
            continue;
        }
        // Groups of upper-case letters and digits separated by single spaces: their
        // characters so far and the byte end of each.
        let mut chars = String::new();
        let mut ends = Vec::new();
        let mut j = i;
        loop {
            let g = j;
            while j < b.len() && (b[j].is_ascii_uppercase() || b[j].is_ascii_digit()) && chars.len() < 34 {
                chars.push(b[j] as char);
                j += 1;
            }
            if j == g || text[j..].chars().next().is_some_and(char::is_alphanumeric) {
                break;
            }
            ends.push((chars.len(), j));
            if j + 1 < b.len() && b[j] == b' ' && (b[j + 1].is_ascii_uppercase() || b[j + 1].is_ascii_digit()) {
                j += 1;
            } else {
                break;
            }
        }
        let found = ends.iter().rev().find(|(n, _)| (15..=34).contains(n) && mod97(&chars[..*n]) == 1);
        match found {
            Some(&(_, e)) => {
                spans.push((i, e));
                i = e;
            }
            None => i += 1,
        }
    }
}

fn mod97(iban: &str) -> u32 {
    let (head, tail) = iban.split_at(4);
    let mut r = 0u32;
    for c in tail.chars().chain(head.chars()) {
        let v = c.to_digit(36).unwrap_or(0);
        r = if v >= 10 { (r * 100 + v) % 97 } else { (r * 10 + v) % 97 };
    }
    r
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(s: &str) -> String {
        redact(s).into_owned()
    }

    // The made-up keys below are split with `concat!` so secret scanners don't flag them.
    #[test]
    fn keys_are_masked() {
        assert_eq!(r(concat!("export OPENAI_API_KEY=sk-", "proj-AbCdEf0123456789XyZaBcDeF")), "export OPENAI_API_KEY=•••");
        assert_eq!(r(concat!("token ghp_", "aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789 ok")), "token ••• ok");
        assert_eq!(r(concat!("aws AKIA", "IOSFODNN7EXAMPLE.")), "aws •••.");
        assert_eq!(r(concat!("key: \"AIza", "SyA-1234567890abcdefghijklmnopqrstu\",")), "key: \"•••\",");
        assert_eq!(r("Authorization: Bearer abcdefgh12345678"), "Authorization: Bearer •••");
        assert_eq!(r(concat!("jwt eyJ", "hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc")), "jwt •••");
        assert_eq!(r("x 9fQ2kLm8ZpR4tW7yB3nV6cX1sD5gH0jK2LmN"), "x •••");
        assert_eq!(r("commit 1b308e8c0e1f2a3b4c5d6e7f8091a2b3c4d5e6f7 merged"), "commit ••• merged");
    }

    #[test]
    fn assignments_to_secret_names_are_masked() {
        assert_eq!(r("DB_PASSWORD=hunter22"), "DB_PASSWORD=•••");
        assert_eq!(r("{\"password\": \"hunter22\", \"user\": \"sam\"}"), "{\"password\": \"•••\", \"user\": \"sam\"}");
        assert_eq!(r("client_secret = s3cr3tvalue"), "client_secret = •••");
        assert_eq!(r("Password: correcthorse"), "Password: •••");
        assert_eq!(r("apiKey:abcdef"), "apiKey:•••");
    }

    #[test]
    fn private_key_blocks_are_masked() {
        let t = concat!("before\n-----BEGIN OPENSSH ", "PRIVATE KEY-----\nb3BlbnNzaC1rZXk\nAAAA\n-----END OPENSSH ", "PRIVATE KEY-----\nafter");
        assert_eq!(r(t), "before\n•••\nafter");
        assert_eq!(r(concat!("x -----BEGIN RSA ", "PRIVATE KEY-----\nMIIE")), "x •••");
        let cert = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----";
        assert_eq!(r(cert), cert, "a certificate is public");
    }

    #[test]
    fn numbers_are_masked_when_they_are_secrets() {
        assert_eq!(r("card 4111 1111 1111 1111 exp"), "card ••• exp");
        assert_eq!(r("card 4111-1111-1111-1112"), "card 4111-1111-1111-1112", "fails Luhn");
        assert_eq!(r("amex 378282246310005."), "amex •••.");
        assert_eq!(r("SSN 078-05-1120"), "SSN •••");
        assert_eq!(r("Aadhaar 2341 2341 2346"), "Aadhaar •••");
        assert_eq!(r("Your OTP is 482913. Do not share it."), "Your OTP is •••. Do not share it.");
        assert_eq!(r("482 913 is your verification code"), "••• is your verification code");
        assert_eq!(r("Use code: 7781"), "Use code: •••");
        assert_eq!(r("We met in 2024 and sold 4500 units"), "We met in 2024 and sold 4500 units");
        assert_eq!(r("Call +91 98765 43210 today"), "Call +91 98765 43210 today");
        assert_eq!(r("Total $412,600 for 2026"), "Total $412,600 for 2026");
    }

    #[test]
    fn ibans_are_masked() {
        assert_eq!(r("IBAN DE89 3704 0044 0532 0130 00 thanks"), "IBAN ••• thanks");
        assert_eq!(r("to GB82WEST12345698765432."), "to •••.");
        assert_eq!(r("GB82 WEST 1234 5698 7654 33"), "GB82 WEST 1234 5698 7654 33", "bad check digits");
    }

    #[test]
    fn ordinary_text_is_left_alone() {
        for t in [
            "Martin: could you send the Q3 numbers?",
            "See https://github.com/DaraSingh1998/foretype/releases/tag/v0.1.9 for notes",
            "/Users/apple/Library/Application Support/Foretype/Models/Qwen3-1.7B-Base.Q4_K_M.gguf",
            "id 3f2b8c1e-4d5a-4b6c-8e9f-0a1b2c3d4e5f",
            "The token economy and password managers were discussed",
            "पासवर्ड बदलें 2024",
            "a_very_long_identifier_name_without_digits_at_all",
        ] {
            assert!(matches!(redact(t), Cow::Borrowed(_)), "{t} → {}", r(t));
        }
    }

    #[test]
    fn sensitive_labels() {
        for l in ["One-time code", "Enter OTP", "PIN", "Card number", "CVV", "IBAN", "Verification code", "Password", "API key"] {
            assert!(sensitive_field(l), "{l}");
        }
        for l in ["", "Message", "Shipping address", "Opinion", "Search", "Message input", "Subject", "Tokenizer notes"] {
            assert!(!sensitive_field(l), "{l}");
        }
    }

    #[test]
    fn addresses_being_typed() {
        assert!(typing_address("see www.exa"));
        assert!(typing_address("open https://git"));
        assert!(typing_address("mail me at (priya@exa"));
        assert!(!typing_address("ping @sam"));
        assert!(!typing_address("see www.example.com "));
        assert!(!typing_address("Hello there"));
    }
}
