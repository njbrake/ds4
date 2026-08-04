# ds4 public bridge

Exposes this repo's `ds4-server` to the internet behind a bearer-token gate, so
a remote client (e.g. Otari on Railway) can call it as an OpenAI-compatible
endpoint.

```
Internet ──TLS:443──▶ Tailscale Funnel ──▶ Caddy :9000 (bearer check) ──▶ 127.0.0.1:8000 (ds4-server)
```

`ds4-server` binds loopback only; the Caddy gate is the sole reachable path,
and it 401s anything without the exact token. TLS is terminated by Tailscale
Funnel (Let's Encrypt cert on the `*.ts.net` name) — there is no TLS or auth in
`ds4-server` itself.

## Run

```sh
./run-bridge.sh
```

Starts ds4-server + Caddy + Funnel in one pane and tails the logs. **Ctrl-C
stops all three and turns the funnel off.** The 86 GB model takes a few minutes
to load; expect `502` through the proxy until it is ready.

Run it inside `tmux` so it survives disconnects:

```sh
tmux new -s ds4-bridge './run-bridge.sh'
# reattach later:  tmux attach -t ds4-bridge
```

## What it serves

- **Model:** DeepSeek V4 Flash 0731 (`ds4flash.gguf` in the repo root)
- **Model id (for clients):** `deepseek-v4-flash`
- **Context:** 500,000 tokens (`--ctx 500000`; the model's native max is ~1M)
- **GPU power:** `--power 100` (full duty cycle)
- **KV disk cache:** `/tmp/ds4-kv`, 64 GB budget — reused across requests/restarts

Tune these at the top of `run-bridge.sh` (`DS4_CTX`, `DS4_POWER`, `KV_DISK_MB`).

## Verify

```sh
URL=https://<your-node>.<tailnet>.ts.net
TOKEN=$(cat .token)

curl -s $URL/v1/models                                  # -> 401 (no token)
curl -s $URL/v1/models -H "Authorization: Bearer $TOKEN" # -> 200 JSON
```

## Point Otari at it (Railway)

```yaml
providers:
  openai:
    api_base: https://<your-node>.<tailnet>.ts.net/v1
    api_key: ${OPENAI_API_KEY}   # set OPENAI_API_KEY to the value in ./.token
```

Call with model id `openai:deepseek-v4-flash`.

## Files

| File | Purpose | In git |
|---|---|---|
| `run-bridge.sh` | launcher (ds4-server + Caddy + Funnel) | yes |
| `Caddyfile` | auth gate + reverse proxy config | yes |
| `README.md` | this file | yes |
| `.token` | **secret** bearer token (mode 0600) | no (.gitignore) |
| `caddy` | bundled Caddy binary (~50 MB) | no (.gitignore) |
| `*.log` | runtime logs | no (.gitignore) |

## Notes

- **One bridge at a time.** ds4 and any oMLX bridge share ports 8000/9000 and
  the same funnel — stop one before starting the other.
- **DSpark / speculative decoding is off.** The 0731 support GGUF
  (`gguf/DeepSeek-V4-Flash-DSpark-support-0731.gguf`) is present; to enable, add
  `--mtp <that file> --dspark --temp 0` to the ds4-server line. It speeds up
  code *generation* (greedy only), not prefill.
- **Rotating the token:** `openssl rand -hex 32 > .token`, then update the
  client (Railway `OPENAI_API_KEY`) to match and restart.
