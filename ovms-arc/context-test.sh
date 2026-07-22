#!/usr/bin/env bash
# context-test.sh — Long-context / multi-turn prefill degradation probe against a running
# OVMS server. Mirrors the methodology behind the llama-cpp-arc real-world finding
# (../llama-cpp-arc/local-llm-yoga-slim7-ubuntu2404-llamacpp.md §8.3: prefill rate on a
# 24.4K-token agentic prompt dropped from ~177 to ~50 tok/s within one request) — this is
# the OVMS-side measurement that finding was missing (see ../ovms-arc/TODO.md).
#
# Two independent modes, because they answer different questions:
#
#   cold        Four independent single-shot requests at growing prompt sizes (~2K/8K/16K/24K
#               tokens, calibrated via the real usage.prompt_tokens OVMS returns — targets are
#               approximate by design). Requires the server started WITHOUT prefix caching
#               (--enable_prefix_caching false) — each request is a genuinely cold prefill, so
#               subtracting consecutive checkpoints approximates the instantaneous prefill rate
#               at that context depth. Directly comparable to the llama-cpp-arc table above.
#
#   multiturn   Simulates a real agentic session: a fixed system prompt, then N turns each
#               appending a new chunk of unique content, POSTing the full growing message
#               history every turn (as any stateless chat client does). Requires the server
#               started WITH prefix caching (the default — just use start-server.sh). If
#               caching works as intended, each turn only pays for its own new tokens, not the
#               whole accumulated history — this isolates the marginal per-turn prefill cost at
#               increasing depth, the practical question for a persistent agent session.
#
# Both modes use max_tokens=1 to isolate prefill time from generation time, and
# chat_template_kwargs.enable_thinking=false (Qwen3 gotcha, see quality-test.sh) so a stray
# thinking token can't distort the one token we do generate.
#
# Usage:
#   ./context-test.sh --model OpenVINO/Qwen3-8B-int4-ov --mode cold
#   ./context-test.sh --model OpenVINO/Qwen3-8B-int4-ov --mode multiturn
#   ./context-test.sh --model OpenVINO/Qwen3-8B-int4-ov --mode both --port 9000

set -euo pipefail

