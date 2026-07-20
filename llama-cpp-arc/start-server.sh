#!/usr/bin/env bash
# start-server.sh — Interactive launcher for llama-server (Intel Arc 140V SYCL stack)
#
# Discovers available GGUFs in models/, shows a selection menu, and starts
# llama-server with the baseline runtime params documented in §6.2 of the guide.
#
# Usage:
#   ./start-server.sh                       # interactive menu
#   ./start-server.sh <filename>            # skip menu, start a specific GGUF by filename
#   ./start-server.sh <name>                # match a model by display name substring
#   ./start-server.sh models/<file>.gguf    # explicit path (back-compat)

set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") [-h] [<filename|name|path>]"
  echo ""
  echo "Interactive launcher for llama-server (llama.cpp SYCL stack)."
  echo ""
  echo "Arguments:"
  echo "  (none)          Show interactive model menu"
  echo "  <filename>      Start a specific GGUF by filename (e.g. Qwen3-8B-Q4_K_M.gguf)"
  echo "  <name>          Match a model by display name substring (e.g. 'Gemma')"
  echo "  <path>          Explicit path to a GGUF (relative to models/ or absolute)"
  echo ""
  echo "Menu options:"
  echo "  1-N             Select a model to start or download"
  echo "  q               Quit"
  exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMACPP_DIR="${SCRIPT_DIR}/llama.cpp"
MODELS_DIR="${SCRIPT_DIR}/models"
SERVER="${LLAMACPP_DIR}/build/bin/llama-server"

# ── Model catalog ─────────────────────────────────────────────────────────────
# Same catalog as benchmark.sh — keep both in sync when the lineup changes.
CATALOG=(
  "Phi-4-mini-Instruct Q4_K_M|microsoft_Phi-4-mini-instruct-Q4_K_M.gguf|bartowski/microsoft_Phi-4-mini-instruct-GGUF|microsoft_Phi-4-mini-instruct-Q4_K_M.gguf|2.5 GB"
  "Gemma-4-E2B Q4_K_M|gemma-4-E2B-it-Q4_K_M.gguf|unsloth/gemma-4-E2B-it-GGUF|gemma-4-E2B-it-Q4_K_M.gguf|3.1 GB"
  "Gemma-4-E4B Q4_K_M|gemma-4-E4B-it-Q4_K_M.gguf|unsloth/gemma-4-e4b-it-GGUF|gemma-4-E4B-it-Q4_K_M.gguf|4.9 GB"
  "DeepSeek-R1-Distill-Qwen-7B Q4_K_M|DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf|bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF|DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf|4.7 GB"
  "Qwen2.5-Coder-7B-Instruct Q4_K_M|Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf|bartowski/Qwen2.5-Coder-7B-Instruct-GGUF|Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf|4.7 GB"
  "Llama-3.1-8B-Instruct Q4_K_M|Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf|bartowski/Meta-Llama-3.1-8B-Instruct-GGUF|Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf|4.9 GB"
  "Qwen3-8B Q4_K_M|Qwen3-8B-Q4_K_M.gguf|unsloth/Qwen3-8B-GGUF|Qwen3-8B-Q4_K_M.gguf|5.2 GB"
  "Gemma-4-12B UD-Q4_K_XL|gemma-4-12b-it-UD-Q4_K_XL.gguf|unsloth/gemma-4-12b-it-GGUF|gemma-4-12b-it-UD-Q4_K_XL.gguf|7.4 GB"
  "Ornith-1.0-9B Q6_K|ornith-1.0-9b-Q6_K.gguf|deepreinforce-ai/Ornith-1.0-9B-GGUF|ornith-1.0-9b-Q6_K.gguf|7.4 GB"
  "Qwen3-14B Q4_K_M (optional)|Qwen3-14B-Q4_K_M.gguf|unsloth/Qwen3-14B-GGUF|Qwen3-14B-Q4_K_M.gguf|9.0 GB"
  "Qwen2.5-Coder-14B-Instruct Q4_K_M|Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf|bartowski/Qwen2.5-Coder-14B-Instruct-GGUF|Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf|9.0 GB"
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
    red "ERROR: llama-server not found at ${SERVER}"
    echo "Build with:"
    echo "  source /opt/intel/oneapi/setvars.sh"
    echo "  cmake --build llama.cpp/build --config Release -j\$(nproc) --target llama-server"
    exit 1
  fi
  if [[ ! -d "${MODELS_DIR}" ]]; then
    red "ERROR: models/ directory not found at ${MODELS_DIR}"
    exit 1
  fi
}

model_exists() {
  [[ -e "${MODELS_DIR}/$1" ]]
}

model_size() {
  du -sh "${MODELS_DIR}/$1" 2>/dev/null | cut -f1
}

# ── Server launcher ───────────────────────────────────────────────────────────

