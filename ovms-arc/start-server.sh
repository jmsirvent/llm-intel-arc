#!/usr/bin/env bash
# start-server.sh — Interactive launcher for ovms (OpenVINO Model Server, Intel Arc 140V)
#
# Discovers models already pulled under models/OpenVINO/, shows a selection menu, and
# starts ovms with the baseline runtime params documented in §4 of the guide.
#
# Unlike llama-cpp-arc's start-server.sh, there is no separate download step: OVMS's
# --source_model flag pulls a missing model automatically the moment the server starts
# (git+LFS from the official OpenVINO HF org). Selecting a model not yet on disk just
# takes longer on first start — the menu marks it so you're not surprised.
#
# Usage:
#   ./start-server.sh                       # interactive menu
#   ./start-server.sh <name>                # match a model by display name substring
#   ./start-server.sh OpenVINO/<repo>       # explicit source_model repo id (back-compat)

set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") [-h] [<name|repo>]"
  echo ""
  echo "Interactive launcher for ovms (OpenVINO Model Server)."
  echo ""
  echo "Arguments:"
  echo "  (none)          Show interactive model menu"
  echo "  <name>          Match a model by display name substring (e.g. 'Qwen3-VL')"
  echo "  <repo>          Explicit HF repo id (e.g. OpenVINO/Qwen3-8B-int4-ov)"
  echo ""
  echo "Menu options:"
  echo "  1-N             Select a model to start (pulls automatically if not local)"
  echo "  q               Quit"
  exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVMS_DIR="${SCRIPT_DIR}/ovms"
MODELS_DIR="${OVMS_DIR}/models"
SERVER="${OVMS_DIR}/bin/ovms"

# ── Model catalog ─────────────────────────────────────────────────────────────
# Only models validated in this project (see local-llm-yoga-slim7-ubuntu2404-ovms.md
# §5-7) — the whole Gemma-4 family is excluded, it's broken on OVMS (§7.1, upstream
# model_server#4178, no workaround). 2nd field: HF source_model repo id, also used to
# derive the local path (models/<repo>/). 3rd field: extra ovms flags, only added where
# actually validated — e.g. --tool_parser hermes3 is confirmed necessary for Qwen3-VL-8B's
# tool_calls to parse correctly; not assumed for Qwen3-8B/14B, never tested there.
CATALOG=(
  "Phi-4-mini-Instruct|OpenVINO/Phi-4-mini-instruct-int4-ov|"
  "DeepSeek-R1-Distill-Qwen-7B|OpenVINO/DeepSeek-R1-Distill-Qwen-7B-int4-ov|"
  "Qwen2.5-Coder-7B-Instruct|OpenVINO/Qwen2.5-Coder-7B-Instruct-int4-ov|"
  "Qwen2.5-Coder-14B-Instruct|OpenVINO/Qwen2.5-Coder-14B-Instruct-int4-ov|"
  "Qwen3-8B|OpenVINO/Qwen3-8B-int4-ov|"
  "Qwen3-14B|OpenVINO/Qwen3-14B-int4-ov|"
  "Qwen2.5-VL-7B-Instruct (vision, no tool-calling)|OpenVINO/Qwen2.5-VL-7B-Instruct-int4-ov|"
  "Qwen3-VL-8B-Instruct (vision + tool-calling)|OpenVINO/Qwen3-VL-8B-Instruct-int4-ov|--tool_parser hermes3"
)

# ── Color helpers ─────────────────────────────────────────────────────────────

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m'    "$*"; echo; }
sep()    { printf '%.0s─' {1..60}; echo; }

# ── Environment / prereqs ─────────────────────────────────────────────────────

check_prereqs() {
  if [[ ! -x "${SERVER}" ]]; then
    red "ERROR: ovms not found at ${SERVER}"
    echo "Install with the steps in local-llm-yoga-slim7-ubuntu2404-ovms.md §3."
    exit 1
  fi
}

model_exists() {
  [[ -d "${MODELS_DIR}/$1" ]]
}

# ── Server launcher ───────────────────────────────────────────────────────────

start_server() {
  local display_name="$1"
  local repo="$2"
  local extra_flags="$3"
  local -a extra_args=()
  [[ -n "${extra_flags}" ]] && read -ra extra_args <<< "${extra_flags}"

  sep
  bold "Starting: ${display_name}"
  echo "  Model  : ${repo}"
  if model_exists "${repo}"; then
    green "  Already pulled — starting immediately."
  else
    yellow "  Not pulled yet — ovms will download it now (size varies by model, a few GB)."
  fi
  echo "  Params : --target_device GPU --task text_generation --rest_port 9000${extra_flags:+ ${extra_flags}}"
  sep

  export LD_LIBRARY_PATH="${OVMS_DIR}/lib:${LD_LIBRARY_PATH:-}"
  export PYTHONPATH="${OVMS_DIR}/lib/python:${PYTHONPATH:-}"

  cd "${OVMS_DIR}"
  exec ./bin/ovms \
    --source_model "${repo}" \
    --model_repository_path ./models \
    --target_device GPU \
    --task text_generation \
    --rest_port 9000 \
    "${extra_args[@]}"
}

# ── Menu ─────────────────────────────────────────────────────────────────────

show_menu() {
  sep
  bold "  ovms launcher — Intel Arc 140V"
  dim  "  --target_device GPU --task text_generation --rest_port 9000"
  sep

  local n=1
  for entry in "${CATALOG[@]}"; do
    IFS='|' read -r name repo extra <<< "${entry}"
    if model_exists "${repo}"; then
      printf "  %2d) \033[32m✓\033[0m  %-52s\n" "${n}" "${name}"
    else
      printf "  %2d) \033[33m⬇\033[0m  %-52s \033[2m(will download)\033[0m\n" "${n}" "${name}"
    fi
    (( n++ ))
  done

  local max_n=$(( n - 1 ))
  echo ""
  bold "   q) Quit"
  sep

  while true; do
    read -r -p "  Select [1-${max_n}/q]: " choice
    case "${choice}" in
      q|Q)
        exit 0
        ;;
      ''|*[!0-9]*)
        red "  Invalid — enter a number or 'q'"
        continue
        ;;
      *)
        if (( choice >= 1 && choice <= max_n )); then
          IFS='|' read -r name repo extra <<< "${CATALOG[$(( choice - 1 ))]}"
          start_server "${name}" "${repo}" "${extra}"
        else
          red "  Invalid — enter a number between 1 and ${max_n}"
        fi
        ;;
    esac
  done
}

# ── Entry point ───────────────────────────────────────────────────────────────

check_prereqs

if [[ $# -ge 1 ]]; then
  arg="$1"
  matched=false
  for entry in "${CATALOG[@]}"; do
    IFS='|' read -r name repo extra <<< "${entry}"
    if [[ "${repo}" == "${arg}" || "${name}" == *"${arg}"* ]]; then
      start_server "${name}" "${repo}" "${extra}"
      matched=true
      break
    fi
  done
  if [[ "${matched}" == false ]]; then
    # Fall back: treat arg as a raw source_model repo id not in the catalog
    if [[ "${arg}" == */* ]]; then
      yellow "Not in the validated catalog — starting anyway with no extra flags."
      start_server "${arg}" "${arg}" ""
    else
      red "Not found in catalog: ${arg}"
      exit 1
    fi
  fi
else
  show_menu
fi
