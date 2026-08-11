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
DS4_CTX=400000              # autoplan sessions peak ~174k; 400k gives ~2.3x headroom and
                           # still fits 4 slots (~6.8GB KV/slot, ~113GB total incl the 86GB
                           # model). Model native max is 1M, but higher ctx needs fewer
                           # slots for memory. Keep this in sync with what Otari advertises.
DS4_POWER=100              # GPU duty-cycle target, 1..100
KV_DISK_DIR=/tmp/ds4-kv
KV_DISK_MB=131072          # 128GB on-disk KV checkpoint budget (491GB SSD free)
DS4_BATCH=4                # resident KV slots. Claude Code spawns sub-agents (each a
                           # separate conversation); a slot each keeps them from
                           # evicting one another (single-slot thrashes on /autoplan-
                           # style multi-agent workloads). Also covers concurrent clients.
DS4_DSPARK=1               # DSpark speculative decoding (draft model for Flash 0731):
                           # the draft proposes up to 5 tokens, Flash verifies and
                           # commits the accepted prefix -> faster DECODE on predictable
                           # /code continuations. Does NOT speed prefill. Adds ~5.6GB
                           # draft weights + verifier state, so it tightens the budget --
                           # watch the startup "memory:" line and drop DS4_BATCH if it
                           # crowds 128GB. Checkpoint-specific: 0731 draft <-> 0731 Flash.
DS4_MTP="$REPO_DIR/gguf/DeepSeek-V4-Flash-DSpark-support-0731.gguf"
DS4_TRACE=""               # DIAGNOSTIC ONLY. Set to a path (e.g. /tmp/ds4-trace.log)
                           # to have ds4-server dump per-request cache decisions --
                           # on a token-mismatch miss it prints the 8 tokens either
                           # side of the divergence, cached vs incoming, as decoded
                           # text. Reveals what the client re-renders each turn and
                           # breaks the prefix cache. Verbose + contains conversation
                           # text, so keep it under /tmp and blank for normal runs.

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

DS4_PID=""; CADDY_PID=""; TAIL_PID=""
cleanup() {
	echo; echo "[bridge] shutting down..."
	[ -n "$CADDY_PID" ] && kill "$CADDY_PID" 2>/dev/null
	[ -n "$DS4_PID" ] && kill "$DS4_PID" 2>/dev/null
	# The tail is backgrounded (different process group), so Ctrl-C's SIGINT
	# never reaches it -- kill it here or each restart orphans one, and every
	# leaked tail reprints the whole log into the pane (10x duplicate lines).
	[ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null
	"$TS" funnel --https=443 off 2>/dev/null
	echo "[bridge] funnel off, processes stopped."
}
trap cleanup EXIT INT TERM

# Optional DSpark draft-model flags, appended only when enabled.
DSPARK_ARGS=()
if [ "${DS4_DSPARK:-0}" = "1" ]; then
	[ -e "$DS4_MTP" ] || { echo "[bridge] DSpark enabled but missing $DS4_MTP -- run: ./download_model.sh ds4f-dspark"; exit 1; }
	DSPARK_ARGS=(--mtp "$DS4_MTP" --dspark)
	echo "[bridge] DSpark ON (draft: $(basename "$DS4_MTP"))"
fi

# Optional per-request cache-decision trace (diagnostic).
TRACE_ARGS=()
if [ -n "${DS4_TRACE:-}" ]; then
	TRACE_ARGS=(--trace "$DS4_TRACE")
	: > "$DS4_TRACE" 2>/dev/null || true   # truncate so we only capture this run
	echo "[bridge] request tracing ON -> $DS4_TRACE (diagnostic; blank DS4_TRACE to disable)"
fi

# --- 1. ds4-server (loopback only; the proxy is the sole reachable path) ---
echo "[bridge] starting ds4-server (127.0.0.1:8000, DeepSeek V4 Flash 0731, ctx=$DS4_CTX) -> $DS4_LOG"
( cd "$REPO_DIR" && exec caffeinate -i ./ds4-server \
	--power "$DS4_POWER" --ctx "$DS4_CTX" \
	--kv-disk-dir "$KV_DISK_DIR" --kv-disk-space-mb "$KV_DISK_MB" \
	--batched-session "$DS4_BATCH" \
	${DSPARK_ARGS[@]+"${DSPARK_ARGS[@]}"} \
	${TRACE_ARGS[@]+"${TRACE_ARGS[@]}"} \
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
TAIL_PID=$!
wait
