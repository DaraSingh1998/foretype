//! Bring-your-own inference server: a llama.cpp `llama-server` (`/completion`) or any
//! OpenAI-compatible completions endpoint (`/v1/completions`: Ollama, LM Studio, vLLM, or a
//! cloud provider). Responses are streamed so a new keystroke can abandon a request between
//! chunks (closing the connection makes llama-server stop generating).
//!
//! Token healing: llama-server gets a GBNF grammar that forces the output to start with the
//! typed fragment, as the in-process engine does with logit masking. OpenAI-style endpoints
//! have no grammar, so they get the prompt *without* the partial word and the reply is used
//! only if it starts with what the user typed. That prompt is the same for every keystroke
//! inside a word, so one reply is cached and filtered locally until the word ends. When the
//! typed letters leave that guess, a second request sends the partial word itself.
//! The personal-vocabulary bias needs logits and is only available in-process.

use std::io::{BufRead, BufReader};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::context::Prompt;
use crate::engine::{Completion, GenError, GenOptions};
use crate::words;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    LlamaServer,
    OpenAi,
}

pub struct HttpBackend {
    kind: Kind,
    base: String,
    model: String,
    api_key: String,
    agent: ureq::Agent,
    /// OpenAI-style: last (prompt, raw continuation), reused while the prompt is unchanged.
    last: Mutex<Option<(String, String)>>,
}

