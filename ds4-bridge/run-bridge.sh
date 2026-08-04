#!/usr/bin/env bash
# ds4 <-> public bridge. Exposes this repo's ds4-server to the internet behind
# a bearer-token gate, so a remote client (e.g. Otari on Railway) can call it as
# an OpenAI-compatible endpoint.
#
#   Internet --TLS:443--> Tailscale Funnel --> Caddy :9000 (bearer) --> 127.0.0.1:8000 (ds4-server)
#
# Serves DeepSeek V4 Flash 0731 at 500k context. Starts three things in this
# pane and tails their logs. Ctrl-C tears all three down and turns the funnel
# off (no `exec` at the end, so the cleanup trap actually runs -- an earlier
# version used `exec tail` and the trap never fired, leaving the funnel on).
set -uo pipefail

BRIDGE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$BRIDGE_DIR")"        # ~/scm/ds4 -- holds ds4-server + ds4flash.gguf
TOKEN_FILE="$BRIDGE_DIR/.token"
CADDYFILE="$BRIDGE_DIR/Caddyfile"
CADDY_BIN="$BRIDGE_DIR/caddy"
DS4_LOG="$BRIDGE_DIR/ds4-server.log"
CADDY_LOG="$BRIDGE_DIR/caddy.log"
PROXY_PORT=9000

# Model / performance knobs (see README for the reasoning behind each).
DS4_CTX=500000              # matches the pi client's assumed max; model native max is 1M
DS4_POWER=100              # GPU duty-cycle target, 1..100
KV_DISK_DIR=/tmp/ds4-kv
KV_DISK_MB=65536           # 64GB on-disk KV checkpoint budget

# Prefer a caddy on PATH; fall back to the bundled binary.
command -v caddy >/dev/null 2>&1 && CADDY_BIN="caddy"

# The `tailscale` CLI is a shell alias in the interactive shell; resolve the
# real binary so this script works regardless of how it's invoked.
TS="$(command -v tailscale || true)"
[ -z "$TS" ] && TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

# --- preflight ---
[ -s "$TOKEN_FILE" ]           || { echo "[bridge] missing $TOKEN_FILE -- run: openssl rand -hex 32 > $TOKEN_FILE"; exit 1; }
[ -x "$REPO_DIR/ds4-server" ]  || { echo "[bridge] no ds4-server at $REPO_DIR -- build it first (make ds4-server)"; exit 1; }
[ -e "$REPO_DIR/ds4flash.gguf" ] || { echo "[bridge] missing $REPO_DIR/ds4flash.gguf"; exit 1; }
[ -x "$CADDY_BIN" ]            || { echo "[bridge] no caddy binary at $CADDY_BIN (brew install caddy, or restore ./caddy)"; exit 1; }
export LLM_API_TOKEN="$(cat "$TOKEN_FILE")"

if lsof -nP -iTCP:8000 -sTCP:LISTEN >/dev/null 2>&1; then
	echo "[bridge] port 8000 already in use -- stop the other server first (oMLX/ds4 bridge?)."; exit 1
fi
if lsof -nP -iTCP:"$PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
	echo "[bridge] port $PROXY_PORT already in use -- stop the other caddy first."; exit 1
fi

FUNNEL_HOST="$("$TS" status --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null)"
[ -z "$FUNNEL_HOST" ] && FUNNEL_HOST="<your-node>.<tailnet>.ts.net"

DS4_PID=""; CADDY_PID=""
cleanup() {
	echo; echo "[bridge] shutting down..."
	[ -n "$CADDY_PID" ] && kill "$CADDY_PID" 2>/dev/null
	[ -n "$DS4_PID" ] && kill "$DS4_PID" 2>/dev/null
	"$TS" funnel --https=443 off 2>/dev/null
	echo "[bridge] funnel off, processes stopped."
}
trap cleanup EXIT INT TERM

# --- 1. ds4-server (loopback only; the proxy is the sole reachable path) ---
echo "[bridge] starting ds4-server (127.0.0.1:8000, DeepSeek V4 Flash 0731, ctx=$DS4_CTX) -> $DS4_LOG"
( cd "$REPO_DIR" && exec caffeinate -i ./ds4-server \
	--power "$DS4_POWER" --ctx "$DS4_CTX" \
	--kv-disk-dir "$KV_DISK_DIR" --kv-disk-space-mb "$KV_DISK_MB" \
	--host 127.0.0.1 --port 8000 ) > "$DS4_LOG" 2>&1 &
DS4_PID=$!

# --- 2. caddy auth gate ---
echo "[bridge] starting caddy auth gate (127.0.0.1:$PROXY_PORT) -> $CADDY_LOG"
"$CADDY_BIN" run --adapter caddyfile --config "$CADDYFILE" > "$CADDY_LOG" 2>&1 &
CADDY_PID=$!

# --- 3. funnel ---
echo "[bridge] funnel -> :$PROXY_PORT"
"$TS" funnel --bg "$PROXY_PORT" >/dev/null 2>&1

sleep 1
cat <<EOF

  Public URL : https://$FUNNEL_HOST/v1
  Model id   : openai:deepseek-v4-flash   (set this in Otari)
  Test       : curl https://$FUNNEL_HOST/v1/models -H "Authorization: Bearer \$(cat $TOKEN_FILE)"

[bridge] ds4 loads an 86GB model; expect 502 through the proxy until it is ready.
[bridge] tailing logs -- Ctrl-C stops ds4 + caddy + funnel.
----------------------------------------------------------------
EOF
tail -n +1 -f "$DS4_LOG" "$CADDY_LOG" &
wait
