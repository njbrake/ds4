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

# Model selector: "glm" (GLM 5.3 Flash Q2, default) or "deepseek" (V4 Flash 0731).
# Rollback to DeepSeek is just: DS4_MODEL=deepseek ./run-bridge.sh
DS4_MODEL="${DS4_MODEL:-glm}"

# Model / performance knobs (see README for the reasoning behind each).
DS4_POWER=100              # GPU duty-cycle target, 1..100
KV_DISK_DIR=/tmp/ds4-kv
KV_DISK_MB=131072          # 128GB on-disk KV checkpoint budget (491GB SSD free)
DS4_MIXED_QUANTUM="${DS4_MIXED_QUANTUM:-2048}"  # tokens of prefill run per turn
                           # when a decode is co-resident on another slot. ds4
                           # shares one GPU executor, so a big COLD prefill and a
                           # concurrent decode take turns. The stock 128 ping-pongs
                           # so finely it's lose-lose: measured on this box a 20k
                           # cold prefill overlapping a decode ran at 136 t/s (vs
                           # 293 solo) AND starved the decode to ~1 t/s. At 2048 the
                           # prefill hits its full 308 t/s, so the whole contention
                           # window is ~2.3x shorter -- both conversations unblock
                           # sooner. No prefill headroom above 2048. Exported as
                           # DS4_SERVER_MIXED_PREFILL_QUANTUM below.
DS4_TRACE="${DS4_TRACE:-}"  # DIAGNOSTIC ONLY. Set to a path (e.g. /tmp/ds4-trace.log)
                           # -- env-overridable so a diagnostic run can flip it on
                           # without editing this file (export DS4_TRACE=/tmp/... first).
                           # to have ds4-server dump per-request cache decisions --
                           # on a token-mismatch miss it prints the 8 tokens either
                           # side of the divergence, cached vs incoming, as decoded
                           # text. Reveals what the client re-renders each turn and
                           # breaks the prefix cache. Verbose + contains conversation
                           # text, so keep it under /tmp and blank for normal runs.

# --- derive per-model config ---------------------------------------------
# ctx/slots/spec-decoding differ sharply between the two models. GLM 5.3 Q2's
# KV (recurrent KDA + sparse DSA layers) is far heavier per token than
# DeepSeek's compressed MLA, so it fits much less context on one 128GB box.
if [ "$DS4_MODEL" = "glm" ]; then
	MODEL_LABEL="GLM 5.3 Flash Q2"
	MODEL_PATH="$REPO_DIR/gguf/GLM-5.3-Flash-Q2.gguf"
	DS4_CTX="${DS4_CTX:-131072}"       # 128k x2 slots measured at ~115 GiB planned
	                                   # (~13 GiB headroom). GLM's sparse DSA makes
	                                   # ctx nearly free: 40k->128k added only ~3 GiB.
	                                   # Can push higher if 180k+ sessions must fit
	                                   # resident, at the cost of headroom.
	DS4_BATCH="${DS4_BATCH:-2}"        # 2 resident slots (balanced choice).
	SPEC_ARGS=(--mtp)                  # GLM's MTP block is embedded in the gguf.
	SPEC_DESC="embedded MTP"
	# Vision: separate 1.1GB encoder sidecar (text weights unchanged). Enabled
	# only when present, so a missing encoder degrades to text-only, not a crash.
	VISION_ENC="$REPO_DIR/gguf/GLM-5.3-Flash-Vision-Encoder.gguf"
	if [ "${DS4_VISION:-1}" = "1" ] && [ -e "$VISION_ENC" ]; then
		SPEC_ARGS+=(--vision "$VISION_ENC")
		SPEC_DESC="$SPEC_DESC + vision"
	elif [ "${DS4_VISION:-1}" = "1" ]; then
		echo "[bridge] vision encoder not found ($VISION_ENC); running text-only. ./download_model.sh glm53-vision"
	fi
elif [ "$DS4_MODEL" = "deepseek" ]; then
	MODEL_LABEL="DeepSeek V4 Flash 0731"
	# Explicit path, not ds4flash.gguf: download_model.sh repoints that symlink
	# to whichever model it fetched last (now GLM), so it is not a stable alias.
	MODEL_PATH="$REPO_DIR/gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf"
	DS4_CTX="${DS4_CTX:-400000}"       # MLA compression fits 4 slots at 400k.
	DS4_BATCH="${DS4_BATCH:-4}"
	DS4_MTP="$REPO_DIR/gguf/DeepSeek-V4-Flash-DSpark-support-0731.gguf"
	if [ "${DS4_DSPARK:-1}" = "1" ]; then
		[ -e "$DS4_MTP" ] || { echo "[bridge] DSpark on but missing $DS4_MTP -- ./download_model.sh ds4f-dspark"; exit 1; }
		SPEC_ARGS=(--mtp-model "$DS4_MTP" --dspark)   # NB: --mtp-model (flag refactored)
		SPEC_DESC="DSpark draft ($(basename "$DS4_MTP"))"
	else
		SPEC_ARGS=(); SPEC_DESC="off"
	fi
else
	echo "[bridge] unknown DS4_MODEL='$DS4_MODEL' (want glm|deepseek)"; exit 1
fi

# Prefer a caddy on PATH; fall back to the bundled binary.
command -v caddy >/dev/null 2>&1 && CADDY_BIN="caddy"

# The `tailscale` CLI is a shell alias in the interactive shell; resolve the
# real binary so this script works regardless of how it's invoked.
TS="$(command -v tailscale || true)"
[ -z "$TS" ] && TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

# --- preflight ---
[ -s "$TOKEN_FILE" ]           || { echo "[bridge] missing $TOKEN_FILE -- run: openssl rand -hex 32 > $TOKEN_FILE"; exit 1; }
[ -x "$REPO_DIR/ds4-server" ]  || { echo "[bridge] no ds4-server at $REPO_DIR -- build it first (make ds4-server)"; exit 1; }
[ -e "$MODEL_PATH" ] || { echo "[bridge] missing model $MODEL_PATH (DS4_MODEL=$DS4_MODEL)"; exit 1; }
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

echo "[bridge] model: $MODEL_LABEL  spec-decoding: $SPEC_DESC  ctx=$DS4_CTX slots=$DS4_BATCH"

# Optional per-request cache-decision trace (diagnostic).
TRACE_ARGS=()
if [ -n "${DS4_TRACE:-}" ]; then
	TRACE_ARGS=(--trace "$DS4_TRACE")
	: > "$DS4_TRACE" 2>/dev/null || true   # truncate so we only capture this run
	echo "[bridge] request tracing ON -> $DS4_TRACE (diagnostic; blank DS4_TRACE to disable)"
fi

# Scheduler tuning read from the environment by ds4-server (see DS4_MIXED_QUANTUM).
export DS4_SERVER_MIXED_PREFILL_QUANTUM="$DS4_MIXED_QUANTUM"

# --- 1. ds4-server (loopback only; the proxy is the sole reachable path) ---
echo "[bridge] starting ds4-server (127.0.0.1:8000, $MODEL_LABEL, ctx=$DS4_CTX, mixed_quantum=$DS4_MIXED_QUANTUM) -> $DS4_LOG"
( cd "$REPO_DIR" && exec caffeinate -i ./ds4-server \
	-m "$MODEL_PATH" \
	--power "$DS4_POWER" --ctx "$DS4_CTX" \
	--kv-disk-dir "$KV_DISK_DIR" --kv-disk-space-mb "$KV_DISK_MB" \
	--batched-session "$DS4_BATCH" \
	${SPEC_ARGS[@]+"${SPEC_ARGS[@]}"} \
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
