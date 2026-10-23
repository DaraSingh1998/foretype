//! Opt-in, local, encrypted record of what the user wrote, used only for personalization.
//!
//! Each record is serialized to JSON and sealed with ChaCha20-Poly1305 under a 256-bit key
//! that the shell keeps in the platform keystore (the macOS Keychain); the core never
//! stores the key. The file is a sequence of frames: `u32` little-endian length, 12-byte
//! nonce, ciphertext. Frames that fail to decrypt (damage) are skipped, but a file whose
//! frames are all undecryptable (a wrong key) or that can't be read is **locked**: kept
//! read-only, never appended to or compacted, so a wrong key can't destroy it. Deleting
//! the history deletes the file (locked or not).

use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
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

const LOCKED: &str = "the history file doesn't open with this key; left as it is";

pub struct History {
    path: Option<PathBuf>,
    cipher: Option<ChaCha20Poly1305>,
    records: Vec<Record>,
    /// The file holds frames none of which open with this key, or can't be read.
    locked: bool,
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
        Self { path: None, cipher: None, records: Vec::new(), locked: false }
    }

    /// Opens (or creates on first append) the encrypted file at `path`. A file with frames
    /// of which none decrypts, or one that can't be read, opens locked (`is_locked`).
    pub fn open(path: impl Into<PathBuf>, key: &[u8; 32]) -> Self {
        let path = path.into();
        let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
        let mut records = Vec::new();
        let (mut frames, mut opened) = (0, 0);
        let buf = match fs::read(&path) {
            Ok(buf) => buf,
            Err(e) if e.kind() == ErrorKind::NotFound => Vec::new(),
            Err(_) => return Self { path: Some(path), cipher: Some(cipher), records, locked: true },
        };
        let mut at = 0;
        while at + 4 + 12 <= buf.len() {
            let len = u32::from_le_bytes(buf[at..at + 4].try_into().unwrap()) as usize;
            let end = at + 4 + len;
            if len < 12 || end > buf.len() {
                break;
            }
            frames += 1;
            let nonce = Nonce::from_slice(&buf[at + 4..at + 16]);
            if let Ok(plain) = cipher.decrypt(nonce, &buf[at + 16..end]) {
                opened += 1;
                if let Ok(r) = serde_json::from_slice::<Record>(&plain) {
                    records.push(r);
                }
            }
            at = end;
        }
        let locked = frames > 0 && opened == 0;
        Self { path: Some(path), cipher: Some(cipher), records, locked }
    }

    pub fn records(&self) -> &[Record] {
        &self.records
    }

    pub fn is_persistent(&self) -> bool {
        self.path.is_some()
    }

    /// The file is there but this key opens none of it (or it can't be read): nothing is
    /// recorded, appended or compacted until the history is cleared.
    pub fn is_locked(&self) -> bool {
        self.locked
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
        if self.locked {
            return Err(LOCKED.into());
        }
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
        if self.locked {
            return Err(LOCKED.into());
        }
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

    /// Forgets everything and deletes the file, a locked one too (the user asked); the
    /// history is then new and unlocked under the same key.
    pub fn clear(&mut self) -> Result<(), String> {
        self.records.clear();
        if let Some(path) = &self.path {
            match fs::remove_file(path) {
                Ok(()) => {}
                Err(e) if e.kind() == ErrorKind::NotFound => {}
                Err(e) => return Err(e.to_string()),
            }
        }
        self.locked = false;
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

    fn rec(ts: u64, text: &str) -> Record {
        Record { ts, app: "com.apple.mail".into(), text: text.into() }
    }

    #[test]
    fn right_key_reads_and_keeps_writing() {
        let path = tmp("right.bin");
        let key = [7u8; 32];
        let mut h = History::open(&path, &key);
        h.append(Record { ts: 1, app: "com.apple.mail".into(), text: "Thanks Priya, see you Thursday.".into() }).unwrap();
        h.append(Record { ts: 2, app: "com.apple.Notes".into(), text: "Reconciliation report owner?".into() }).unwrap();
        let raw = fs::read(&path).unwrap();
        assert!(!String::from_utf8_lossy(&raw).contains("Priya"), "file must not contain plaintext");
        let mut again = History::open(&path, &key);
        assert!(!again.is_locked());
        assert_eq!(again.records(), h.records());
        again.append(rec(3, "Third note, written after reopening.")).unwrap();
        assert_eq!(History::open(&path, &key).records().len(), 3);
        // One frame that doesn't open (damage) among good ones is skipped, not a lock.
        let mut f = OpenOptions::new().append(true).open(&path).unwrap();
        f.write_all(&History::frame(&ChaCha20Poly1305::new(Key::from_slice(&[9u8; 32])), &rec(4, "other key")).unwrap()).unwrap();
        let mixed = History::open(&path, &key);
        assert!(!mixed.is_locked());
        assert_eq!(mixed.records().len(), 3);
        again.clear().unwrap();
        assert!(!path.exists());
    }

    #[test]
    fn wrong_key_never_touches_the_file() {
        let path = tmp("wrong.bin");
        let key = [7u8; 32];
        let mut h = History::open(&path, &key);
        for i in 0..3 {
            h.append(rec(i, &format!("Record number {i} of the real history."))).unwrap();
        }
        let before = fs::read(&path).unwrap();

        let mut wrong = History::open(&path, &[8u8; 32]);
        assert!(wrong.is_locked());
        assert!(wrong.records().is_empty());
        // Enough appends to reach compaction, then compaction itself: all refused.
        for i in 0..(MAX_RECORDS + MAX_RECORDS / 4 + 1) as u64 {
            assert!(wrong.append(rec(100 + i, "Written with the wrong key.")).is_err());
        }
        assert!(wrong.compact().is_err());
        assert!(wrong.records().is_empty());
        assert_eq!(fs::read(&path).unwrap(), before, "file must stay byte-identical");
        assert!(!path.with_extension("tmp").exists());
        assert_eq!(History::open(&path, &key).records(), h.records(), "the right key still reads it all");

        // Deleting is the user's call and works locked too; the history then starts over.
        wrong.clear().unwrap();
        assert!(!path.exists());
        assert!(!wrong.is_locked());
        wrong.append(rec(200, "A new history under the new key.")).unwrap();
        assert_eq!(History::open(&path, &[8u8; 32]).records().len(), 1);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn missing_or_empty_file_opens_for_writing() {
        let key = [7u8; 32];
        let missing = tmp("missing.bin");
        let mut h = History::open(&missing, &key);
        assert!(!h.is_locked());
        assert!(h.records().is_empty());
        h.append(rec(1, "First record in a new file.")).unwrap();
        assert_eq!(History::open(&missing, &key).records().len(), 1);
        let _ = fs::remove_file(&missing);

        let empty = tmp("empty.bin");
        fs::write(&empty, b"").unwrap();
        let mut h = History::open(&empty, &key);
        assert!(!h.is_locked());
        h.append(rec(1, "First record in an empty file.")).unwrap();
        assert_eq!(History::open(&empty, &key).records().len(), 1);
        let _ = fs::remove_file(&empty);

        // A path that can't be read (here a folder) is locked, not treated as empty.
        let unreadable = tmp("unreadable.bin");
        fs::create_dir_all(&unreadable).unwrap();
        let mut h = History::open(&unreadable, &key);
        assert!(h.is_locked());
        assert!(h.append(rec(1, "Never written.")).is_err());
        assert!(unreadable.is_dir());
        let _ = fs::remove_dir(&unreadable);
    }

    #[test]
    fn keys() {
        assert!(parse_key(&"ab".repeat(32)).is_some());
        assert!(parse_key("abc").is_none());
        assert!(parse_key(&"zz".repeat(32)).is_none());
    }
}
