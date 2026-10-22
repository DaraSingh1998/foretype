//! The custom instructions a fresh install starts with: one note for every app, plus one for
//! each kind of app (email, chat, notes, ...). Shells show them in their instructions editor
//! as if the user had written them, so the user can change or clear any of them; a note the
//! user hasn't touched follows the defaults of the installed version.

use std::collections::BTreeMap;

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
    fn an_app_in_two_groups_is_an_error() {
        let json = r#"{"global": "g", "groups": [{"note": "a", "apps": ["x"]}, {"note": "b", "apps": ["x"]}]}"#;
        assert!(parse(json).is_err());
    }
}