start_server() {
  local display_name="$1"
  local filename="$2"
  local model_path="${MODELS_DIR}/${filename}"

  sep
  bold "Starting: ${display_name}"
  echo "  File   : ${model_path}"
  echo "  Params : --n-gpu-layers 999 --ctx-size 32768 --parallel 1 --port 8080"
  sep

  # Activate oneAPI
  # setvars.sh references unset vars (e.g. OCL_ICD_FILENAMES) — under `set -u`
  # that aborts the whole script (nounset errors ignore `||` guards). Silence
  # nounset just for the source call, per Intel's documented workaround.
  if [[ ! -f /opt/intel/oneapi/setvars.sh ]]; then
    red "ERROR: /opt/intel/oneapi/setvars.sh not found"
    exit 1
  fi
  set +u
  source /opt/intel/oneapi/setvars.sh --force
  set -u

  # SYCL variables
  export GGML_SYCL_DEVICE=0
  export SYCL_CACHE_PERSISTENT=0  # workaround intel/llvm#21972 — see TODO.md
  export ZES_ENABLE_SYSMAN=1

  exec "${SERVER}" \
    -m "${model_path}" \
    --port 8080 \
    --host 0.0.0.0 \
    --n-gpu-layers 999 \
    --ctx-size 32768 \
    --parallel 1
}

# ── Download prompt ───────────────────────────────────────────────────────────

show_download_prompt() {
  local display_name="$1"
  local hf_repo="$2"
  local hf_file="$3"
  local expected_size="$4"

  sep
  yellow "  Not downloaded: ${display_name}  (~${expected_size})"
  echo ""
  echo "  Verify exact filename (HF filenames are case-sensitive):"
  printf "    hf download %s --dry-run\n" "${hf_repo}"
  echo ""
  echo "  Download:"
  printf "    hf download %s \\\\\n" "${hf_repo}"
  printf "      %s \\\\\n" "${hf_file}"
  printf "      --local-dir %s/\n" "${MODELS_DIR}"
  sep
  read -r -p "  Download now? [y/N] " answer
  if [[ "${answer}" =~ ^[Yy]$ ]]; then
    hf download "${hf_repo}" "${hf_file}" --local-dir "${MODELS_DIR}/"
    echo ""
    green "Download complete. Re-run the script to start the server."
  fi
}

# ── Menu ─────────────────────────────────────────────────────────────────────

show_menu() {
  local -a avail_names=() avail_files=()
  local -a missing_names=() missing_files=() missing_repos=() missing_hffiles=() missing_sizes=()

  for entry in "${CATALOG[@]}"; do
    IFS='|' read -r name file repo hffile size <<< "${entry}"
    if model_exists "${file}"; then
      avail_names+=("${name}")
      avail_files+=("${file}")
    else
      missing_names+=("${name}")
      missing_files+=("${file}")
      missing_repos+=("${repo}")
      missing_hffiles+=("${hffile}")
      missing_sizes+=("${size}")
    fi
  done

  sep
  bold "  llama-server launcher — Intel Arc 140V"
  dim  "  --n-gpu-layers 999 --ctx-size 8192 --parallel 1 --port 8080"
  sep

  local n=1
  local -a menu_type=()   # "avail" or "missing"
  local -a menu_idx=()    # index into avail_* or missing_* arrays

  if [[ ${#avail_names[@]} -gt 0 ]]; then
    bold "  Available:"
    for i in "${!avail_names[@]}"; do
      local sz
      sz=$(model_size "${avail_files[$i]}")
      printf "  %2d) \033[32m✓\033[0m  %-48s \033[2m%s\033[0m\n" \
        "${n}" "${avail_names[$i]}" "${sz}"
      menu_type+=("avail")
      menu_idx+=("${i}")
      (( n++ ))
    done
  fi

  if [[ ${#missing_names[@]} -gt 0 ]]; then
    echo ""
    bold "  Not downloaded:"
    for i in "${!missing_names[@]}"; do
      printf "  %2d) \033[31m✗\033[0m  %-48s \033[2m~%s\033[0m\n" \
        "${n}" "${missing_names[$i]}" "${missing_sizes[$i]}"
      menu_type+=("missing")
      menu_idx+=("${i}")
      (( n++ ))
    done
  fi

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
          local pos=$(( choice - 1 ))
          local type="${menu_type[$pos]}"
          local idx="${menu_idx[$pos]}"
          if [[ "${type}" == "avail" ]]; then
            start_server "${avail_names[$idx]}" "${avail_files[$idx]}"
          else
            show_download_prompt \
              "${missing_names[$idx]}" \
              "${missing_repos[$idx]}" \
              "${missing_hffiles[$idx]}" \
              "${missing_sizes[$idx]}"
          fi
          exit 0
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
  # Match against catalog by filename or display name substring
  matched=false
  for entry in "${CATALOG[@]}"; do
    IFS='|' read -r name file repo hffile size <<< "${entry}"
    if [[ "${file}" == "${arg}" || "${name}" == *"${arg}"* ]]; then
      if model_exists "${file}"; then
        start_server "${name}" "${file}"
      else
        show_download_prompt "${name}" "${repo}" "${hffile}" "${size}"
      fi
      matched=true
      break
    fi
  done
  if [[ "${matched}" == false ]]; then
    # Fall back: treat arg as a raw path relative to models/ or absolute
    if [[ -f "${MODELS_DIR}/${arg}" ]]; then
      start_server "${arg}" "${arg}"
    elif [[ -f "${arg}" ]]; then
      start_server "$(basename "${arg}")" "$(basename "${arg}")"
    else
      red "Not found in catalog or on disk: ${arg}"
      exit 1
    fi
  fi
else
  show_menu
fi
