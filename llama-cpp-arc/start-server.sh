#!/usr/bin/env bash
set -euo pipefail

# Project directory
LLAMACPP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/llama.cpp" && pwd)"
MODELS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/models" && pwd)"

# Activate oneAPI
source /opt/intel/oneapi/setvars.sh --force

# SYCL variables
export GGML_SYCL_DEVICE=0
export SYCL_CACHE_PERSISTENT=0  # workaround intel/llvm#21972 — see TODO.md
export ZES_ENABLE_SYSMAN=1

# Default model (pass as argument to override)
MODEL="${1:-${MODELS_DIR}/llama3.1-8b-instruct-q4_k_m.gguf}"

exec "${LLAMACPP_DIR}/build/bin/llama-server" \
  -m "${MODEL}" \
  --port 8080 \
  --host 0.0.0.0 \
  --n-gpu-layers 999 \
  --ctx-size 8192 \
  --parallel 1
