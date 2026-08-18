# Feature: Smart `rm` Command Suggestions

## Overview

Lumen now suggests common deletable files and folders when you use the `rm` command with flags like `-rf`, `-r`, or `-f`. This helps you quickly clean up build artifacts, caches, dependencies, and temporary files without memorizing what to delete.

## Usage

Simply type `rm` with any flags, and Lumen will suggest common patterns:

```bash
rm -rf [space]
# Lumen shows: node_modules, .build, dist, .cache, .DS_Store, etc.

rm -rf node
# Lumen shows: node_modules [exists]

rm -r .b
# Lumen shows: .build, .bundle
```

## What Gets Suggested

Lumen suggests 40+ commonly-deleted patterns organized by category:

| Category | Examples |
|----------|----------|
| **Build artifacts** | `.build`, `build/`, `dist/`, `target/`, `DerivedData/`, `.gradle/` |
| **Dependencies** | `node_modules/`, `vendor/`, `.bundle/`, `bower_components/` |
| **Caches** | `.cache/`, `.npm/`, `.yarn/`, `__pycache__/`, `.next/`, `.turbo/` |
| **System files** | `.DS_Store`, `Thumbs.db`, `desktop.ini` |
| **Temp/Logs** | `tmp/`, `logs/`, `*.log`, `coverage/`, `.coverage` |

## Smart Features

### Existence Checking
Lumen shows `[exists]` next to items that are actually present in your current directory:

```bash
# In a Node.js project:
rm -rf node
# Shows: node_modules [exists] - Node.js dependencies
```

### Category Labels
Each suggestion shows what type of file it is:
- "Build artifacts" - compiled code and build outputs
- "Dependencies" - package manager dependencies
- "Cache" - temporary cache directories
- "System files" - OS-generated metadata
- "Temp files" - logs and temporary data

### Icon Integration
Suggestions use Lumen's icon system to visually distinguish items (shown as "dir" icons in the overlay panel).

## Implementation Details

The feature integrates seamlessly with Lumen's existing matcher system:

1. **Triggers** on `rm` commands with flags (`-r`, `-f`, `-rf`, etc.)
2. **Scans** the current directory for matching patterns
3. **Shows** relevant suggestions with descriptions
4. **Respects** Lumen's performance limits (max 50 candidates)

### Code Structure

- **Matcher function**: `_lumen_rm_match()` in `shell/zsh/lumen.plugin.zsh`
- **Pattern database**: 40+ entries with name, description, and category
- **Integration point**: Called in `_lumen_static_or_dynamic_match()` priority list

### Performance

- Uses zsh's efficient glob matching
- No external commands or network calls
- Checks file existence only for matched patterns
- Instant response time (< 1ms)

## Future Enhancements

Potential improvements for future versions:

1. **Size indicators**: Show disk space that would be freed
2. **Age indicators**: Show when files were last modified
3. **Danger warnings**: Highlight potentially dangerous deletions
4. **Custom patterns**: Let users add their own common patterns
5. **Project-aware**: Detect project type and suggest relevant artifacts
6. **Git-aware**: Suggest only gitignored items

## Examples in Real Projects

### Swift Project
```bash
cd ~/my-swift-project
rm -rf 
# Suggests: .build [exists], DerivedData [exists], .DS_Store [exists]
```

### Node.js Project
```bash
cd ~/my-web-app
rm -rf 
# Suggests: node_modules [exists], dist [exists], .next [exists], .cache [exists]
```

### Python Project
```bash
cd ~/my-python-app
rm -rf 
# Suggests: __pycache__ [exists], .pytest_cache [exists], .mypy_cache, .tox
```

### Multi-Language Monorepo
```bash
cd ~/my-monorepo
rm -rf 
# Suggests all relevant patterns from all categories
```

## Safety Notes

⚠️ **Important**: This feature only provides *suggestions* — it doesn't modify Lumen's safety behavior. Always review what you're deleting, especially with `rm -rf`!

The `[exists]` indicator helps you verify that:
1. The file/folder is actually present
2. You're in the right directory
3. You're about to delete what you intend

## Technical Details

### Matching Logic

The matcher handles various `rm` command forms:

```bash
rm -rf node_modules    # Works
rm -r node_modules     # Works
rm -f something        # Works
rm -rfv build          # Works (any flags)
rm node_modules        # Doesn't trigger (no flags)
```

### Pattern Format

Each pattern is defined as:
```zsh
$'name\tdescription\tcategory'
```

Example:
```zsh
$'node_modules\tNode.js dependencies\tDependencies'
```

### Directory Structure

The implementation is contained entirely in the Zsh plugin:
```
shell/zsh/lumen.plugin.zsh
├── _lumen_rm_match()          # Main matcher function
└── deletion_patterns array     # 40+ common patterns
```

## Contributing

To add new patterns:

1. Edit `shell/zsh/lumen.plugin.zsh`
2. Find the `deletion_patterns` array in `_lumen_rm_match()`
3. Add entries in the format: `$'name\tdescription\tcategory'`
4. Test with: `source ~/lumen/shell/zsh/lumen.plugin.zsh`
5. Submit a pull request!

Popular patterns to consider adding:
- Framework-specific caches (`.angular/`, `.vuepress/`)
- IDE directories (`.idea/`, `.vscode/`)
- Lock files that regenerate (`.lock`, `package-lock.json`)
- Language-specific outputs (`*.pyc`, `*.class`, `*.o`)

## Changelog

### v1.0.0 (Initial Release)
- ✅ Detects `rm -rf`, `rm -r`, `rm -f` commands
- ✅ Suggests 40+ common deletable patterns
- ✅ Shows existence indicators
- ✅ Categorizes suggestions (Build/Dependencies/Cache/System/Temp)
- ✅ Integrates with Lumen's icon system
- ✅ Zero performance impact
