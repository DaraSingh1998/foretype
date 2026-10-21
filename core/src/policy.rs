//! The gate that runs before any inference: per-app rules from the shared compatibility
//! database plus field-level checks (secure fields, selections, IME composition, mid-line).

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

use crate::words;
use crate::Snapshot;

/// The compatibility database bundled with the engine. Shells may load a newer copy.
pub const BUNDLED_COMPAT: &str = include_str!("../../compat/apps.json");

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct AppRule {
    #[serde(default)]
    pub disabled: bool,
    /// Terminals: suggest only when the caret line is an AI-agent prompt.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub agent_prompt_only: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub insertion: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prime: Option<String>,
    /// Where the shell finds the caret: `"pixel"` always locates it on screen (the app's
    /// accessibility geometry is wrong), `"ax"` never does. Unset: accessibility, with the
    /// pixel locator as the fallback when that gives nothing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caret: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// Fields that stay on in an app that is off by default: case-insensitive substrings
    /// of the field's label or placeholder (a code editor's chat input, say).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub allow_fields: Vec<String>,
}

impl AppRule {
    /// True if `description` matches one of `allow_fields`.
    pub fn allows_field(&self, description: &str) -> bool {
        let d = description.to_lowercase();
        !d.is_empty() && self.allow_fields.iter().any(|p| d.contains(&p.to_lowercase()))
    }
}

/// How CLI agents draw their input line: an optional border character, then a marker.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct AgentPrompt {
    #[serde(default)]
    pub borders: Vec<String>,
    #[serde(default)]
    pub markers: Vec<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct CompatDb {
    #[serde(default)]
    pub apps: HashMap<String, AppRule>,
    #[serde(default)]
    pub prefixes: HashMap<String, AppRule>,
    #[serde(default)]
    pub agent_prompt: AgentPrompt,
}

impl CompatDb {
    pub fn bundled() -> Self {
        serde_json::from_str(BUNDLED_COMPAT).expect("bundled compat/apps.json is valid")
    }

    pub fn rule(&self, bundle_id: &str) -> AppRule {
        if let Some(r) = self.apps.get(bundle_id) {
            return r.clone();
        }
        self.prefixes
            .iter()
            .filter(|(p, _)| bundle_id.starts_with(p.as_str()))
            .max_by_key(|(p, _)| p.len())
            .map(|(_, r)| r.clone())
            .unwrap_or_default()
    }

    /// The prompt text typed so far if `text_before`'s last line is an AI-agent prompt
    /// (e.g. Claude Code's `> `), or `None` for an ordinary shell line.
    pub fn agent_prompt_text<'a>(&self, text_before: &'a str) -> Option<&'a str> {
        let line = text_before.rsplit('\n').next().unwrap_or("");
        let mut rest = line.trim_start();
        if let Some(b) = self.agent_prompt.borders.iter().find(|b| rest.starts_with(b.as_str())) {
            rest = rest[b.len()..].trim_start();
        }
        self.agent_prompt
            .markers
            .iter()
            .find(|m| rest.starts_with(m.as_str()))
            .map(|m| &rest[m.len()..])
    }
}

/// Text roles that can take suggestions.
const TEXT_ROLES: &[&str] = &["AXTextArea", "AXTextField", "AXComboBox"];

/// Characters allowed after the caret on the same line before we stop suggesting
/// (llama.vim's `max_line_suffix`).
const MAX_LINE_SUFFIX: usize = 8;

/// Single-line fields narrower than this are treated as "small" (search boxes, form
/// fields), where Tab must keep moving focus.
const MIN_SINGLE_LINE_WIDTH: f64 = 260.0;

