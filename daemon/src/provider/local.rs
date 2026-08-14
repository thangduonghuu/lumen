use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context as _};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use tokio::sync::Semaphore;

use crate::config::LocalConfig;
use crate::context::Context;
use crate::protocol::Suggestion;

use super::{build_prompt, parse_suggestions, AiProvider};

/// A single local model instance can't usefully serve concurrent requests —
/// they just queue up on the same GPU/CPU anyway — so a burst of keystrokes
/// (each debounced request only cancels the *previous client*, not an
/// already-in-flight Ollama call, see the zsh plugin's cancel comment) would
/// otherwise stack up several multi-second calls at once and make the whole
/// machine sluggish. Capping in-flight requests to 1 turns that pile-up into
/// an orderly queue instead.
const MAX_CONCURRENT_REQUESTS: usize = 1;

pub struct OllamaProvider {
    client: reqwest::Client,
    host: String,
    model: String,
    max_suggestions: usize,
    limiter: Arc<Semaphore>,
}

impl OllamaProvider {
    pub fn new(cfg: &LocalConfig, max_suggestions: usize) -> Self {
        Self {
            // Generous on purpose: Ollama has to cold-load the model into
            // memory on its first request (observed 10s+ for a 14B model),
            // on top of the model's own generation time. Once warm it stays
            // loaded for Ollama's keep_alive window (5 minutes by default),
            // so this timeout is really only ever hit by that first request
            // or a genuinely stuck server — steady-state calls return in a
            // few seconds either way.
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(45))
                .build()
                .expect("failed to build reqwest client"),
            host: cfg.host.clone(),
            model: cfg.model.clone(),
            max_suggestions,
            limiter: Arc::new(Semaphore::new(MAX_CONCURRENT_REQUESTS)),
        }
    }
}

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'a str,
    messages: Vec<ChatMessage<'a>>,
    stream: bool,
}

#[derive(Serialize)]
struct ChatMessage<'a> {
    role: &'a str,
    content: String,
}

#[derive(Deserialize)]
struct ChatResponse {
    message: ChatResponseMessage,
}

#[derive(Deserialize)]
struct ChatResponseMessage {
    content: String,
}

#[async_trait]
impl AiProvider for OllamaProvider {
    async fn suggest(&self, ctx: &Context) -> anyhow::Result<Vec<Suggestion>> {
        // If a request is already running, waiting here for it to finish is
        // strictly better than firing an overlapping one: same total work,
        // but the model isn't context-switching between two prompts at once.
        let _permit = self
            .limiter
            .acquire()
            .await
            .context("suggestion queue closed")?;

        let prompt = build_prompt(ctx, self.max_suggestions);
        let url = format!("{}/api/chat", self.host.trim_end_matches('/'));

        let req = ChatRequest {
            model: &self.model,
            messages: vec![ChatMessage {
                role: "user",
                content: prompt,
            }],
            stream: false,
        };

        let resp = self.client.post(&url).json(&req).send().await.map_err(|e| {
            if e.is_timeout() {
                anyhow::anyhow!("Ollama didn't respond in time (model still loading, or overloaded)")
            } else {
                anyhow::Error::new(e).context("failed to reach Ollama (is `ollama serve` running?)")
            }
        })?;

        if !resp.status().is_success() {
            bail!("Ollama returned HTTP {}", resp.status());
        }

        let body: ChatResponse = resp.json().await.context("invalid Ollama response body")?;
        Ok(parse_suggestions(&body.message.content, self.max_suggestions))
    }

    fn name(&self) -> &'static str {
        "local:ollama"
    }
}
