mod socket;

pub use socket::run;

use std::sync::Arc;

use crate::config::{Config, ProviderKind};
use crate::provider::{AiProvider, AnthropicProvider, OllamaProvider};

pub struct AppState {
    pub config: Config,
    pub primary: Arc<dyn AiProvider>,
    pub secondary: Option<Arc<dyn AiProvider>>,
}

impl AppState {
    pub fn new(config: Config) -> Self {
        let local: Arc<dyn AiProvider> =
            Arc::new(OllamaProvider::new(&config.local, config.max_suggestions));
        let cloud: Option<Arc<dyn AiProvider>> = AnthropicProvider::new(&config.cloud, config.max_suggestions)
            .map(|p| Arc::new(p) as Arc<dyn AiProvider>);

        let (primary, secondary) = match config.provider {
            ProviderKind::Local => (local, cloud),
            ProviderKind::Cloud => match cloud.clone() {
                Some(cloud) => (cloud, Some(local)),
                None => {
                    eprintln!(
                        "ai-suggest-daemon: provider = \"cloud\" but no API key found in env; \
                         falling back to local"
                    );
                    (local, None)
                }
            },
        };

        Self {
            config,
            primary,
            secondary,
        }
    }
}
