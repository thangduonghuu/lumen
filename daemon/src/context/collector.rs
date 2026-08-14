use std::path::Path;
use std::process::Command;

use super::Context;

const PROJECT_MARKERS: &[(&str, &str)] = &[
    ("Cargo.toml", "Rust"),
    ("package.json", "Node.js"),
    ("requirements.txt", "Python"),
    ("pyproject.toml", "Python"),
    ("go.mod", "Go"),
    ("Gemfile", "Ruby"),
    ("pom.xml", "Java (Maven)"),
    ("build.gradle", "Java/Kotlin (Gradle)"),
];

/// Gathers everything a provider needs to produce a suggestion: what the
/// user is typing, recent history the client already collected, and
/// cheap-to-compute local signals (project type, git state).
///
/// Blocking (spawns `git`); callers should run this inside
/// `tokio::task::spawn_blocking`.
pub fn collect(buffer: String, cwd: String, recent_history: Vec<String>) -> Context {
    let cwd_path = Path::new(&cwd);

    let project_types = PROJECT_MARKERS
        .iter()
        .filter(|(marker, _)| cwd_path.join(marker).exists())
        .map(|(_, label)| *label)
        .collect();

    let git_branch = run_git(&cwd, &["rev-parse", "--abbrev-ref", "HEAD"])
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && s != "HEAD");

    let git_dirty_count = run_git(&cwd, &["status", "--porcelain"])
        .map(|s| s.lines().filter(|l| !l.trim().is_empty()).count());

    Context {
        buffer,
        cwd,
        recent_history,
        project_types,
        git_branch,
        git_dirty_count,
    }
}

fn run_git(cwd: &str, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(args)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout).ok()
}
