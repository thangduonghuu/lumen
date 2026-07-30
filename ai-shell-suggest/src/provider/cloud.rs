use std::time::Duration;

use anyhow::{bail, Context as _};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::config::CloudConfig;
use crate::context::Context;
use crate::protocol::Suggestion;

use super::{build_prompt, parse_suggestions, AiProvider};

pub struct AnthropicProvider {
    client: reqwest::Client,
    api_key: String,
    model: String,
    max_suggestions: usize,
}

impl AnthropicProvider {
    /// Returns `None` if no API key is configured/available in the
    /// environment, so the daemon can skip constructing a cloud provider
    /// entirely rather than fail on every request.
    pub fn new(cfg: &CloudConfig, max_suggestions: usize) -> Option<Self> {
        let api_key = cfg.api_key.clone()?;
        Some(Self {
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(15))
                .build()
                .expect("failed to build reqwest client"),
            api_key,
            model: cfg.model.clone(),
            max_suggestions,
        })
    }
}

#[derive(Serialize)]
struct MessagesRequest<'a> {
    model: &'a str,
    max_tokens: u32,
    messages: Vec<Message<'a>>,
}

#[derive(Serialize)]
struct Message<'a> {
    role: &'a str,
    content: String,
}

#[derive(Deserialize)]
struct MessagesResponse {
    content: Vec<ContentBlock>,
}

#[derive(Deserialize)]
struct ContentBlock {
    #[serde(default)]
    text: String,
}

#[async_trait]
impl AiProvider for AnthropicProvider {
    async fn suggest(&self, ctx: &Context) -> anyhow::Result<Vec<Suggestion>> {
        let prompt = build_prompt(ctx, self.max_suggestions);

        let req = MessagesRequest {
            model: &self.model,
            max_tokens: 512,
            messages: vec![Message {
                role: "user",
                content: prompt,
            }],
        };

        let resp = self
            .client
            .post("https://api.anthropic.com/v1/messages")
            .header("x-api-key", &self.api_key)
            .header("anthropic-version", "2023-06-01")
            .json(&req)
            .send()
            .await
            .context("failed to reach Anthropic API")?;

        if !resp.status().is_success() {
            bail!("Anthropic API returned HTTP {}", resp.status());
        }

        let body: MessagesResponse = resp.json().await.context("invalid Anthropic response body")?;
        let text = body
            .content
            .into_iter()
            .map(|b| b.text)
            .collect::<Vec<_>>()
            .join("\n");
        Ok(parse_suggestions(&text, self.max_suggestions))
    }

    fn name(&self) -> &'static str {
        "cloud:anthropic"
    }
}