/// A GBNF string literal for `s`.
fn gbnf_literal(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

impl HttpBackend {
    pub fn new(kind: &str, url: &str, model: &str, api_key: &str) -> Result<Self, String> {
        let kind = match kind {
            "llama-server" => Kind::LlamaServer,
            "openai" => Kind::OpenAi,
            other => return Err(format!("unknown backend '{other}' (llama-server | openai)")),
        };
        let base = url.trim().trim_end_matches('/').to_string();
        if !(base.starts_with("http://") || base.starts_with("https://")) {
            return Err(format!("backend URL must start with http:// or https://: {base}"));
        }
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(2))
            .timeout_read(Duration::from_secs(15))
            .build();
        Ok(Self { kind, base, model: model.to_string(), api_key: api_key.to_string(), agent, last: Mutex::new(None) })
    }

    pub fn describe(&self) -> String {
        match self.kind {
            Kind::LlamaServer => format!("llama-server at {}", self.base),
            Kind::OpenAi => format!("OpenAI-compatible server at {} ({})", self.base, self.model),
        }
    }

    fn post(&self, path: &str, body: Value) -> Result<ureq::Response, String> {
        let mut req = self.agent.post(&format!("{}{}", self.base, path)).set("Content-Type", "application/json");
        if !self.api_key.is_empty() {
            req = req.set("Authorization", &format!("Bearer {}", self.api_key));
        }
        req.send_string(&body.to_string()).map_err(|e| e.to_string())
    }

    /// Prefills the prompt on llama-server (zero-token request); a no-op elsewhere.
    pub fn warm(&self, prefix: &str) -> Result<usize, GenError> {
        if self.kind != Kind::LlamaServer {
            return Ok(0);
        }
        self.post("/completion", json!({ "prompt": prefix, "n_predict": 0, "cache_prompt": true }))
            .map(|_| 0)
            .map_err(GenError::Failed)
    }

    pub fn complete(&self, prompt: &Prompt, opts: &GenOptions, cancel: &dyn Fn() -> bool) -> Result<Completion, GenError> {
        let t0 = Instant::now();
        if self.kind == Kind::OpenAi {
            let cached = self.last.lock().unwrap().as_ref().filter(|(p, _)| *p == prompt.prefix).map(|(_, raw)| raw.clone());
            let raw = match cached {
                Some(raw) => raw,
                None => {
                    let raw = self.stream_openai(&prompt.prefix, opts, cancel)?;
                    *self.last.lock().unwrap() = Some((prompt.prefix.clone(), raw.clone()));
                    raw
                }
            };
            let c = Self::filtered(&raw, prompt, opts, "maxTokens", t0);
            if !c.text.is_empty() || prompt.fragment.trim().is_empty() {
                return Ok(c);
            }
            // The guess for this word no longer matches: continue from the typed letters.
            let tail = self.stream_openai(&format!("{}{}", prompt.prefix, prompt.fragment), opts, cancel)?;
            let joined = format!("{}{}", prompt.fragment, tail);
            return Ok(Self::filtered(&joined, prompt, opts, "maxTokens", t0));
        }
        let max_tokens = opts.max_words * 3 + 8 + prompt.fragment.len();
        let (path, body) = match self.kind {
            Kind::LlamaServer => {
                let mut b = json!({
                    "prompt": prompt.prefix, "n_predict": max_tokens, "cache_prompt": true, "stream": true,
                    "temperature": 0.0, "top_k": 1, "stop": ["\n"],
                });
                if !prompt.fragment.is_empty() {
                    b["grammar"] = json!(format!("root ::= {} [^\\n]*", gbnf_literal(&prompt.fragment)));
                }
                ("/completion", b)
            }
            Kind::OpenAi => (
                "/v1/completions",
                json!({
                    "model": self.model, "prompt": prompt.prefix,
                    "max_tokens": max_tokens, "temperature": 0.0, "stream": true, "stop": ["\n"],
                }),
            ),
        };
        let resp = self.post(path, body).map_err(GenError::Failed)?;
        let mut out = String::new();
        let mut chunks = 0usize;
        let mut prefilled = 0usize;
        let mut stop = "maxTokens";
        for line in BufReader::new(resp.into_reader()).lines() {
            if cancel() {
                return Err(GenError::Cancelled);
            }
            let line = line.map_err(|e| GenError::Failed(e.to_string()))?;
            let Some(data) = line.strip_prefix("data: ") else { continue };
            if data.trim() == "[DONE]" {
                stop = "eog";
                break;
            }
            let Ok(v) = serde_json::from_str::<Value>(data) else { continue };
            let piece = match self.kind {
                Kind::LlamaServer => v["content"].as_str().unwrap_or(""),
                Kind::OpenAi => v["choices"][0]["text"].as_str().unwrap_or(""),
            };
            out.push_str(piece);
            chunks += 1;
            if let Some(n) = v["timings"]["prompt_n"].as_u64() {
                prefilled = n as usize;
            }
            if v["stop"].as_bool() == Some(true) || v["choices"][0]["finish_reason"].is_string() {
                stop = "eog";
                break;
            }
            if out.contains('\n') {
                stop = "newline";
                break;
            }
            // Enough words: stop reading (the server stops when the connection closes).
            let shown = out.strip_prefix(prompt.fragment.as_str()).unwrap_or("");
            if words::count_words(shown) > opts.max_words + 1 {
                stop = "words";
                break;
            }
        }
        if self.kind == Kind::OpenAi {
            *self.last.lock().unwrap() = Some((prompt.prefix.clone(), out.clone()));
            return Ok(Self::filtered(&out, prompt, opts, stop, t0));
        }
        let mut c = Self::filtered(&out, prompt, opts, stop, t0);
        c.prefilled_tokens = prefilled;
        c.generated_tokens = chunks;
        Ok(c)
    }

    /// Streams an OpenAI-style completion of `text`, stopping early at a newline or once
    /// enough words have arrived.
    fn stream_openai(&self, text: &str, opts: &GenOptions, cancel: &dyn Fn() -> bool) -> Result<String, GenError> {
        let body = json!({
            "model": self.model, "prompt": text, "max_tokens": opts.max_words * 3 + 12,
            "temperature": 0.0, "stream": true, "stop": ["\n"],
        });
        let resp = self.post("/v1/completions", body).map_err(GenError::Failed)?;
        let mut out = String::new();
        for line in BufReader::new(resp.into_reader()).lines() {
            if cancel() {
                return Err(GenError::Cancelled);
            }
            let line = line.map_err(|e| GenError::Failed(e.to_string()))?;
            let Some(data) = line.strip_prefix("data: ") else { continue };
            if data.trim() == "[DONE]" {
                break;
            }
            let Ok(v) = serde_json::from_str::<Value>(data) else { continue };
            out.push_str(v["choices"][0]["text"].as_str().unwrap_or(""));
            if out.contains('\n') || words::count_words(&out) > opts.max_words + 2 || v["choices"][0]["finish_reason"].is_string() {
                break;
            }
        }
        Ok(out)
    }

    /// The part of `raw` after the typed fragment, limited to the requested words; empty if
    /// the continuation does not start with what the user typed.
    fn filtered(raw: &str, prompt: &Prompt, opts: &GenOptions, stop: &'static str, t0: Instant) -> Completion {
        let shown = raw.split('\n').next().unwrap_or("");
        let text = match shown.strip_prefix(prompt.fragment.as_str()) {
            Some(rest) => words::limit(rest, opts.max_words, opts.stop_at_sentence_end, stop == "maxTokens" || stop == "words"),
            None => String::new(),
        };
        Completion {
            text,
            prompt_tokens: 0,
            prefilled_tokens: 0,
            generated_tokens: 0,
            prefill_ms: 0.0,
            total_ms: t0.elapsed().as_secs_f64() * 1000.0,
            stop,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grammar_literal_escapes() {
        assert_eq!(gbnf_literal(" say \"hi\"\\"), r#"" say \"hi\"\\""#);
    }

    #[test]
    fn rejects_bad_config() {
        assert!(HttpBackend::new("llama-server", "localhost:8080", "", "").is_err());
        assert!(HttpBackend::new("grpc", "http://x", "", "").is_err());
        assert!(HttpBackend::new("openai", "http://127.0.0.1:11434/", "qwen3", "").is_ok());
    }
}
