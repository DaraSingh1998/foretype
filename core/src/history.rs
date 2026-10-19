//! Opt-in, local, encrypted record of what the user wrote, used only for personalization.
//!
//! Each record is serialized to JSON and sealed with ChaCha20-Poly1305 under a 256-bit key
//! that the shell keeps in the platform keystore (the macOS Keychain); the core never
//! stores the key. The file is a sequence of frames: `u32` little-endian length, 12-byte
//! nonce, ciphertext. Frames that fail to decrypt (wrong key, damage) are skipped.
//! Deleting the history deletes the file.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use chacha20poly1305::aead::{Aead, AeadCore, KeyInit, OsRng};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Record {
    /// Seconds since the Unix epoch.
    pub ts: u64,
    /// Bundle ID (or app name) the text was written in.
    pub app: String,
    pub text: String,
}

impl Record {
    pub fn now(app: &str, text: &str) -> Self {
        let ts = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        Self { ts, app: app.to_string(), text: text.to_string() }
    }
}

/// Most records kept; older ones are dropped when the file is compacted.
pub const MAX_RECORDS: usize = 3000;

pub struct History {
    path: Option<PathBuf>,
    cipher: Option<ChaCha20Poly1305>,
    records: Vec<Record>,
}

/// Parses a 64-character hex key.
pub fn parse_key(hex: &str) -> Option<[u8; 32]> {
    let hex = hex.trim();
    if hex.len() != 64 {
        return None;
    }
    let mut key = [0u8; 32];
    for (i, byte) in key.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).ok()?;
    }
    Some(key)
}

impl History {
    /// History that lives only in memory (tests, replays, or no key available).
    pub fn in_memory() -> Self {
        Self { path: None, cipher: None, records: Vec::new() }
    }

    /// Opens (or creates on first append) the encrypted file at `path`.
    pub fn open(path: impl Into<PathBuf>, key: &[u8; 32]) -> Self {
        let path = path.into();
        let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
        let mut records = Vec::new();
        if let Ok(mut f) = File::open(&path) {
            let mut buf = Vec::new();
            if f.read_to_end(&mut buf).is_ok() {
                let mut at = 0;
                while at + 4 + 12 <= buf.len() {
                    let len = u32::from_le_bytes(buf[at..at + 4].try_into().unwrap()) as usize;
                    let end = at + 4 + len;
                    if len < 12 || end > buf.len() {
                        break;
                    }
                    let nonce = Nonce::from_slice(&buf[at + 4..at + 16]);
                    if let Ok(plain) = cipher.decrypt(nonce, &buf[at + 16..end]) {
                        if let Ok(r) = serde_json::from_slice::<Record>(&plain) {
                            records.push(r);
                        }
                    }
                    at = end;
                }
            }
        }
        Self { path: Some(path), cipher: Some(cipher), records }
    }

    pub fn records(&self) -> &[Record] {
        &self.records
    }

    pub fn is_persistent(&self) -> bool {
        self.path.is_some()
    }

    fn frame(cipher: &ChaCha20Poly1305, r: &Record) -> Result<Vec<u8>, String> {
        let nonce = ChaCha20Poly1305::generate_nonce(&mut OsRng);
        let plain = serde_json::to_vec(r).map_err(|e| e.to_string())?;
        let sealed = cipher.encrypt(&nonce, plain.as_slice()).map_err(|e| e.to_string())?;
        let mut out = Vec::with_capacity(4 + 12 + sealed.len());
        out.extend_from_slice(&((12 + sealed.len()) as u32).to_le_bytes());
        out.extend_from_slice(&nonce);
        out.extend_from_slice(&sealed);
        Ok(out)
    }

    pub fn append(&mut self, r: Record) -> Result<(), String> {
        self.records.push(r.clone());
        let (Some(path), Some(cipher)) = (&self.path, &self.cipher) else { return Ok(()) };
        if self.records.len() > MAX_RECORDS + MAX_RECORDS / 4 {
            return self.compact();
        }
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let frame = Self::frame(cipher, &r)?;
        let mut f = OpenOptions::new().create(true).append(true).open(path).map_err(|e| e.to_string())?;
        f.write_all(&frame).map_err(|e| e.to_string())
    }

    /// Keeps the newest `MAX_RECORDS` and rewrites the file atomically.
    fn compact(&mut self) -> Result<(), String> {
        let excess = self.records.len().saturating_sub(MAX_RECORDS);
        self.records.drain(..excess);
        let (Some(path), Some(cipher)) = (&self.path, &self.cipher) else { return Ok(()) };
        let mut data = Vec::new();
        for r in &self.records {
            data.extend(Self::frame(cipher, r)?);
        }
        let tmp = path.with_extension("tmp");
        fs::write(&tmp, &data).map_err(|e| e.to_string())?;
        fs::rename(&tmp, path).map_err(|e| e.to_string())
    }

    /// Forgets everything and deletes the file.
    pub fn clear(&mut self) -> Result<(), String> {
        self.records.clear();
        if let Some(path) = &self.path {
            match fs::remove_file(path) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e.to_string()),
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("foretype-test-{}-{name}", std::process::id()));
        let _ = fs::remove_file(&p);
        p
    }

    #[test]
    fn round_trip_and_wrong_key() {
        let path = tmp("history.bin");
        let key = [7u8; 32];
        let mut h = History::open(&path, &key);
        h.append(Record { ts: 1, app: "com.apple.mail".into(), text: "Thanks Priya, see you Thursday.".into() }).unwrap();
        h.append(Record { ts: 2, app: "com.apple.Notes".into(), text: "Reconciliation report owner?".into() }).unwrap();
        let raw = fs::read(&path).unwrap();
        assert!(!String::from_utf8_lossy(&raw).contains("Priya"), "file must not contain plaintext");
        let again = History::open(&path, &key);
        assert_eq!(again.records(), h.records());
        let wrong = History::open(&path, &[8u8; 32]);
        assert!(wrong.records().is_empty());
        let mut again = again;
        again.clear().unwrap();
        assert!(!path.exists());
    }

    #[test]
    fn keys() {
        assert!(parse_key(&"ab".repeat(32)).is_some());
        assert!(parse_key("abc").is_none());
        assert!(parse_key(&"zz".repeat(32)).is_none());
    }
}