/// Why the gate said no. `None` means suggest. `allow_mid_line` lifts the rule against text
/// after the caret (the engine can fill in the middle and the user turned it on).
pub fn evaluate(
    snap: &Snapshot,
    compat: &CompatDb,
    user_disabled: &HashSet<String>,
    user_enabled: &HashSet<String>,
    allow_mid_line: bool,
) -> Option<&'static str> {
    if snap.secure_input {
        return Some("secureInput");
    }
    let rd = snap.role_description.to_lowercase();
    if snap.subrole == "AXSecureTextField" || rd.contains("password") || rd.contains("secure") {
        return Some("secureField");
    }
    if !TEXT_ROLES.contains(&snap.role.as_str()) {
        return Some("notTextField");
    }
    if snap.subrole == "AXSearchField" && !snap.force {
        return Some("searchField");
    }
    if snap.selection_len > 0 {
        return Some("selection");
    }
    if snap.marked_len > 0 {
        return Some("composing");
    }
    if user_disabled.contains(&snap.bundle_id) {
        return Some("appDisabledByUser");
    }
    let rule = compat.rule(&snap.bundle_id);
    let user_on = user_enabled.contains(&snap.bundle_id);
    if rule.disabled && !user_on && !snap.force && !rule.allows_field(&snap.description) {
        return Some("appDisabledByDefault");
    }
    if rule.agent_prompt_only && !user_on && !snap.force && compat.agent_prompt_text(&snap.text_before).is_none() {
        return Some("notAgentPrompt");
    }
    if snap.role == "AXTextField"
        && snap.field_width > 0.0
        && snap.field_width < MIN_SINGLE_LINE_WIDTH
        && !snap.force
    {
        return Some("smallField");
    }
    let suffix = snap.text_after.split('\n').next().unwrap_or("");
    if !allow_mid_line && suffix.trim().chars().count() > MAX_LINE_SUFFIX {
        return Some("midLine");
    }
    if snap.text_before.trim().chars().count() < 2 {
        return Some("tooShort");
    }
    let (_, fragment) = words::split_fragment(&snap.text_before);
    if words::fragment_word(fragment).chars().count() > 30 {
        return Some("longWord");
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snap(text: &str) -> Snapshot {
        Snapshot {
            role: "AXTextArea".into(),
            bundle_id: "com.apple.TextEdit".into(),
            text_before: text.into(),
            ..Default::default()
        }
    }

    #[test]
    fn bundled_db_parses_and_matches_prefixes() {
        let db = CompatDb::bundled();
        assert!(db.rule("com.apple.Terminal").agent_prompt_only);
        assert!(db.rule("dev.warp.Warp-Stable").disabled);
        assert!(db.rule("com.jetbrains.intellij").disabled);
        assert!(!db.rule("com.apple.TextEdit").disabled);
        assert_eq!(db.rule("com.google.Chrome").prime.as_deref(), Some("chromium"));
    }

    #[test]
    fn caret_rule() {
        // Apps without AX geometry (Teams) or with rects the pixel caret confirms (LibreOffice)
        // need no rule: the pixel caret is the fallback.
        let db = CompatDb::bundled();
        assert_eq!(db.rule("org.libreoffice.script").caret, None);
        assert_eq!(db.rule("com.microsoft.teams2").caret, None);
        let db: CompatDb = serde_json::from_str(r#"{"apps": {"a.b": {"caret": "pixel"}, "c.d": {"caret": "ax"}}}"#).unwrap();
        assert_eq!(db.rule("a.b").caret.as_deref(), Some("pixel"));
        assert_eq!(db.rule("c.d").caret.as_deref(), Some("ax"));
        // The shell reads the rule as JSON: the key appears only when set.
        let json = serde_json::to_string(&db.rule("a.b")).unwrap();
        assert!(json.contains("\"caret\":\"pixel\""), "{json}");
        assert!(!serde_json::to_string(&db.rule("x.y")).unwrap().contains("\"caret\":"));
        let r: AppRule = serde_json::from_str(r#"{"disabled": true}"#).unwrap();
        assert!(r.disabled && r.caret.is_none());
    }

    #[test]
    fn agent_prompts() {
        let db = CompatDb::bundled();
        assert_eq!(db.agent_prompt_text("history\n> add a test for"), Some("add a test for"));
        assert_eq!(db.agent_prompt_text("\u{2502} > refactor the"), Some("refactor the"));
        assert_eq!(db.agent_prompt_text("  \u{203a} explain this"), Some("explain this"));
        assert_eq!(db.agent_prompt_text("$ git status"), None);
        assert_eq!(db.agent_prompt_text("user@host ~ % ls"), None);
        assert_eq!(db.agent_prompt_text("\u{276f} cd src"), None); // starship shell prompt
    }

    #[test]
    fn gate() {
        let db = CompatDb::bundled();
        let none = HashSet::new();
        assert_eq!(evaluate(&snap("Hello there, I"), &db, &none, &none, false), None);
        let mut s = snap("Hello there");
        s.marked_len = 2;
        assert_eq!(evaluate(&s, &db, &none, &none, false), Some("composing"));
        let mut s = snap("Hello there");
        s.marked_len = 0; // TextEdit always reports a zero-length marked range
        assert_eq!(evaluate(&s, &db, &none, &none, false), None);
        let mut s = snap("Hello there");
        s.text_after = " and some more text here\nnext".into();
        assert_eq!(evaluate(&s, &db, &none, &none, false), Some("midLine"));
        let mut s = snap("Hello there");
        s.text_after = ".\nnext line".into();
        assert_eq!(evaluate(&s, &db, &none, &none, false), None);
        let mut s = snap("Hello there");
        s.text_after = " and some more text here\nnext".into();
        assert_eq!(evaluate(&s, &db, &none, &none, true), None, "mid-line allowed");
        let mut s = snap("ls -la");
        s.bundle_id = "dev.warp.Warp-Stable".into();
        assert_eq!(evaluate(&s, &db, &none, &none, false), Some("appDisabledByDefault"));
        let mut s = snap("refactor the parser so that");
        s.bundle_id = "com.microsoft.VSCode".into();
        s.description = "Editor content;Press Alt+F1 for Accessibility Options.".into();
        assert_eq!(evaluate(&s, &db, &none, &none, false), Some("appDisabledByDefault"), "the code editor stays off");
        s.description = "Chat Input".into();
        assert_eq!(evaluate(&s, &db, &none, &none, false), None, "its chat input is on");
        let mut s = snap("Last login: Mon\n$ ls -la");
        s.bundle_id = "com.apple.Terminal".into();
        assert_eq!(evaluate(&s, &db, &none, &none, false), Some("notAgentPrompt"));
        s.text_before = "Welcome to Claude Code\n\u{2502} > fix the failing te".into();
        assert_eq!(evaluate(&s, &db, &none, &none, false), None);
        let mut s = snap("secret");
        s.subrole = "AXSecureTextField".into();
        assert_eq!(evaluate(&s, &db, &none, &none, false), Some("secureField"));
        let mut s = snap("query text");
        s.role = "AXTextField".into();
        s.field_width = 180.0;
        assert_eq!(evaluate(&s, &db, &none, &none, false), Some("smallField"));
    }
}
