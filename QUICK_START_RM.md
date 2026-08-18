# Quick Start: rm Suggestions in Lumen

## Try It Now

```bash
# 1. Make sure Lumen is running (menu bar icon)

# 2. Reload your shell
source ~/.zshrc

# 3. Type this and watch the magic ✨
rm -rf 

# 4. Start typing to filter
rm -rf node     # Shows: node_modules
rm -rf .b       # Shows: .build, .bundle
```

## What You'll See

Lumen's floating panel will show:
- **Pattern name** (e.g., `node_modules`)
- **Description** (e.g., "Node.js dependencies")
- **Existence marker** (`[exists]` if present)
- **Category** (Build artifacts, Dependencies, Cache, etc.)

## Common Patterns

| What to delete | Type this |
|----------------|-----------|
| Node modules | `rm -rf node` |
| Build output | `rm -rf build` or `rm -rf dist` |
| Swift builds | `rm -rf .build` |
| Python cache | `rm -rf __py` |
| npm cache | `rm -rf .npm` |
| .DS_Store | `rm -rf .DS` |
| All caches | `rm -rf .c` then browse |

## Controls

- **Up/Down arrows** - Navigate suggestions
- **Tab / Enter / Right arrow** - Accept suggestion
- **Ctrl+G** - Dismiss panel
- **Ctrl+Space** - Force show suggestions

## Works With Any Flags

```bash
rm -rf          # ✅ Works
rm -r           # ✅ Works
rm -f           # ✅ Works
rm -rfv         # ✅ Works
rm              # ❌ Doesn't trigger (needs flags)
```

## What Gets Suggested

**40+ patterns including:**

🏗️ **Build** - `.build`, `build`, `dist`, `target`, `out`, `DerivedData`

📦 **Dependencies** - `node_modules`, `vendor`, `.bundle`

💾 **Cache** - `.cache`, `.npm`, `.yarn`, `__pycache__`, `.next`, `.turbo`

🖥️ **System** - `.DS_Store`, `Thumbs.db`

📝 **Temp/Logs** - `tmp`, `logs`, `*.log`, `coverage`

## Troubleshooting

**Panel not showing?**
1. Is Lumen.app running? (check menu bar)
2. Accessibility permission granted? (System Settings → Privacy & Security)
3. Plugin loaded? Run: `source ~/.zshrc`

**No suggestions?**
1. Did you type flags? (needs `-rf`, `-r`, or `-f`)
2. Try: `rm -rf ` with space after flags
3. Check log: `tail -f /tmp/lumen-overlay-debug.log`

**Wrong suggestions?**
1. Type more letters to filter: `rm -rf node` instead of `rm -rf n`
2. Only items matching your input are shown

## Safety Tips

⚠️ This feature suggests patterns — it doesn't prevent mistakes!

- The `[exists]` marker helps verify you're deleting the right thing
- Always review what you're about to delete
- `rm -rf` is destructive and permanent
- Consider using `rm -rfi` for interactive confirmation

## Examples by Project Type

### JavaScript/Node.js
```bash
rm -rf node    # node_modules
rm -rf .n      # .next, .npm, .nuxt, .nyc_output
rm -rf dist    # dist
```

### Swift/iOS
```bash
rm -rf .b      # .build
rm -rf Der     # DerivedData
```

### Python
```bash
rm -rf __p     # __pycache__
rm -rf .p      # .pytest_cache, .pnpm-store
```

### Rust
```bash
rm -rf tar     # target
```

### Java
```bash
rm -rf tar     # target
rm -rf .g      # .gradle
```

## More Info

- Full docs: `FEATURE_RM_SUGGESTIONS.md`
- Test it: `./examples/rm_suggestions_demo.sh`
- Implementation: `IMPLEMENTATION_SUMMARY.md`
