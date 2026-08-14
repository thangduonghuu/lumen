use ai_suggest::config::Config;
use ai_suggest::daemon::{self, AppState};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = Config::load_or_init()?;
    let state = AppState::new(config);
    daemon::run(state).await
}
