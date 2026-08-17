#!/usr/bin/env zsh
# Demo script showing the rm suggestions feature in action
# This script creates sample files/folders to demonstrate the feature

cat << 'EOF'
╔══════════════════════════════════════════════════════════════════╗
║   Lumen rm Suggestions Feature Demo                             ║
║                                                                  ║
║   This script creates sample files/folders to test the          ║
║   rm suggestions feature.                                       ║
╚══════════════════════════════════════════════════════════════════╝

Setting up demo environment...
EOF

# Create a temporary demo directory
DEMO_DIR="/tmp/lumen_rm_demo_$$"
mkdir -p "$DEMO_DIR"
cd "$DEMO_DIR"

echo "\n📁 Creating sample directories and files:\n"

# Build artifacts
mkdir -p .build build dist target out DerivedData
echo "✅ Build artifacts: .build, build, dist, target, out, DerivedData"

# Dependencies
mkdir -p node_modules vendor .bundle
echo "✅ Dependencies: node_modules, vendor, .bundle"

# Caches
mkdir -p .cache .npm .yarn __pycache__ .next .turbo
echo "✅ Caches: .cache, .npm, .yarn, __pycache__, .next, .turbo"

# System files
touch .DS_Store Thumbs.db
echo "✅ System files: .DS_Store, Thumbs.db"

# Temp files
mkdir -p tmp logs coverage
touch test.log debug.log
echo "✅ Temp files: tmp, logs, coverage, *.log"

cat << 'EOF'

┌──────────────────────────────────────────────────────────────────┐
│  Demo Environment Ready!                                         │
│                                                                  │
│  Location: 
EOF

echo "│  $DEMO_DIR"

cat << 'EOF'
│                                                                  │
│  Now try these commands:                                        │
│                                                                  │
│  1. cd to the demo directory:                                   │
│     cd
EOF

echo "     cd $DEMO_DIR"

cat << 'EOF'
│                                                                  │
│  2. Type:  rm -rf                                               │
│     (with a space after -rf)                                    │
│     → You should see suggestions appear in Lumen's panel        │
│                                                                  │
│  3. Try typing partial names:                                   │
│     rm -rf node       → Shows: node_modules [exists]            │
│     rm -rf .b         → Shows: .build [exists], .bundle [exists]│
│     rm -rf bu         → Shows: build [exists]                   │
│     rm -rf .DS        → Shows: .DS_Store [exists]               │
│                                                                  │
│  4. Use arrow keys to navigate, Tab/Enter to accept             │
│                                                                  │
│  5. When done testing, clean up:                                │
│     rm -rf
EOF

echo "     rm -rf $DEMO_DIR"

cat << 'EOF'
│                                                                  │
└──────────────────────────────────────────────────────────────────┘

Features to notice:
  • [exists] marker shows which files/folders are present
  • Categories help identify what each item is
  • Suggestions appear instantly as you type
  • Works with any flag combination: -rf, -r, -f, -rfv, etc.

Press Enter to open the demo directory in a new shell...
EOF

read

# Launch a new shell in the demo directory
cd "$DEMO_DIR"
echo "\n🚀 Starting new shell in demo directory..."
echo "Type 'exit' when done to return to your original shell.\n"
$SHELL
