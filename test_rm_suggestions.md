# Testing rm Suggestions Feature

## What This Feature Does

The new `rm` matcher suggests common deletable files and folders when you type `rm -rf ` (or other flag combinations). It shows:

- **Build artifacts**: `.build`, `build`, `dist`, `target`, `DerivedData`, etc.
- **Dependencies**: `node_modules`, `vendor`, `.bundle`, etc.
- **Caches**: `.cache`, `.npm`, `.yarn`, `__pycache__`, etc.
- **System files**: `.DS_Store`, `Thumbs.db`, etc.
- **Temp files**: `tmp`, `logs`, `*.log`, etc.

## How to Test

1. **Reload your shell** with the updated plugin:
   ```bash
   source ~/lumen/shell/zsh/lumen.plugin.zsh
   ```

2. **Test basic rm suggestions**:
   ```bash
   rm -rf 
   # Should show all common deletable patterns
   ```

3. **Test with partial matches**:
   ```bash
   rm -rf node
   # Should show: node_modules
   
   rm -rf .b
   # Should show: .build, .bundle
   
   rm -rf bu
   # Should show: build
   ```

4. **Test in a real project directory**:
   ```bash
   cd ~/lumen/Lumen
   rm -rf 
   # Should show .build [exists], .DS_Store [exists], etc.
   ```

5. **Test different flag combinations**:
   ```bash
   rm -r 
   # Should work
   
   rm -f 
   # Should work
   
   rm -rfv 
   # Should work
   ```

## Expected Behavior

- Suggestions appear in a floating panel as you type
- Items that exist in your current directory show `[exists]` marker
- Each suggestion shows a description (e.g., "Build artifacts", "Dependencies")
- Use Up/Down arrows to select
- Press Tab/Enter/Right-arrow to accept
- Press Ctrl-G to dismiss

## What Gets Suggested

The feature suggests 40+ common patterns:

### Build Artifacts
- `.build` - Swift build artifacts
- `build` - Generic build output
- `dist` - Distribution output
- `target` - Rust/Java builds
- `out`, `bin`, `obj` - Other build outputs
- `.gradle` - Gradle cache
- `DerivedData` - Xcode artifacts

### Dependencies
- `node_modules` - Node.js packages
- `vendor` - PHP/Ruby packages
- `.bundle` - Ruby bundle cache
- `bower_components`, `jspm_packages` - Legacy JS

### Caches
- `.cache`, `.npm`, `.yarn`, `.pnpm-store`
- `.next`, `.nuxt`, `.vite`, `.turbo`, `.parcel-cache`
- `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox`

### System Files
- `.DS_Store` - macOS metadata
- `Thumbs.db` - Windows thumbnails
- `desktop.ini` - Windows settings

### Temp/Log Files
- `tmp`, `.tmp`, `temp`
- `logs`, `*.log`
- `coverage`, `.nyc_output`, `.coverage`

## Integration Notes

- Works immediately after flags (e.g., `rm -rf `)
- Only triggers when flags are present
- Integrates seamlessly with Lumen's existing suggestion system
- No performance impact (uses efficient glob matching)
- Respects `_LUMEN_MAX_CANDIDATES` limit (50 by default)
