use std::time::Duration;

use ai_suggest::config::Config;
use ai_suggest::protocol::{SuggestRequest, SuggestResponse};
use anyhow::{Context, Result};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

/// Usage: ai-suggest-client <buffer> <cwd> [history_line...]
///
/// Thin, short-lived client: connects to the daemon (auto-spawning it if
/// it's not running yet), sends one request, prints one suggestion per
/// line to stdout, and exits. Meant to be run from the zsh plugin.
#[tokio::main]
async fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let buffer = args.next().unwrap_or_default();
    let cwd = args
        .next()
        .unwrap_or_else(|| std::env::current_dir().map(|p| p.display().to_string()).unwrap_or_default());
    let recent_history: Vec<String> = args.collect();

    let config = Config::load_or_init()?;
    let socket_path = config.socket_path()?;

    let stream = match UnixStream::connect(&socket_path).await {
        Ok(s) => s,
        Err(_) => {
            spawn_daemon()?;
            connect_with_retry(&socket_path).await?
        }
    };

    let request = SuggestRequest {
        buffer,
        cwd,
        recent_history,
    };
    let mut line = serde_json::to_string(&request)?;
    line.push('\n');

    let (read_half, mut write_half) = stream.into_split();
    write_half.write_all(line.as_bytes()).await?;
    write_half.flush().await?;

    let mut reader = BufReader::new(read_half);
    let mut resp_line = String::new();
    reader.read_line(&mut resp_line).await?;

    let response: SuggestResponse = serde_json::from_str(resp_line.trim())?;
    // One candidate per line, tab-separated command/description so the zsh
    // plugin can split on \t without needing a JSON parser. Tabs and
    // newlines are stripped from both fields since they'd otherwise corrupt
    // this framing (a model could plausibly emit either inside a
    // description, or even inside a shell command via $'\t').
    for suggestion in response.suggestions {
        let command = sanitize_field(&suggestion.command);
        let description = suggestion.description.as_deref().map(sanitize_field).unwrap_or_default();
        println!("{command}\t{description}");
    }
    if let Some(err) = response.error {
        eprintln!("ai-suggest-client: {} error: {err}", response.provider_used);
    }
    Ok(())
}

fn sanitize_field(s: &str) -> String {
    s.chars()
        .map(|c| if c == '\t' || c == '\n' || c == '\r' { ' ' } else { c })
        .collect::<String>()
        .trim()
        .to_string()
}

fn spawn_daemon() -> Result<()> {
    let exe = std::env::current_exe().context("resolving current exe path")?;
    let daemon_path = exe
        .parent()
        .context("resolving exe dir")?
        .join("ai-suggest-daemon");

    std::process::Command::new(daemon_path)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .context("spawning ai-suggest-daemon")?;
    Ok(())
}

async fn connect_with_retry(socket_path: &std::path::Path) -> Result<UnixStream> {
    let mut last_err = None;
    for _ in 0..20 {
        tokio::time::sleep(Duration::from_millis(50)).await;
        match UnixStream::connect(socket_path).await {
            Ok(s) => return Ok(s),
            Err(e) => last_err = Some(e),
        }
    }
    Err(last_err.unwrap()).context("daemon did not come up in time")
}
