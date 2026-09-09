#!/usr/bin/env bash
# start.sh - one-command local launcher for WebDesktop Builder.
#
# Usage:
#   ./start.sh
#
# What it does:
#   1. Makes sure it's running from the project root (wherever this script
#      itself lives), so it works no matter where you call it from.
#   2. Checks for Ruby and Bundler, and tells you clearly if either is
#      missing instead of failing with a cryptic error.
#   3. Runs `bundle install` (only if needed).
#   4. Generates a SESSION_SECRET once and reuses it on every future run,
#      stored in .session_secret (gitignored) -- otherwise a new random
#      secret would be generated on every restart and log everyone out.
#   5. Boots the app with `bundle exec ruby webdesktop_builder.rb`.

set -euo pipefail

# --- 1. Always run from this script's own directory ------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Project directory: $SCRIPT_DIR"

# --- 2. Check for Ruby -------------------------------------------------------
if ! command -v ruby >/dev/null 2>&1; then
  echo ""
  echo "ERROR: Ruby is not installed (or not on your PATH)."
  echo ""
  echo "Install it first, then re-run this script:"
  echo "  macOS (Homebrew):   brew install ruby"
  echo "  Ubuntu/Debian:      sudo apt-get update && sudo apt-get install ruby-full"
  echo "  Any OS (rbenv):     https://github.com/rbenv/rbenv#installation"
  echo "  Any OS (asdf):      https://asdf-vm.com/guide/getting-started.html"
  exit 1
fi

RUBY_VERSION="$(ruby -v)"
echo "==> Found: $RUBY_VERSION"

# --- 3. Check for Bundler, install it if missing ----------------------------
if ! command -v bundle >/dev/null 2>&1; then
  echo "==> Bundler not found, installing it (gem install bundler)..."
  gem install bundler
fi

# --- 4. Install gems (skip if already satisfied) ----------------------------
echo "==> Checking gem dependencies..."
if ! bundle check >/dev/null 2>&1; then
  echo "==> Installing gems (bundle install)..."
  bundle install
else
  echo "==> Gems already installed."
fi

# --- 5. Persistent session secret -------------------------------------------
SECRET_FILE="$SCRIPT_DIR/.session_secret"
if [ ! -f "$SECRET_FILE" ]; then
  echo "==> Generating a persistent SESSION_SECRET (.session_secret)..."
  ruby -rsecurerandom -e 'print SecureRandom.hex(64)' > "$SECRET_FILE"
fi
export SESSION_SECRET
SESSION_SECRET="$(cat "$SECRET_FILE")"

# --- 6. Boot the app ---------------------------------------------------------
PORT="${PORT:-4567}"
echo ""
echo "==> Starting WebDesktop Builder on http://localhost:$PORT"
echo "==> Press Ctrl+C to stop."
echo ""

exec bundle exec ruby webdesktop_builder.rb
