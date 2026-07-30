use serde::{Deserialize, Serialize};

/// One request sent from the zsh client to the daemon over the unix socket,
/// terminated by a newline (newline-delimited JSON, one exchange per connection).
#[derive(Debug, Serialize, Deserialize)]
pub struct SuggestRequest {
    pub buffer: String,
    pub cwd: String,
    #[serde(default)]
    pub recent_history: Vec<String>,
}

/// A single candidate. `description` is optional because the plain
/// line-based fallback in `parse_suggestions` (used when a model ignores
/// the JSON-object instruction) has no way to produce one.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Suggestion {
    pub command: String,
    #[serde(default)]
    pub description: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SuggestResponse {
    pub suggestions: Vec<Suggestion>,
    pub provider_used: String,
    #[serde(default)]
    pub error: Option<String>,
}
