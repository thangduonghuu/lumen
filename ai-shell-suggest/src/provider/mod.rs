mod cloud;
mod local;

pub use cloud::AnthropicProvider;
pub use local::OllamaProvider;

use async_trait::async_trait;

use crate::context::Context;
use crate::protocol::Suggestion;

#[async_trait]
pub trait AiProvider: Send + Sync {
    async fn suggest(&self, ctx: &Context) -> anyhow::Result<Vec<Suggestion>>;
    fn name(&self) -> &'static str;
}

/// System-style instruction shared by every provider so prompt shape stays
/// consistent regardless of backend.
pub(crate) fn build_prompt(ctx: &Context, max_suggestions: usize) -> String {
    let mut prompt = String::new();
    prompt.push_str(
        "You are a shell command suggestion engine embedded in a terminal. \
         Given the context below, suggest up to ",
    );
    prompt.push_str(&max_suggestions.to_string());
    prompt.push_str(
        " likely shell commands the user wants to run next. \
         Respond ONLY with a JSON array of objects (no markdown, no explanation), \
         each shaped like {\"command\": \"...\", \"description\": \"...\"}. \
         \"command\" is a complete, ready-to-run shell command line. \
         \"description\" is a short (under 8 words) plain-English summary of what \
         that command does.\n\n",
    );

    prompt.push_str(&format!("Current directory: {}\n", ctx.cwd));

    if !ctx.project_types.is_empty() {
        prompt.push_str(&format!("Project type(s): {}\n", ctx.project_types.join(", ")));
    }
    if let Some(branch) = &ctx.git_branch {
        prompt.push_str(&format!("Git branch: {branch}\n"));
    }
    if let Some(dirty) = ctx.git_dirty_count {
        prompt.push_str(&format!("Git dirty files: {dirty}\n"));
    }
    if !ctx.recent_history.is_empty() {
        prompt.push_str("Recent commands:\n");
        for cmd in &ctx.recent_history {
            prompt.push_str(&format!("  {cmd}\n"));
        }
    }

    prompt.push_str(&format!("\nUser is currently typing: \"{}\"\n", ctx.buffer));
    prompt.push_str("JSON array response:");
    prompt
}

/// Raw shape of one entry when the model does follow the JSON-object
/// instruction; kept separate from `Suggestion` since the wire protocol
/// type shouldn't need to know about this parsing detail.
#[derive(serde::Deserialize)]
struct RawSuggestion {
    command: String,
    #[serde(default)]
    description: Option<String>,
}

/// Providers are expected to return a JSON array of `{command, description}`
/// objects. Models don't always follow instructions, so this falls back
/// through two looser shapes: a JSON array of plain strings (description
/// omitted), then finally treating each non-empty line as one command
/// (also no description).
pub(crate) fn parse_suggestions(raw: &str, max_suggestions: usize) -> Vec<Suggestion> {
    let trimmed = raw.trim();
    let json_candidate = extract_json_array(trimmed).unwrap_or(trimmed);

    if let Ok(list) = serde_json::from_str::<Vec<RawSuggestion>>(json_candidate) {
        return list
            .into_iter()
            .take(max_suggestions)
            .map(|r| Suggestion {
                command: r.command,
                description: r.description,
            })
            .collect();
    }

    if let Ok(list) = serde_json::from_str::<Vec<String>>(json_candidate) {
        return list
            .into_iter()
            .take(max_suggestions)
            .map(|command| Suggestion {
                command,
                description: None,
            })
            .collect();
    }

    trimmed
        .lines()
        .map(|l| {
            l.trim()
                .trim_start_matches(|c: char| c.is_ascii_digit() || c == '.' || c == '-' || c == '*')
                .trim()
        })
        .filter(|l| !l.is_empty())
        .take(max_suggestions)
        .map(|command| Suggestion {
            command: command.to_string(),
            description: None,
        })
        .collect()
}

fn extract_json_array(s: &str) -> Option<&str> {
    let start = s.find('[')?;
    let end = s.rfind(']')?;
    if end > start {
        Some(&s[start..=end])
    } else {
        None
    }
}
