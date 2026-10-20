//! The downloadable model catalog, shared by every shell. Shells download and verify the
//! files (platform networking); the core decides which one fits the machine.

use serde::{Deserialize, Serialize};

pub const CATALOG: &str = include_str!("../../models/catalog.json");

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ModelInfo {
    pub id: String,
    pub name: String,
    pub tier: String,
    pub file: String,
    pub url: String,
    pub sha256: String,
    pub bytes: u64,
    pub min_ram_gb: u32,
    pub license: String,
    #[serde(default)]
    pub recommended: bool,
}

#[derive(Deserialize)]
struct Catalog {
    models: Vec<ModelInfo>,
}

/// Tier for a machine: the 0.6B model below 12 GB of RAM, the 1.7B model otherwise. The
/// 4B model is never picked automatically (about twice the latency).
pub fn recommended_tier(ram_gb: u32) -> &'static str {
    if ram_gb < 12 {
        "light"
    } else {
        "default"
    }
}

/// The catalog with `recommended` set for this machine; models needing more RAM are left out.
pub fn catalog(ram_gb: u32) -> Vec<ModelInfo> {
    let c: Catalog = serde_json::from_str(CATALOG).expect("bundled models/catalog.json is valid");
    let tier = recommended_tier(ram_gb);
    c.models
        .into_iter()
        .filter(|m| m.min_ram_gb <= ram_gb.max(8))
        .map(|mut m| {
            m.recommended = m.tier == tier;
            m
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tiers() {
        let small = catalog(8);
        assert!(small.iter().all(|m| m.min_ram_gb <= 8));
        assert_eq!(small.iter().find(|m| m.recommended).unwrap().tier, "light");
        let big = catalog(18);
        assert_eq!(big.len(), 4);
        assert!(big.iter().filter(|m| m.tier == "quality").all(|m| !m.recommended));
        assert_eq!(big.iter().find(|m| m.recommended).unwrap().file, "Qwen3-1.7B-Base.Q4_K_M.gguf");
        assert!(big.iter().all(|m| m.sha256.len() == 64 && m.url.starts_with("https://huggingface.co/")));
    }
}
