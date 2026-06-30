#!/usr/bin/env bash
# benchmark.sh — Mide rendimiento de inferencia Ollama (IPEX-LLM)
# Métricas: tokens/s generación, tokens/s prompt, TTFT, memoria RAM
# Uso: ./benchmark.sh [modelo] [num_ctx]
# Ejemplo: ./benchmark.sh qwen2.5:7b 8192

set -euo pipefail

MODEL="${1:-}"
CTX="${2:-8192}"
RUNS=3
API="http://localhost:11434"
# Prompt corto y determinista para medir generación pura
PROMPT="Explain in exactly 100 words what a transformer neural network is."

# ── helpers ──────────────────────────────────────────────────────────────────

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
sep()   { printf '%0.s─' {1..60}; echo; }

check_api() {
  if ! curl -sf "$API/api/tags" >/dev/null 2>&1; then
    red "ERROR: API Ollama no responde en $API"
    red "Arranca el contenedor primero: docker compose up -d"
    exit 1
  fi
}

pick_model() {
  local models
  models=$(curl -s "$API/api/tags" | python3 -c "
import sys, json
d = json.load(sys.stdin)
models = [m['name'] for m in d.get('models', [])]
print('\n'.join(models))
" 2>/dev/null)

  if [[ -z "$models" ]]; then
    red "No hay modelos descargados. Descarga uno con: /ollama-pull <modelo>"
    exit 1
  fi

  if [[ -z "$MODEL" ]]; then
    MODEL=$(echo "$models" | head -1)
    echo "Modelo no especificado — usando: $MODEL"
  elif ! echo "$models" | grep -qF "$MODEL"; then
    red "Modelo '$MODEL' no encontrado. Disponibles:"
    echo "$models"
    exit 1
  fi
}

ram_available_gb() {
  awk '/^MemAvailable:/ { printf "%.1f", $2/1024/1024 }' /proc/meminfo
}

docker_mem_mb() {
  docker stats ipex-llm --no-stream --format "{{.MemUsage}}" 2>/dev/null \
    | awk -F'[/ ]' '{print $1 $2}' | sed 's/MiB//' | sed 's/GiB/*1024/' \
    | bc 2>/dev/null || echo "N/A"
}

run_inference() {
  local run_num="$1"
  local tmp_payload tmp_response
  tmp_payload=$(mktemp)
  tmp_response=$(mktemp)

  python3 -c "
import json
print(json.dumps({
  'model': '$MODEL',
  'prompt': '$PROMPT',
  'stream': False,
  'think': False,
  'options': {'num_ctx': $CTX, 'temperature': 0}
}))" > "$tmp_payload"

  curl -sf -X POST "$API/api/generate" \
    -H "Content-Type: application/json" \
    -d @"$tmp_payload" \
    --max-time 180 > "$tmp_response"

  python3 - "$tmp_response" "$run_num" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    r = json.load(f)

run_num       = sys.argv[2]
eval_count    = r.get('eval_count', 0)
eval_dur_ns   = r.get('eval_duration', 1)
prompt_count  = r.get('prompt_eval_count', 0)
prompt_dur_ns = r.get('prompt_eval_duration', 1)

gen_tps    = eval_count / (eval_dur_ns / 1e9)
prompt_tps = prompt_count / (prompt_dur_ns / 1e9) if prompt_dur_ns > 0 else 0
ttft_ms    = prompt_dur_ns / 1e6

print(f'run={run_num} gen_tps={gen_tps:.2f} prompt_tps={prompt_tps:.2f} ttft_ms={ttft_ms:.0f} tokens={eval_count}')
PYEOF

  rm -f "$tmp_payload" "$tmp_response"
}

# ── main ─────────────────────────────────────────────────────────────────────

check_api
pick_model

sep
bold "BENCHMARK IPEX-LLM — $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Modelo : $MODEL"
echo "  CTX    : $CTX tokens"
echo "  Runs   : $RUNS (el 1º incluye carga del modelo)"
echo "  RAM disponible antes: $(ram_available_gb) GB"
sep

declare -a gen_arr prompt_arr ttft_arr

for i in $(seq 1 $RUNS); do
  echo -n "  Run $i/$RUNS ... "
  result=$(run_inference "$i")
  echo "$result"

  gen_tps=$(echo "$result"    | grep -oP 'gen_tps=\K[0-9.]+')
  prompt_tps=$(echo "$result" | grep -oP 'prompt_tps=\K[0-9.]+')
  ttft_ms=$(echo "$result"   | grep -oP 'ttft_ms=\K[0-9.]+')

  # Excluir run 1 (cold start con carga de modelo)
  if [[ $i -gt 1 ]]; then
    gen_arr+=("$gen_tps")
    prompt_arr+=("$prompt_tps")
    ttft_arr+=("$ttft_ms")
  fi
done

sep
bold "RESULTADOS (runs 2+ — modelo ya cargado)"
python3 -c "
import sys
gen    = [float(x) for x in '${gen_arr[*]}'.split()]
prompt = [float(x) for x in '${prompt_arr[*]}'.split()]
ttft   = [float(x) for x in '${ttft_arr[*]}'.split()]

def stats(lst, unit):
    if not lst: return 'N/A'
    return f'avg={sum(lst)/len(lst):.2f}  min={min(lst):.2f}  max={max(lst):.2f}  {unit}'

print(f'  Generación (eval)  : {stats(gen, \"tok/s\")}')
print(f'  Prompt (prefill)   : {stats(prompt, \"tok/s\")}')
print(f'  Time-to-first-token: {stats(ttft, \"ms\")}')
" 2>/dev/null

echo "  RAM disponible después : $(ram_available_gb) GB"
echo "  Memoria contenedor     : $(docker_mem_mb) MiB"
sep
echo "Guarda esta salida para comparar antes/después:"
echo "  ./benchmark.sh $MODEL $CTX | tee benchmark-$(date +%Y%m%d-%H%M).txt"
sep
