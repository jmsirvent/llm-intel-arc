#!/usr/bin/env bash
# bench-spec.sh — Measure speculative decoding throughput via llama-server.
#
# Usage:
#   ./bench-spec.sh                  # 3 runs, default prompt
#   ./bench-spec.sh -n 5             # 5 runs
#   ./bench-spec.sh -p "My prompt"   # custom prompt
#   ./bench-spec.sh -t 256           # tokens to generate (default: 128)
#   ./bench-spec.sh --port 8081      # different port (default: 8080)

set -euo pipefail

PORT=8080
RUNS=3
TOKENS=128
PROMPT="Write a detailed explanation of how transformer neural networks work in natural language processing, covering self-attention mechanisms, positional encoding, layer normalization, and the encoder-decoder architecture. Include concrete examples."

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) RUNS="$2"; shift 2 ;;
    -p) PROMPT="$2"; shift 2 ;;
    -t) TOKENS="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

PAYLOAD=$(printf '{"prompt":%s,"n_predict":%d,"stream":false,"cache_prompt":false}' \
  "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$PROMPT")" \
  "$TOKENS")

green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
sep()   { printf '%.0s─' {1..50}; echo; }

sep
bold "Speculative decoding bench — localhost:${PORT}"
printf "  Prompt tokens : ~%d chars / ~%d tokens\n" "${#PROMPT}" "$(( ${#PROMPT} / 4 ))"
printf "  Generate      : %d tokens\n" "$TOKENS"
printf "  Runs          : %d\n" "$RUNS"
sep

total_gen=0
total_prefill=0
total_accepted=0
total_drafted=0

for i in $(seq 1 "$RUNS"); do
  response=$(curl -sf "http://localhost:${PORT}/completion" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD") || { echo "ERROR: server not responding on port ${PORT}"; exit 1; }

  result=$(python3 - "$response" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
t = d['timings']
gen      = t['predicted_per_second']
prefill  = t['prompt_per_second']
accepted = t.get('draft_n_accepted', 0)
drafted  = t.get('draft_n', 0)
print(f"{gen:.2f} {prefill:.0f} {accepted} {drafted}")
PYEOF
)

  read -r gen prefill accepted drafted <<< "$result"
  total_gen=$(python3 -c "print($total_gen + $gen)")
  total_prefill=$(python3 -c "print($total_prefill + $prefill)")
  total_accepted=$(( total_accepted + accepted ))
  total_drafted=$(( total_drafted + drafted ))

  if [[ "$drafted" -gt 0 ]]; then
    rate=$(python3 -c "print('%.0f%%' % ($accepted / $drafted * 100))")
  else
    rate="N/A"
  fi
  printf "  Run %d/%d  gen: %s tok/s  prefill: %s tok/s  accepted: %s/%s (%s)\n" \
    "$i" "$RUNS" "$gen" "$prefill" "$accepted" "$drafted" "$rate"
done

sep
avg_gen=$(python3 -c "print('%.2f' % ($total_gen / $RUNS))")
avg_pre=$(python3 -c "print('%d' % ($total_prefill / $RUNS))")
if [[ "$total_drafted" -gt 0 ]]; then
  avg_rate=$(python3 -c "print('%.0f%%' % ($total_accepted / $total_drafted * 100))")
else
  avg_rate="N/A"
fi
green "  Avg gen     : ${avg_gen} tok/s"
green "  Avg prefill : ${avg_pre} tok/s"
green "  Acceptance  : ${avg_rate}  (${total_accepted}/${total_drafted} tokens)"
sep
printf "  Baseline (§8.3, no spec decoding): check the guide\n"
