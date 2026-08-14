mod collector;

pub use collector::collect;

#[derive(Debug, Clone)]
pub struct Context {
    pub buffer: String,
    pub cwd: String,
    pub recent_history: Vec<String>,
    pub project_types: Vec<&'static str>,
    pub git_branch: Option<String>,
    pub git_dirty_count: Option<usize>,
}
