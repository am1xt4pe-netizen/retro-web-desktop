#!/usr/bin/env bash
# Start WebDesktop Builder.command
#
# Double-click this file in Finder to start the app and open it in your
# browser. If it's already running, this just opens the browser tab again.
#
# First time you double-click it, macOS Gatekeeper may block it since it's
# an unsigned script. If that happens: right-click (or Control-click) the
# file -> "Open" -> confirm "Open" in the dialog. You only need to do that
# once.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PORT="${PORT:-4567}"
URL="http://localhost:$PORT"

open_browser() {
  if command -v open >/dev/null 2>&1; then
    open "$URL"                # macOS
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$URL"            # Linux
  else
    echo "Open this in your browser: $URL"
  fi
}

echo "=================================================="
echo "  WebDesktop Builder"
echo "=================================================="
echo ""

# --- Already running? Just reopen the browser tab and exit. ---------------
if curl -s -o /dev/null --max-time 2 "$URL"; then
  echo "Already running at $URL -- opening it now."
  open_browser
  sleep 2
  exit 0
fi

# --- Not running yet: check prerequisites -----------------------------------
if ! command -v ruby >/dev/null 2>&1; then
  echo "ERROR: Ruby isn't installed."
  echo "Open a terminal in this folder and run ./start.sh once for setup help."
  echo ""
  read -r -p "Press Enter to close this window..." _
  exit 1
fi

if ! command -v bundle >/dev/null 2>&1; then
  echo "Installing Bundler (one-time)..."
  gem install bundler
fi

if ! bundle check >/dev/null 2>&1; then
  echo "Installing gems (one-time, this may take a minute)..."
  bundle install
fi

# --- Persistent session secret, same as start.sh ----------------------------
SECRET_FILE="$SCRIPT_DIR/.session_secret"
if [ ! -f "$SECRET_FILE" ]; then
  ruby -rsecurerandom -e 'print SecureRandom.hex(64)' > "$SECRET_FILE"
fi
export SESSION_SECRET
SESSION_SECRET="$(cat "$SECRET_FILE")"
export PORT

# --- Start the server in the background, wait for it, then open browser ----
echo "Starting server..."
bundle exec ruby webdesktop_builder.rb &
SERVER_PID=$!

for _ in $(seq 1 40); do
  if curl -s -o /dev/null --max-time 1 "$URL"; then
    break
  fi
  sleep 0.5
done

open_browser

echo ""
echo "Running at $URL"
echo "Leave this window open to keep the server running."
echo "Close this window (or press Ctrl+C) to stop it."
echo ""

wait "$SERVER_PID"
