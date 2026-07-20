#!/usr/bin/env bash
# benchmark.sh — llama-bench wrapper for the llama.cpp SYCL stack (Intel Arc 140V)
#
# Discovers available GGUFs in models/, shows a selection menu, and runs
# llama-bench with the project baseline params (-p 512 -n 128 -ngl 999) so
# results are directly comparable to the §8.3 table in the guide.
#
# Usage:
#   ./benchmark.sh              # interactive menu
#   ./benchmark.sh <filename>   # skip menu, bench a specific GGUF

set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") [-h] [<filename|name>]"
  echo ""
  echo "Interactive llama-bench wrapper for the llama.cpp SYCL stack."
  echo ""
  echo "Arguments:"
  echo "  (none)          Show interactive model menu"
  echo "  <filename>      Bench a specific GGUF by filename (e.g. qwen3-8b-q4_k_m.gguf)"
  echo "  <name>          Match a model by display name substring (e.g. 'Gemma')"
  echo ""
  echo "Menu options:"
  echo "  1-N             Select a model to benchmark or download"
  echo "  a               Benchmark all available models sequentially"
  echo "  q               Quit"
  echo ""
  echo "Bench params: -p 512 -n 128 -ngl 999 (matches §8.3 baseline in the guide)"
  echo "Results saved to: bench-YYYYMMDD-HHMMSS.txt"
  exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="${SCRIPT_DIR}/models"
BENCH="${SCRIPT_DIR}/llama.cpp/build/bin/llama-bench"
DROP_CACHES="${SCRIPT_DIR}/drop-caches.sh"

# Baseline params — must match §8.3 for comparable results
PP=512
TG=128
NGL=999

# ── Color helpers ─────────────────────────────────────────────────────────────

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m'    "$*"; echo; }
sep()    { printf '%.0s─' {1..60}; echo; }

# ── Model catalog ─────────────────────────────────────────────────────────────
# One entry per lineup model. Format (pipe-separated):
#   "Display name|local_filename|hf_repo|hf_filename|expected_size"
#
# local_filename: exact filename on disk under models/ (case-sensitive)
# hf_filename:    exact filename in the HuggingFace repo (case-sensitive)
# Ollama-derived symlinks use lowercase; HF downloads preserve original case.

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

# ── Environment setup ─────────────────────────────────────────────────────────

activate_oneapi() {
  # setvars.sh sets PATH, LD_LIBRARY_PATH, MKLROOT — required for libsvml.so
  # It also references unset vars (e.g. OCL_ICD_FILENAMES) — under `set -u`
  # that aborts the whole script (nounset errors ignore `||` guards). Silence
  # nounset just for the source call, per Intel's documented workaround.
  if [[ ! -f /opt/intel/oneapi/setvars.sh ]]; then
    red "ERROR: /opt/intel/oneapi/setvars.sh not found"
    exit 1
  fi
  set +u
  source /opt/intel/oneapi/setvars.sh --force
  set -u
  export GGML_SYCL_DEVICE=0
  export SYCL_CACHE_PERSISTENT=0   # workaround intel/llvm#21972 (oneAPI ≥ 2025.3)
  export ZES_ENABLE_SYSMAN=1
}

check_prereqs() {
  if [[ ! -x "${BENCH}" ]]; then
    red "ERROR: llama-bench not found at ${BENCH}"
    echo "Build with:"
    echo "  source /opt/intel/oneapi/setvars.sh"
    echo "  cmake --build llama.cpp/build --config Release -j\$(nproc) --target llama-bench"
    exit 1
  fi
  if [[ ! -d "${MODELS_DIR}" ]]; then
    red "ERROR: models/ directory not found at ${MODELS_DIR}"
    exit 1
  fi
}

# ── Helpers ───────────────────────────────────────────────────────────────────

mem_available_gb() {
  awk '/^MemAvailable:/ { printf "%.1f GB", $2/1024/1024 }' /proc/meminfo
}

model_exists() {
  [[ -e "${MODELS_DIR}/$1" ]]
}

model_size() {
  du -sh "${MODELS_DIR}/$1" 2>/dev/null | cut -f1
}

drop_caches() {
  if [[ -x "${DROP_CACHES}" ]]; then
    "${DROP_CACHES}"
  else
    # Inline fallback if drop-caches.sh is missing. Needs sudo because
    # /proc/sys/vm/drop_caches and swapoff/swapon are root-only. Scope is the
    # whole machine (page cache + all swap, not just this benchmark's model) —
    # affects other running processes, not only llama-bench.
    yellow "WARNING: dropping system-wide page cache and cycling all swap (affects other processes)"
    sudo sync
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sudo swapoff -a && sudo swapon -a
  fi
}

