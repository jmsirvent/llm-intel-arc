#!/usr/bin/env bash
# quality-test.sh — Fixed 5-prompt quality battery against a running llama-server.
#
# Not a rigorous benchmark: 5 prompts, no automated scoring. Catches obvious
# regressions (broken format, empty content, type-contract bugs) and gives a
# consistent basis to compare a new quant/candidate against the current pick
# for a model already in the catalog — see local-llm-yoga-slim7-ubuntu2404-llamacpp.md
# §7.1 (Gemma-4-12B Unsloth-vs-bartowski comparison) for the case this was built for.
#
# Usage:
#   ./quality-test.sh --save <label>            # run battery, save as new baseline
#   ./quality-test.sh --diff <label>             # run battery, diff vs saved baseline
#   ./quality-test.sh --list                     # list saved baselines
#   ./quality-test.sh --save <label> --port 8081 --max-tokens 1024
#
# Requires a model already loaded via start-server.sh / llama-server on --port
# (default 8080). Never load two models at once on this hardware (see CLAUDE.md).
#
# Known noise: even at temperature=0 on the SAME model/server, one run vs
# another can show 1/5 prompts with minor wording differences (SYCL parallel
# reduction order isn't guaranteed deterministic — ties in logits can flip).
# A single changed prompt with no structural/factual difference is expected
# noise, not a regression signal on its own. Treat multiple changed prompts,
# or a changed prompt with a different *conclusion* (wrong fix, broken
# format, wrong answer), as the real signal.

set -euo pipefail

PORT=8080
MAX_TOKENS=768
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
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
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

if ! curl -sf "http://localhost:${PORT}/health" > /dev/null 2>&1; then
  red "ERROR: no server responding on port ${PORT} — start one with ./start-server.sh first"
  exit 1
fi

run_battery() {
  local outdir="$1"
  mkdir -p "${outdir}"
  local i=0
  while read -r prompt; do
    i=$((i + 1))
    printf "  Prompt %d/5... " "${i}"
    curl -sf "http://localhost:${PORT}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"quality-test\",\"temperature\":0,\"max_tokens\":${MAX_TOKENS},\"chat_template_kwargs\":{\"enable_thinking\":false},\"messages\":[{\"role\":\"user\",\"content\":${prompt}}]}" \
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
bold "Quality battery — localhost:${PORT} — mode: ${MODE} ${LABEL}"
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
