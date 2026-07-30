use std::sync::Arc;

use anyhow::{Context as _, Result};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

use crate::context::collect;
use crate::protocol::{SuggestRequest, SuggestResponse};

use super::AppState;

pub async fn run(state: AppState) -> Result<()> {
    let socket_path = state.config.socket_path()?;
    if let Some(parent) = socket_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    if socket_path.exists() {
        if UnixStream::connect(&socket_path).await.is_ok() {
            anyhow::bail!("a daemon is already listening on {}", socket_path.display());
        }
        std::fs::remove_file(&socket_path)
            .with_context(|| format!("removing stale socket {}", socket_path.display()))?;
    }

    let listener = UnixListener::bind(&socket_path)
        .with_context(|| format!("binding {}", socket_path.display()))?;
    eprintln!(
        "ai-suggest-daemon: listening on {} (primary provider: {})",
        socket_path.display(),
        state.primary.name()
    );

    let state = Arc::new(state);
    loop {
        let (stream, _) = listener.accept().await?;
        let state = state.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_connection(stream, state).await {
                eprintln!("ai-suggest-daemon: connection error: {e:#}");
            }
        });
    }
}

async fn handle_connection(stream: UnixStream, state: Arc<AppState>) -> Result<()> {
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    let mut line = String::new();
    let n = reader.read_line(&mut line).await?;
    if n == 0 {
        return Ok(());
    }

    let request: SuggestRequest = serde_json::from_str(line.trim())?;
    let response = build_response(&state, request).await;

    let mut out = serde_json::to_string(&response)?;
    out.push('\n');
    write_half.write_all(out.as_bytes()).await?;
    write_half.flush().await?;
    Ok(())
}

async fn build_response(state: &AppState, request: SuggestRequest) -> SuggestResponse {
    let ctx = tokio::task::spawn_blocking(move || {
        collect(request.buffer, request.cwd, request.recent_history)
    })
    .await
    .expect("context collection panicked");

    match state.primary.suggest(&ctx).await {
        Ok(suggestions) => SuggestResponse {
            suggestions,
            provider_used: state.primary.name().to_string(),
            error: None,
        },
        Err(primary_err) => {
            if state.config.fallback_to_local_on_cloud_error {
                if let Some(secondary) = &state.secondary {
                    if let Ok(suggestions) = secondary.suggest(&ctx).await {
                        return SuggestResponse {
                            suggestions,
                            provider_used: secondary.name().to_string(),
                            error: None,
                        };
                    }
                }
            }
            SuggestResponse {
                suggestions: vec![],
                provider_used: state.primary.name().to_string(),
                error: Some(primary_err.to_string()),
            }
        }
    }
}