# ── Benchmark runner ──────────────────────────────────────────────────────────

run_bench() {
  local display_name="$1"
  local filename="$2"
  local model_path="${MODELS_DIR}/${filename}"
  local result_file="${SCRIPT_DIR}/bench-$(date +%Y%m%d-%H%M%S).txt"

  sep
  bold "Benchmarking: ${display_name}"
  echo "  File   : ${model_path}"
  echo "  Params : -p ${PP} -n ${TG} -ngl ${NGL}"
  echo "  RAM    : $(mem_available_gb) available"
  sep

  drop_caches

  # Header for the result file
  {
    echo "=== ${display_name} — $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo "=== ${filename} ==="
  } > "${result_file}"

  "${BENCH}" \
    -m "${model_path}" \
    -p "${PP}" \
    -n "${TG}" \
    -ngl "${NGL}" \
    --output md \
    2>&1 | tee -a "${result_file}"
  local bench_status="${PIPESTATUS[0]}"

  if [[ "${bench_status}" -ne 0 ]]; then
    sep
    red "  FAILED: ${display_name} (llama-bench exit ${bench_status}) — see ${result_file}"
    sep
    return 1
  fi

  # Extract gen and prefill numbers from the markdown table for a clean summary
  # (|| true: a missing match must not abort the script under set -e — the
  # bench itself already succeeded above, this is just cosmetic reporting)
  local gen prefill
  gen=$(grep    "tg${TG}"  "${result_file}" | awk -F'|' '{gsub(/ /,"",$7); print $7}' | cut -d'±' -f1 | head -1) || true
  prefill=$(grep "pp${PP}" "${result_file}" | awk -F'|' '{gsub(/ /,"",$7); print $7}' | cut -d'±' -f1 | head -1) || true

  sep
  if [[ -n "${gen}" && -n "${prefill}" ]]; then
    green "  Gen (tg${TG})    : ${gen} tok/s"
    green "  Prefill (pp${PP}) : ${prefill} tok/s"
  else
    yellow "  Could not parse gen/prefill from output — check ${result_file}"
  fi
  echo "  RAM    : $(mem_available_gb) available"
  echo "  Saved  : ${result_file}"
  sep
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
    green "Download complete. Re-run the script to benchmark."
  fi
}

# ── Menu ─────────────────────────────────────────────────────────────────────

show_menu() {
  # Build two ordered lists: available first, then not downloaded
  local -a ordered_names=() ordered_files=() ordered_repos=() ordered_hffiles=() ordered_sizes=() ordered_available=()
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
  bold "  llama.cpp SYCL Benchmark — Intel Arc 140V"
  dim  "  llama-bench -p ${PP} -n ${TG} -ngl ${NGL} --output md"
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
  bold "   a) Benchmark all available models"
  bold "   q) Quit"
  sep

  while true; do
    read -r -p "  Select [1-${max_n}/a/q]: " choice
    case "${choice}" in
      q|Q)
        exit 0
        ;;
      a|A)
        local -a failed=()
        for i in "${!avail_names[@]}"; do
          run_bench "${avail_names[$i]}" "${avail_files[$i]}" || failed+=("${avail_names[$i]}")
        done
        if [[ ${#failed[@]} -gt 0 ]]; then
          sep
          red "  Failed (${#failed[@]}/${#avail_names[@]}): ${failed[*]}"
          sep
        fi
        exit 0
        ;;
      ''|*[!0-9]*)
        red "  Invalid — enter a number, 'a', or 'q'"
        continue
        ;;
      *)
        if (( choice >= 1 && choice <= max_n )); then
          local pos=$(( choice - 1 ))
          local type="${menu_type[$pos]}"
          local idx="${menu_idx[$pos]}"
          if [[ "${type}" == "avail" ]]; then
            run_bench "${avail_names[$idx]}" "${avail_files[$idx]}"
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

activate_oneapi
check_prereqs

if [[ $# -ge 1 ]]; then
  arg="$1"
  # Match against catalog by filename or display name substring
  matched=false
  for entry in "${CATALOG[@]}"; do
    IFS='|' read -r name file repo hffile size <<< "${entry}"
    if [[ "${file}" == "${arg}" || "${name}" == *"${arg}"* ]]; then
      if model_exists "${file}"; then
        run_bench "${name}" "${file}"
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
      run_bench "${arg}" "${arg}"
    elif [[ -f "${arg}" ]]; then
      run_bench "$(basename "${arg}")" "$(basename "${arg}")"
    else
      red "Not found in catalog or on disk: ${arg}"
      exit 1
    fi
  fi
else
  show_menu
fi
