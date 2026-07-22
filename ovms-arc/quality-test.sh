#!/usr/bin/env bash
# quality-test.sh — Fixed 5-prompt quality battery against a running OVMS server.
#
# Port of ../llama-cpp-arc/quality-test.sh for OVMS's /v3/ API surface. Same 5 prompts,
# same intent: not a rigorous benchmark, catches obvious regressions (broken format, empty
# content, type-contract bugs) and gives a basis to compare OVMS's output against the
# existing SYCL baseline for the same model — see ../llama-cpp-arc/quality-baselines/<model>/
# for those (already generated during the original catalog benchmark campaign).
#
# Usage:
#   ./quality-test.sh --model OpenVINO/Qwen3-8B-int4-ov --save qwen3-8b-ovms
#   ./quality-test.sh --model OpenVINO/Qwen3-8B-int4-ov --diff qwen3-8b-ovms
#   ./quality-test.sh --list
#   ./quality-test.sh --model <id> --save <label> --port 9001 --max-tokens 1024
#
# Requires a model already loaded via ovms (see local-llm-yoga-slim7-ubuntu2404-ovms.md §4)
# on --port (default 9000). --model must match the exact id OVMS reports at /v3/models —
# unlike llama-server, OVMS does not ignore a mismatched model field.
#
# Reasoning models (Qwen3): pass chat_template_kwargs.enable_thinking=false, same as the
# llama.cpp version — confirmed OVMS respects it via the model's own Jinja chat template.
# Without it, thinking tokens can consume the entire --max-tokens budget before any answer
# is emitted (finish_reason: length, no usable content) — verified this failure mode before
# adding the flag below, don't remove it.

set -euo pipefail

PORT=9000
MAX_TOKENS=768
MODEL=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE_DIR="${SCRIPT_DIR}/quality-baselines"

PROMPTS='[
  "Write a Python function that returns the nth Fibonacci number using memoization.",
  "Find and fix the bug in this code:\n\ndef divide_list(nums, d):\n    return [n / d for n in nums if n % d == 0]\n\nprint(divide_list([10, 15, 20, 7], 0))",
  "A train leaves station A at 60 km/h. Two hours later, a second train leaves the same station on the same track at 90 km/h. How long after the second train departs does it catch the first one? Show your reasoning step by step.",
  "Return a JSON object (and nothing else) with keys \"name\", \"is_prime\", \"factors\" for the number 91.",
  "Explain what a race condition is and give a minimal Python example that demonstrates one using threading."
]'

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
sep()    { printf '%.0s─' {1..60}; echo; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

MODE=""
LABEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --save)
      [[ $# -lt 2 ]] && { echo "ERROR: --save requires a label" >&2; exit 1; }
      MODE="save"; LABEL="$2"; shift 2 ;;
    --diff)
      [[ $# -lt 2 ]] && { echo "ERROR: --diff requires a label" >&2; exit 1; }
      MODE="diff"; LABEL="$2"; shift 2 ;;
    --list)
      MODE="list"; shift ;;
    --model)
      [[ $# -lt 2 ]] && { echo "ERROR: --model requires a value" >&2; exit 1; }
      MODEL="$2"; shift 2 ;;
    --port)
      [[ $# -lt 2 ]] && { echo "ERROR: --port requires a value" >&2; exit 1; }
      PORT="$2"; shift 2 ;;
    --max-tokens)
      [[ $# -lt 2 ]] && { echo "ERROR: --max-tokens requires a value" >&2; exit 1; }
      MAX_TOKENS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "${MODE}" == "list" ]]; then
  bold "Saved baselines (${BASELINE_DIR}):"
  if [[ -d "${BASELINE_DIR}" ]] && [[ -n "$(ls -A "${BASELINE_DIR}" 2>/dev/null)" ]]; then
    for d in "${BASELINE_DIR}"/*/; do
      name="$(basename "${d}")"
      count="$(find "${d}" -name 'prompt-*.md' | wc -l)"
      echo "  ${name}  (${count} prompts)"
    done
  else
    yellow "  (none yet)"
  fi
  exit 0
fi

if [[ -z "${MODE}" ]]; then
  usage
fi

if [[ -z "${MODEL}" ]]; then
  red "ERROR: --model is required (must match the id OVMS reports at /v3/models)" >&2
  exit 1
fi

if ! curl -sf "http://localhost:${PORT}/v3/models" > /dev/null 2>&1; then
  red "ERROR: no server responding on port ${PORT} — start ovms first (see local-llm-yoga-slim7-ubuntu2404-ovms.md §4)"
  exit 1
fi

run_battery() {
  local outdir="$1"
  mkdir -p "${outdir}"
  local i=0
  while read -r prompt; do
    i=$((i + 1))
    printf "  Prompt %d/5... " "${i}"
    curl -sf "http://localhost:${PORT}/v3/chat/completions" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"${MODEL}\",\"temperature\":0,\"max_tokens\":${MAX_TOKENS},\"chat_template_kwargs\":{\"enable_thinking\":false},\"messages\":[{\"role\":\"user\",\"content\":${prompt}}]}" \
      | jq -r '.choices[0].message.content' > "${outdir}/prompt-${i}.md" \
      || { red "FAILED (server error or unexpected response)"; exit 1; }
    if [[ ! -s "${outdir}/prompt-${i}.md" ]]; then
      yellow "empty response — model may be stuck in thinking mode without emitting content"
    else
      green "done ($(wc -l < "${outdir}/prompt-${i}.md") lines)"
    fi
  done < <(jq -c '.[]' <<< "${PROMPTS}")
}

sep
bold "Quality battery (OVMS) — localhost:${PORT} — model: ${MODEL} — mode: ${MODE} ${LABEL}"
sep

case "${MODE}" in
  save)
    outdir="${BASELINE_DIR}/${LABEL}"
    if [[ -d "${outdir}" ]]; then
      yellow "Baseline '${LABEL}' already exists — overwriting."
    fi
    run_battery "${outdir}"
    date -Iseconds > "${outdir}/.saved-at" 2>/dev/null || true
    sep
    green "Saved baseline: ${outdir}"
    ;;
  diff)
    baseline_dir="${BASELINE_DIR}/${LABEL}"
    if [[ ! -d "${baseline_dir}" ]]; then
      red "ERROR: no baseline named '${LABEL}' — run --list to see available baselines"
      exit 1
    fi
    tmp_dir="$(mktemp -d)"
    run_battery "${tmp_dir}"
    sep
    bold "Diff vs baseline '${LABEL}':"
    changed=0
    for i in 1 2 3 4 5; do
      if diff -q "${baseline_dir}/prompt-${i}.md" "${tmp_dir}/prompt-${i}.md" > /dev/null 2>&1; then
        green "  prompt ${i}: unchanged"
      else
        yellow "  prompt ${i}: CHANGED — diff below"
        diff -u "${baseline_dir}/prompt-${i}.md" "${tmp_dir}/prompt-${i}.md" || true
        changed=$((changed + 1))
      fi
    done
    sep
    if [[ "${changed}" -eq 0 ]]; then
      green "No differences — output matches baseline '${LABEL}'."
    else
      yellow "${changed}/5 prompts differ from baseline '${LABEL}'. Review diffs above before concluding regression vs. expected variation."
    fi
    rm -rf "${tmp_dir}"
    ;;
esac