PORT=9000
MODEL=""
MODE="both"
COLD_TARGETS=(2048 8192 16384 24576)
NUM_TURNS=12
TURN_TARGET_TOKENS=1800

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
sep()    { printf '%.0s─' {1..70}; echo; }

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      [[ $# -lt 2 ]] && { echo "ERROR: --model requires a value" >&2; exit 1; }
      MODEL="$2"; shift 2 ;;
    --port)
      [[ $# -lt 2 ]] && { echo "ERROR: --port requires a value" >&2; exit 1; }
      PORT="$2"; shift 2 ;;
    --mode)
      [[ $# -lt 2 ]] && { echo "ERROR: --mode requires cold|multiturn|both" >&2; exit 1; }
      MODE="$2"; shift 2 ;;
    --cold-targets)
      [[ $# -lt 2 ]] && { echo "ERROR: --cold-targets requires a comma-separated token list" >&2; exit 1; }
      IFS=',' read -ra COLD_TARGETS <<< "$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "${MODEL}" ]] && { red "ERROR: --model is required (must match the id OVMS reports at /v3/models)"; exit 1; }
[[ "${MODE}" =~ ^(cold|multiturn|both)$ ]] || { red "ERROR: --mode must be cold, multiturn or both"; exit 1; }

if ! curl -sf "http://localhost:${PORT}/v3/models" > /dev/null 2>&1; then
  red "ERROR: no server responding on port ${PORT} — start ovms first"
  exit 1
fi

# words(n) — n unique filler tokens, cheap even at tens of thousands (single seq call)
words() { seq -f "w%06g" 1 "$1" | tr '\n' ' '; }

# chat(content_json_array) -> curl response body. content_json_array is a jq-ready messages array.
chat() {
  curl -sf "http://localhost:${PORT}/v3/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",\"temperature\":0,\"max_tokens\":1,\"chat_template_kwargs\":{\"enable_thinking\":false},\"messages\":${1}}"
}

# chat_raw(outfile, content_json_array) -> prints HTTP status code, body goes to outfile.
# Unlike chat(), never fails on a non-200 — used where the response itself (context exceeded,
# OOM, etc.) is the thing being tested, not an error to abort on.
chat_raw() {
  curl -s -o "$1" -w "%{http_code}" "http://localhost:${PORT}/v3/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",\"temperature\":0,\"max_tokens\":1,\"chat_template_kwargs\":{\"enable_thinking\":false},\"messages\":$2}"
}

now_ms() { date +%s%3N; }

# ── Word/token ratio calibration ────────────────────────────────────────────────
calibrate_wpt() {
  local cal_words=1000
  local msg
  msg="[{\"role\":\"user\",\"content\":\"$(words ${cal_words})Question: reply with a single word.\"}]"
  local resp tokens
  resp="$(chat "${msg}")" || { red "ERROR: calibration request failed"; exit 1; }
  tokens="$(jq -r '.usage.prompt_tokens' <<< "${resp}")"
  [[ "${tokens}" == "null" || -z "${tokens}" ]] && { red "ERROR: no usage.prompt_tokens in response — got: ${resp}"; exit 1; }
  awk -v w="${cal_words}" -v t="${tokens}" 'BEGIN { printf "%.4f", w/t }'
}

# ── Cold mode ────────────────────────────────────────────────────────────────────
run_cold() {
  sep; bold "COLD long-prompt degradation — model: ${MODEL}"
  yellow "Requires the server running with --enable_prefix_caching false. If it's running"
  yellow "with caching on (e.g. via start-server.sh), these numbers are NOT valid — restart"
  yellow "manually per CLAUDE.md's 'Manual equivalent' with that flag added."
  sep

  echo "Calibrating words↔tokens ratio..."
  local wpt
  wpt="$(calibrate_wpt)"
  echo "  ratio: ${wpt} words/token"
  sep

  local prev_tokens=0 prev_ms=0
  printf "%-22s %-12s %-14s %-20s\n" "Target tokens" "Real tokens" "Elapsed ms" "Instantaneous rate"
  for target in "${COLD_TARGETS[@]}"; do
    local w
    w="$(awk -v t="${target}" -v r="${wpt}" 'BEGIN { printf "%d", t*r }')"
    local msg
    msg="[{\"role\":\"user\",\"content\":\"$(words "${w}")Question: reply with a single word.\"}]"
    local t0 t1 resp_file http_code tokens elapsed
    resp_file="$(mktemp)"
    t0="$(now_ms)"
    http_code="$(chat_raw "${resp_file}" "${msg}" || echo "000")"
    t1="$(now_ms)"
    if [[ "${http_code}" != "200" ]]; then
      red "  FAILED at target ${target} (~${w} filler words) — HTTP ${http_code}"
      yellow "  Response body: $(head -c 500 "${resp_file}" 2>/dev/null)"
      rm -f "${resp_file}"
      yellow "  Stopping the cold sweep here — this is the breaking point, not a transient error."
      break
    fi
    tokens="$(jq -r '.usage.prompt_tokens // "null"' "${resp_file}")"
    rm -f "${resp_file}"
    if [[ "${tokens}" == "null" ]]; then
      red "  FAILED at target ${target} — HTTP 200 but no usage.prompt_tokens in response"
      break
    fi
    elapsed=$(( t1 - t0 ))

    local rate
    if (( prev_tokens == 0 )); then
      rate="$(awk -v tok="${tokens}" -v ms="${elapsed}" 'BEGIN { printf "%.1f", tok/(ms/1000) }')"
      printf "%-22s %-12s %-14s %-20s\n" "0 → ${target}" "${tokens}" "${elapsed}" "${rate} tok/s"
    else
      local dtok dms
      dtok=$(( tokens - prev_tokens ))
      dms=$(( elapsed - prev_ms ))
      rate="$(awk -v tok="${dtok}" -v ms="${dms}" 'BEGIN { printf "%.1f", tok/(ms/1000) }')"
      printf "%-22s %-12s %-14s %-20s\n" "${prev_tokens} → ${tokens}" "${tokens}" "${elapsed}" "${rate} tok/s"
    fi
    prev_tokens="${tokens}"
    prev_ms="${elapsed}"
  done
  sep
}

# ── Multi-turn mode ──────────────────────────────────────────────────────────────
run_multiturn() {
  sep; bold "MULTI-TURN growing session — model: ${MODEL}"
  yellow "Requires the server running WITH prefix caching (the default — start-server.sh)."
  sep

  echo "Calibrating words↔tokens ratio..."
  local wpt
  wpt="$(calibrate_wpt)"
  local turn_words
  turn_words="$(awk -v t="${TURN_TARGET_TOKENS}" -v r="${wpt}" 'BEGIN { printf "%d", t*r }')"
  echo "  ratio: ${wpt} words/token — ~${turn_words} filler words/turn"
  sep

  local tmp_messages
  tmp_messages="$(mktemp)"
  echo '[{"role":"system","content":"You are a coding agent with access to tools: read_file(path), write_file(path,content), run_shell(cmd), search_code(query). Use them when appropriate. Keep replies short."}]' > "${tmp_messages}"

  local prev_tokens=0 prev_ms=0
  printf "%-8s %-14s %-14s %-20s\n" "Turn" "Total tokens" "Elapsed ms" "Marginal rate (new tokens)"
  for (( turn=1; turn<=NUM_TURNS; turn++ )); do
    local user_content
    user_content="$(words "${turn_words}")Turn ${turn} question: what is the sum of the numbers you were just given? Reply with one word."
    jq --arg c "${user_content}" '. + [{"role":"user","content":$c}]' "${tmp_messages}" > "${tmp_messages}.next"
    mv "${tmp_messages}.next" "${tmp_messages}"

    local messages_json t0 t1 resp tokens elapsed assistant_content
    messages_json="$(cat "${tmp_messages}")"
    t0="$(now_ms)"
    resp="$(chat "${messages_json}")" || { red "  FAILED at turn ${turn}"; exit 1; }
    t1="$(now_ms)"
    tokens="$(jq -r '.usage.prompt_tokens' <<< "${resp}")"
    elapsed=$(( t1 - t0 ))
    assistant_content="$(jq -r '.choices[0].message.content // "(empty)"' <<< "${resp}")"

    jq --arg c "${assistant_content}" '. + [{"role":"assistant","content":$c}]' "${tmp_messages}" > "${tmp_messages}.next"
    mv "${tmp_messages}.next" "${tmp_messages}"

    local rate dtok dms
    if (( prev_tokens == 0 )); then
      rate="$(awk -v tok="${tokens}" -v ms="${elapsed}" 'BEGIN { printf "%.1f", tok/(ms/1000) }')"
    else
      dtok=$(( tokens - prev_tokens ))
      dms=$(( elapsed - prev_ms ))
      rate="$(awk -v tok="${dtok}" -v ms="${dms}" 'BEGIN { printf "%.1f", (ms>0)? tok/(ms/1000) : 0 }')"
    fi
    printf "%-8s %-14s %-14s %-20s\n" "${turn}/${NUM_TURNS}" "${tokens}" "${elapsed}" "${rate} tok/s"
    prev_tokens="${tokens}"
    prev_ms="${elapsed}"
  done
  rm -f "${tmp_messages}"
  sep
}

case "${MODE}" in
  cold) run_cold ;;
  multiturn) run_multiturn ;;
  both) run_cold; echo; run_multiturn ;;
esac
