# Local LLM Inference — Yoga Slim 7 14ILL10 (llama.cpp SYCL)
**Ubuntu 24.04 LTS · Intel Core Ultra 7 258V · Intel Arc 140V (Xe2) · 32 GB LPDDR5X**

> **Living document.** Sections validated on real hardware are marked ✅.
> Sections marked ⚠️ are documented but pending testing — they may require adjustments.

---

## Table of contents

1. [Hardware summary and solution architecture](#1-hardware-summary-and-solution-architecture)
2. [System prerequisites](#2-system-prerequisites)
3. [Intel GPU Compute Runtime (Level Zero — host-side)](#3-intel-gpu-compute-runtime-level-zero--host-side)
4. [oneAPI — SYCL compiler and Intel MKL](#4-oneapi--sycl-compiler-and-intel-mkl)
5. [Building llama.cpp with SYCL backend](#5-building-llamacpp-with-sycl-backend)
6. [llama-server — configuration and startup](#6-llama-server--configuration-and-startup)
7. [Recommended models](#7-recommended-models)
8. [Model management and benchmarking](#8-model-management-and-benchmarking)
   - [8.4 Speculative decoding](#84-speculative-decoding)
9. [Integration with external tools](#9-integration-with-external-tools)
10. [Systemd service (autostart)](#10-systemd-service-autostart)
11. [OS tuning for performance](#11-os-tuning-for-performance)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Hardware summary and solution architecture

| Component | Detail |
|---|---|
| CPU | Intel Core Ultra 7 258V (Lunar Lake, 8 cores @ 4.7 GHz) |
| GPU | Intel Arc 140V (Xe2 iGPU, 8 Xe2 cores, driver: `xe`) |
| NPU | Intel AI Boost / Lunar Lake NPU (`intel_vpu`) |
| RAM | 32 GB LPDDR5X-8533 unified (shared CPU/GPU/NPU, ~97 GB/s) |
| Storage | Samsung NVMe PM9C1b 1 TB |
| OS | Ubuntu 24.04 LTS, kernel 6.19.10 |

### Why native SYCL llama.cpp

The previous stack (`../ipex-llm/`) used IPEX-LLM, an Intel-patched inference server for SYCL/Level Zero — see that project's own docs for its architecture. That project was archived in January 2026. llama.cpp is the actual underlying inference engine — IPEX-LLM wrapped it in Docker to distribute the precompiled Intel toolchain.

This stack compiles llama.cpp directly with the Intel `icx/icpx` compiler (oneAPI), no Docker intermediary. What you gain:

- IQ quantizations (IQ4\_XS, IQ3\_M) — better quality per GB than K\_M
- Up-to-date model support with llama.cpp upstream
- OpenAI-compatible API at `localhost:8080` — any standard OpenAI-client integration works unchanged

```
VS Code (Twinny / Cline / Roo Code) · Open WebUI · Python scripts
                     │
                     │  OpenAI-compatible REST  (localhost:8080)
                     ▼
            llama-server  (llama.cpp SYCL)
                     │
                     │  SYCL / Level Zero
                     ▼
          Intel Arc 140V  (Xe2, driver xe)
          ──────────────────────────────────
          LPDDR5X-8533  ·  32 GB  unified memory
```

---

## 2. System prerequisites ✅

### 2.1 Verify the GPU is active with the xe driver

```bash
# xe driver active for the iGPU (NOT i915 — Xe2 uses a different driver)
lspci -k | grep -A3 -i "VGA\|Display"
# Expected: Kernel driver in use: xe

# Available DRI devices
ls -la /dev/dri/
# Expected: card1, renderD128
```

### 2.2 User groups

```bash
# Add user to render and video groups
sudo usermod -aG render,video $USER

# Verify membership
groups $USER
# Must include: render video

# IMPORTANT: log out and back in for the groups to take effect.
```

### 2.3 Build dependencies

```bash
sudo apt update
sudo apt install -y \
  git cmake ninja-build \
  pkg-config \
  libgomp1 \
  libssl-dev \
  python3-pip
```

---

## 3. Intel GPU Compute Runtime (Level Zero — host-side) ✅

This step installs the Level Zero userspace libraries on the Ubuntu 24.04 host.
These are what allow the SYCL runtime to communicate with the kernel's `xe` driver.

> **Validated method for Lunar Lake (Xe2):** the official Intel repository (`repositories.intel.com/gpu/ubuntu noble`) provides older Level Zero versions (1.21.x). The working method is the **Canonical kobuk-team Intel Graphics PPA**, the current successor to the discontinued `ubuntu-oem/intel-graphics-preview` PPA:
> [`https://launchpad.net/~kobuk-team/+archive/ubuntu/intel-graphics`](https://launchpad.net/~kobuk-team/+archive/ubuntu/intel-graphics)

```bash
# Add the Canonical kobuk-team Intel Graphics PPA
# (successor to the discontinued ppa:ubuntu-oem/intel-graphics-preview)
sudo add-apt-repository ppa:kobuk-team/intel-graphics
sudo apt update

# Install compute runtime with Xe2 / Lunar Lake support
sudo apt install -y \
  libze-intel-gpu1 \
  libze1 \
  libze-dev \
  intel-opencl-icd \
  intel-level-zero-gpu \
  level-zero \
  clinfo

# Verify GPU detection via Level Zero
clinfo -l
# Expected:
# Platform #0: Intel(R) OpenCL Graphics
#  -- Device #0: Intel(R) Arc(TM) Graphics

ls /dev/dri/
# card1  renderD128
```

> **Why the PPA:** `repositories.intel.com/gpu/ubuntu noble` provides Level Zero 1.21.x — too old for Xe2/Lunar Lake. The `kobuk-team/intel-graphics` PPA (Canonical team maintaining Intel graphics support in Ubuntu) provides 1.28.x, which is what was validated on this hardware.

---

## 4. oneAPI — SYCL compiler and Intel MKL ✅

> **Architecture note:** the `apt.repos.intel.com/oneapi` repository (compiler + MKL) is **separate** from the GPU driver repository that does not work with Xe2. The oneAPI compiler packages do work on Ubuntu 24.04 Noble.

```bash
# Add GPG key and oneAPI repository
wget -O- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
  | gpg --dearmor \
  | sudo tee /usr/share/keyrings/oneapi-archive-keyring.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] \
  https://apt.repos.intel.com/oneapi all main" \
  | sudo tee /etc/apt/sources.list.d/oneAPI.list

sudo apt update

# Find the latest available version (Intel does not maintain unversioned metapackages reliably)
apt-cache search intel-oneapi-dpcpp-cpp | sort -V | tail -5
# e.g.: intel-oneapi-dpcpp-cpp-2026.0

# Install SYCL compiler (icx/icpx) + MKL — use the versioned package names from the search above
sudo apt install -y \
  intel-oneapi-dpcpp-cpp-2026.0 \
  intel-oneapi-mkl-2026.0 \
  intel-oneapi-mkl-devel-2026.0

# Verify installation
source /opt/intel/oneapi/setvars.sh

icx --version
# Intel(R) oneAPI DPC++/C++ Compiler ...

# Verify that sycl-ls detects the Arc GPU
sycl-ls
# Expected (among others):
# [level_zero:gpu][level_zero:0] Intel(R) oneAPI Unified Runtime over Level-Zero V2, Intel(R) Arc(TM) Graphics ...
# [opencl:gpu][opencl:1] Intel(R) OpenCL Graphics, Intel(R) Arc(TM) Graphics OpenCL 3.0 NEO ...
```

> ⚠️ **If `sycl-ls` does not show the Arc 140V:** the problem is the Level Zero runtime (§3), not the compiler. Verify that `clinfo -l` shows the GPU before continuing.

> **`setvars.sh`**: this script sets up `PATH`, `LD_LIBRARY_PATH`, `MKLROOT` and other environment variables needed for icx/icpx and MKL. It must be run in each terminal session before building or starting the server. See §6 for automatic activation via systemd.

---

## 5. Building llama.cpp with SYCL backend ✅

```bash
# Clone llama.cpp
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp

# Activate oneAPI environment (if not already active)
source /opt/intel/oneapi/setvars.sh

# Build with SYCL backend
cmake -B build \
  -DGGML_SYCL=ON \
  -DCMAKE_C_COMPILER=icx \
  -DCMAKE_CXX_COMPILER=icpx \
  -DGGML_SYCL_F16=ON \
  -DCMAKE_BUILD_TYPE=Release

cmake --build build --config Release -j$(nproc) \
  --target llama-server llama-bench llama-cli

# Verify the binary detects the GPU
./build/bin/llama-server --list-devices
```

Expected output:
```
Available devices:
  SYCL0: Intel(R) Arc(TM) Graphics (29283 MiB, 6959 MiB free)
```

> **29283 MiB total (~28.6 GB):** the `xe` driver exposes almost all unified RAM as the GPU pool — expected on Lunar Lake. Free memory shown here (6959 MiB) is a single snapshot, not a baseline — it varies with OS load and with GPU pool retention from prior sessions (§7 memory budget). Always re-check with `--list-devices` or `xpu-smi stats -d 0` before assuming a figure from this document still holds.

> **`DGGML_SYCL_F16=ON`**: enables FP16 operations in the SYCL backend. Reduces memory usage and can improve throughput on hardware with native FP16 support such as the Arc 140V Xe2.

> **Build time:** compiling with icx/icpx takes longer than with gcc/clang due to the depth of SYCL optimizations. Expect 5–15 minutes on the Core Ultra 7 258V (8 cores).

> **Expected warnings during build:** 3 warnings in `ggml-sycl.cpp` about unused variables (`use_mkl_direct`, `last_str`, `type_size_src0`) — upstream code, harmless, build is correct if it reaches `[100%] Built target llama-cli`.

---

## 6. llama-server — configuration and startup ✅

### 6.1 SYCL environment variables

```bash
# Activate oneAPI (required each session)
source /opt/intel/oneapi/setvars.sh

# Select the Arc 140V (first Level Zero device)
export GGML_SYCL_DEVICE=0

# Persistent SYCL kernel cache disabled — workaround for intel/llvm#21972:
# getSortedImages() calls strcmp() on a NULL GetName() from dynamically-linked kernels,
# causing SIGSEGV on first dispatch. Affects oneAPI ≥ 2025.3 (libsycl.so.9).
# Cost: 2–5 min JIT recompilation on each cold start. Inference speed unaffected.
# See: llama-cpp-arc/TODO.md — re-enable to SYCL_CACHE_PERSISTENT=1 once Intel fixes it.
export SYCL_CACHE_PERSISTENT=0

# Allows the runtime to query GPU metrics
export ZES_ENABLE_SYSMAN=1
```

### 6.2 Start the server

```bash
cd ~/llm/llama-cpp-arc/llama.cpp

./build/bin/llama-server \
  -m ../models/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf \
  --port 8080 \
  --host 0.0.0.0 \
  --n-gpu-layers 999 \
  --ctx-size 8192 \
  --parallel 1

# Verify the server responds
curl http://localhost:8080/health
# {"status":"ok"}

# Test inference
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"Hello"}],"max_tokens":20}' \
  | python3 -m json.tool
```

| Parameter | Value | Description |
|---|---|---|
| `--n-gpu-layers 999` | 999 (all) | Load all layers onto GPU — no CPU/GPU split |
| `--ctx-size` | 8192 | Default context; increase to 16384–32768 depending on model and available RAM |
| `--parallel` | 1 | Explicit single-user — avoids reserving buffers for parallel requests |
| `--port` | 8080 | API port for this server |
| `--host` | 0.0.0.0 | Listen on all interfaces |

### 6.3 First model load

Every startup compiles SYCL kernels JIT for the Arc 140V Xe2 — this takes **2–5 minutes** and is normal. The persistent kernel cache (`SYCL_CACHE_PERSISTENT=1`) is disabled due to a bug in oneAPI 2026.0 (`libsycl.so.9`) that causes a SIGSEGV in `PersistentDeviceCodeCache::getItemFromDisc`. Re-enable it once Intel ships a fix.

> **Cache directories** (if re-enabling after a fix): `~/.cache/libsycl_cache/` and `~/.cache/neo_compiler_cache/` — these are the actual locations used by oneAPI 2026.0, not `~/.cache/sycl/`. Clear both if switching between oneAPI versions or after a kernel driver update.

### 6.4 Startup script

`~/llm/llama-cpp-arc/start-server.sh` is an interactive launcher, not a fixed one-model script. It shares the same model catalog as `benchmark.sh` (§7.1 lineup) and, with no arguments, shows a menu listing every model in the catalog: available ones (✓, ready to start) and not-yet-downloaded ones (✗, with a ready-to-run `hf download` command and an interactive download prompt). Selecting an available model starts `llama-server` with the baseline params from §6.2 (`--n-gpu-layers 999 --ctx-size 8192 --parallel 1 --port 8080`).

```bash
chmod +x ~/llm/llama-cpp-arc/start-server.sh

# Usage
./start-server.sh                             # interactive menu
./start-server.sh Qwen3-8B-Q4_K_M.gguf        # start a specific GGUF by filename
./start-server.sh Gemma                       # match by display-name substring
./start-server.sh models/Qwen3-8B-Q4_K_M.gguf # explicit path (back-compat)
```

See the script itself for the full implementation — the catalog, download-prompt, and menu logic mirror `benchmark.sh` (§8.3) exactly, so both scripts should be updated together when the model lineup changes.

---

## 7. Recommended models ✅

### Memory budget

- Total RAM: 32 GB
- OS + desktop + apps in use: ~11–12 GB in typical daily use

There is no fixed "available for models" figure — free memory on this unified-memory system varies with OS load and, more importantly, with the `xe` driver's GPU pool retention behavior (next note). Observed free memory has ranged from ~7 GB (GPU pool populated by a prior session, driver not reclaiming pages) up to ~19–20 GB (clean reboot, no prior GPU allocations). Treat any single number in this document as a snapshot, not a ceiling — always check current availability before loading a large model (`free -h`, `xpu-smi stats -d 0`).

> With 32 GB of unified RAM it is not possible to separate "GPU VRAM" from the rest of RAM. The Arc 140V accesses the same LPDDR5X pool as the CPU.

> ⚠️ **xe driver behavior:** once the xe driver assigns RAM pages to the GPU pool (on first model load), it does not return them to the system even if the model is unloaded. Memory is only fully recovered with a reboot or `echo 3 > /proc/sys/vm/drop_caches` after stopping the server.

### 7.1 Recommended models (GGUFs from Hugging Face)

Always use verified publishers. Two categories are acceptable:

- **Trusted GGUF quantizers** — community publishers with an established track record of correct quantization: **bartowski**, **unsloth**, **lmstudio-community**, **deepreinforce-ai** (author of Ornith, not a third-party quantizer, but reviewed as trustworthy for their own model).
- **Original model publishers** — the organization that trained the model, when they publish GGUF directly: **Google** (Gemma), **Qwen team / Alibaba**, **DeepSeek**. Prefer a trusted quantizer's GGUF when one exists; fall back to the original publisher's own GGUF (e.g. `google/gemma-4-*-qat-q4_0-gguf`) when no third-party quant is available yet.

Do not use unknown or unreviewed publishers outside these two categories.

| Model | Quant | GGUF size | RAM (bench) | Primary use | Alternative use | HF repo | Gen tok/s |
|---|---|---|---|---|---|---|---|
| Phi-4-mini-Instruct | Q4\_K\_M | 2.5 GB | 2.31 GiB | FIM autocomplete (Twinny) | Low-latency general Q&A when speed matters more than depth (fastest model in the lineup) | bartowski | **33.97** |
| Gemma-4-E4B-IT | Q4\_K\_M | 4.9 GB | 4.62 GiB | Fast general-purpose chat | Vision/audio understanding (multimodal input) when a lighter model than Gemma-4-12B suffices | unsloth/gemma-4-e4b-it-GGUF | **26.73** |
| DeepSeek-R1-Distill-Qwen-7B | Q4\_K\_M | 4.7 GB | 4.36 GiB | Reasoning with chain-of-thought (`<think>` blocks) | Explaining/debugging logic step-by-step — the visible reasoning trace helps surface why an answer is wrong, not just that it is | bartowski | **20.93** |
| Qwen2.5-Coder-7B-Instruct | Q4\_K\_M | 4.7 GB | 4.36 GiB | Fast coding / autocomplete | General-purpose lightweight assistant (non-code chat) when Llama-3.1-8B is already loaded elsewhere | bartowski | **19.42** |
| Llama-3.1-8B-Instruct | Q4\_K\_M | 4.9 GB | 4.58 GiB | Fast general purpose | Multilingual tasks / translation — a documented strength of the Llama 3.1 base training | bartowski | **18.87** |
| Qwen3-8B | Q4\_K\_M | 5.2 GB | 4.86 GiB | Reasoning / long context | Tool-calling / agentic chat — Qwen3 has native function-calling support | unsloth | **15.25** |
| Gemma-4-12B-IT | Q4\_K\_M | 7.7 GB | 7.12 GiB | Vision + audio multimodal reasoning | Long-document analysis / summarization, leveraging the 256K context window | bartowski/gemma-4-12b-it-GGUF | **11.34** |
| Ornith-1.0-9B | Q6\_K | 7.4 GB | 6.84 GiB | Agentic coding / tool-calling | Terminal/devops automation — trained on Terminal-Bench, not just SWE-Bench | deepreinforce-ai/Ornith-1.0-9B-GGUF | **10.20** |
| Qwen3-14B *(optional)* | Q4\_K\_M | 9.0 GB | 8.38 GiB | Deep reasoning | Knowledge-intensive Q&A benefiting from the larger parameter count vs Qwen3-8B | unsloth | **10.09** |
| Qwen2.5-Coder-14B-Instruct | Q4\_K\_M | 9.0 GB | 8.37 GiB | Agentic coding (Cline) | Code review / explaining unfamiliar code — larger model gives more reliable explanations than the 7B | bartowski | **9.92** |

> RAM column: memory allocated by llama.cpp SYCL during `llama-bench` (`-p 512 -n 128 -ngl 999`).
> Full benchmark results and IPEX-LLM comparison: §8.3.
> Qwen3-14B: same speed as the 14B coders but double the RAM of Qwen3-8B — only worth it when reasoning depth matters more than throughput. Speculative decoding with Qwen3-8B as draft was tested and found not viable on this hardware (§8.4) — despite 64% acceptance, net throughput regresses 38%.
> Gemma-4-12B: replaces Gemma-3-12B (+45% gen speed: 11.34 vs 7.84 tok/s), adds 256K context, audio/video, configurable thinking mode. Repo: `bartowski/gemma-4-12b-it-GGUF` (no `google_` prefix, unlike Gemma 3). The `mtp-gemma-4-12B-it-Q4_0.gguf` MTP head is not usable as a draft model in llama.cpp upstream (`ctx_other` requirement, §8.4) — no download needed for speculative decoding purposes.
> Gemma-4-E4B: MatFormer architecture — 7.52B declared params but runs at the efficiency of a ~4B model. Fastest general-purpose model under 5 GiB (26.73 tok/s). Vocab matches Gemma-4-12B (`n_vocab = 262144` in both) but was never tested as a separate draft model in §8.4 — only its MTP head was tested (fails, `ctx_other` incompatibility, unrelated to vocab). Untested as a §8.4-style separate draft; given the Gemma-4-E2B result (net regression despite matching vocab), unlikely to be worth pursuing.
> DeepSeek-R1-Distill-Qwen-7B: Qwen2 architecture distilled from DeepSeek-R1. Faster than Qwen3-8B for reasoning tasks with internal chain-of-thought (`<think>` blocks); shares tokenizer with Qwen2.5-Coder models.

### 7.2 Ornith-1.0-9B — specific configuration

Ornith-1.0-9B ([GGUF repo](https://huggingface.co/deepreinforce-ai/Ornith-1.0-9B-GGUF)) is a dense 9B model based on Qwen 3.5, post-trained for agentic coding (SWE-Bench, Terminal-Bench, NL2Repo). It uses internal `<think>` reasoning blocks before answering — expect higher TTFT than a standard 9B model.

**Recommended quantization:** Q6\_K (7.36 GB) — fits comfortably in the ~20 GB available pool leaving headroom for context and OS. Q8\_0 (9.53 GB) is also viable.

**Download:**

```bash
hf download deepreinforce-ai/Ornith-1.0-9B-GGUF ornith-1.0-9b-Q6_K.gguf \
  --local-dir ~/llm/llama-cpp-arc/models/
```

**Start the server with the recommended sampling parameters:**

```bash
./build/bin/llama-server \
  -m models/ornith-1.0-9b-Q6_K.gguf \
  --port 8080 \
  --host 0.0.0.0 \
  --n-gpu-layers 999 \
  --ctx-size 32768 \
  --parallel 1 \
  --temp 0.6 \
  --top-p 0.95 \
  --top-k 20
```

> The 262K context window is supported by the model but loading it fully requires ~20 GB of KV cache. In daily use, 32768 tokens is a practical ceiling that keeps memory pressure manageable.

**Available quantizations:**

| Quant | Size | Notes |
|---|---|---|
| Q4\_K\_M | 5.63 GB | Minimum recommended |
| Q5\_K\_M | 6.47 GB | Good quality/size balance |
| Q6\_K | 7.36 GB | **Recommended** — near-lossless on 9B |
| Q8\_0 | 9.53 GB | Near full precision |
| BF16 | 17.9 GB | Leaves very little headroom |

### 7.3 Downloading models

```bash
# Install hf (huggingface_hub CLI — huggingface-cli is deprecated as of v1.21.0)
pip install --user --upgrade huggingface_hub

mkdir -p ~/llm/llama-cpp-arc/models

# List files in a repo before downloading
hf download <repo_id> --dry-run

# Download a specific file — filename goes as positional argument (exact case matters)
hf download bartowski/Qwen2.5-Coder-14B-Instruct-GGUF \
  Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf \
  --local-dir ~/llm/llama-cpp-arc/models

# Download Qwen3-8B
hf download unsloth/Qwen3-8B-GGUF \
  Qwen3-8B-Q4_K_M.gguf \
  --local-dir ~/llm/llama-cpp-arc/models
```

---

## 8. Model management and benchmarking ✅

### 8.1 Verify GPU inference

```bash
# With the server running, send a prompt and verify the response
curl -s http://localhost:8080/completion \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Explain in exactly 50 words what a transformer neural network is.",
    "n_predict": 128,
    "stream": false
  }' | python3 -m json.tool | grep -E '"content"|"tokens_per_second"|"timings"'

# OpenAI-compatible API (chat completions)
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": false
  }' | python3 -m json.tool
```

### 8.2 GPU monitoring during inference ✅

> `intel_gpu_top` **does not work** with the `xe` driver (Lunar Lake/Xe2). Use `xpu-smi` instead.

```bash
# Point-in-time snapshot
xpu-smi stats -d 0

# Continuous monitoring: utilization + memory + frequency
# -m 0=GPU_UTIL, 5=MEM_UTIL, 18=MEM_USED  |  -i interval in seconds
sudo xpu-smi dump -d 0 -m 0,5,18 -i 1

# Without sudo (no engine utilization, rest works)
xpu-smi dump -d 0 -m 5,18 -i 1

# Active frequency via sysfs (no extra tools needed)
watch -n1 'echo "Act: $(cat /sys/class/drm/card1/device/tile0/gt0/freq0/act_freq) MHz" && \
           echo "Cur: $(cat /sys/class/drm/card1/device/tile0/gt0/freq0/cur_freq) MHz"'
```

**Practical combination during inference** (two terminals):
```bash
# Terminal 1 — GPU
sudo xpu-smi dump -d 0 -m 0,5,18 -i 1

# Terminal 2 — system memory
watch -n1 'grep -E "MemFree|MemAvailable" /proc/meminfo'
```

### 8.3 Benchmark with llama-bench ✅

```bash
# Basic benchmark: prefill (512 tokens) + generation (128 tokens)
./build/bin/llama-bench \
  -m models/Qwen3-8B-Q4_K_M.gguf \
  -p 512 -n 128 \
  -ngl 999 \
  --output md

# Useful options:
# -p <tokens>       prompt tokens for prefill test (default: 512)
# -n <tokens>       tokens to generate (default: 128)
# -ngl <layers>     GPU layers (999 = all on GPU)
# --output md       Markdown table output, ready to paste into docs
# Note: no -c flag — context size = -p + -n, no pre-allocation needed
```

> **`~/llm/llama-cpp-arc/benchmark.sh`** wraps the command above in an interactive menu — same model catalog and ✓/✗ availability display as `start-server.sh` (§6.4), but running `llama-bench` with the baseline params (`-p 512 -n 128 -ngl 999 --output md`) instead of starting a server. It drops GPU/system caches between runs (`drop-caches.sh`) and saves each result to a timestamped `bench-YYYYMMDD-HHMMSS.txt` file. Usage: `./benchmark.sh` (menu), `./benchmark.sh <filename>` or `./benchmark.sh <name>` (specific model), `./benchmark.sh` menu option `a` (benchmark every available model sequentially).

**llama-bench results — llama.cpp SYCL (Arc 140V, `-p 512 -n 128 -ngl 999`, Flash Attention off):**

> ⚠️ Run sequentially in a loop. The `xe` driver retains GPU memory pages between model loads —
> run gemma3 in isolation (fresh terminal or after `echo 3 > /proc/sys/vm/drop_caches`) to avoid OOM.

| Model | Quant | Size | Gen tok/s | Prefill tok/s | vs IPEX-LLM gen | vs IPEX-LLM prefill |
|---|---|---|---|---|---|---|
| phi4-mini | Q4\_K\_M | 2.31 GiB | **33.97** | **819** | — ² | — ² |
| gemma4-e4b | Q4\_K\_M | 4.62 GiB | **26.73** | **617** | — ² | — ² |
| deepseek-r1-distill-qwen-7b | Q4\_K\_M | 4.36 GiB | **20.93** | **525** | — ² | — ² |
| qwen2.5-coder-7b | Q4\_K\_M | 4.36 GiB | **19.42** | **479** | ≈ (−3%) | −41% ⁴ |
| llama3.1-8b-instruct | Q4\_K\_M | 4.58 GiB | **18.87** | **358** | ≈ (−0%) | −17% ¹ |
| qwen3-8b | Q4\_K\_M | 4.86 GiB | **15.25** | **323** | −16% | −38% ¹ |
| gemma4-12b | Q4\_K\_M | 7.12 GiB | **11.34** | **273** | +8% ⁵ | +14% ⁵ |
| ornith-1.0-9b | Q6\_K | 6.84 GiB | **10.20** | **330** | — ² | — ² |
| qwen3-14b *(optional)* | Q4\_K\_M | 8.38 GiB | **10.09** | **225** | — ² | — ² |
| qwen2.5-coder-14b | Q4\_K\_M | 8.37 GiB | **9.92** | **227** | — ³ | — ³ |
| ~~gemma3-12b~~ *(replaced)* | Q4\_K\_M | 6.79 GiB | ~~7.84~~ | ~~211~~ | — | — |

> ¹ IPEX-LLM had Flash Attention enabled, which mainly accelerates prefill (O(n²) → O(n) attention).
> Generation speed is a fairer comparison — llama3.1 is virtually identical (18.87 vs 18.9 tok/s).
> FA on Arc 140V with llama.cpp SYCL was validated across 4 models — see the FA validation table below.
>
> ² No IPEX-LLM baseline for this model.
>
> ³ IPEX-LLM baseline used qwen2.5-coder **7B**; the table above benchmarks the **14B** variant — not directly comparable.
>
> ⁴ IPEX-LLM baseline for qwen2.5-coder:7b: 20.0 tok/s gen, 814 tok/s prefill (FA on). llama.cpp without FA: 19.42 gen (≈), 479 prefill (−41%).
> With FA on: 19.97 gen (+3%), 329 prefill (−59% vs IPEX-LLM) — FA regresses prefill on Arc 140V.
>
> ⁵ Gemma-4-12B replaces Gemma-3-12B (IPEX-LLM baseline: 10.5 tok/s gen, 240 tok/s prefill). Gemma-4 is +8% faster on generation and +14% on prefill despite running without Flash Attention.

#### Flash Attention validation on Arc 140V ✅

`-fa on` tested on 4 models. **Result: FA is counterproductive on Xe2 with the current SYCL backend — do not use.**

| Model | Prefill (FA off) | Prefill (FA on) | Δ prefill | Gen (FA off) | Gen (FA on) | Δ gen |
|---|---|---|---|---|---|---|
| qwen2.5-coder-7b | 479 | 329 | −31% | 19.42 | 19.97 | +3% |
| qwen3-8b | 323 | 228 | −29% | 15.25 | 17.73 | +16% |
| llama3.1-8b | 358 | 375 | **+5%** | 18.87 | 19.32 | +2% |
| qwen3-14b | 225 | 174 | −23% | 10.09 | **6.08** | **−40%** ⚠️ |

Llama 3.1 is the only model with a positive prefill delta (+5%), but the gain is too small (17 tok/s) to justify FA across the board.

Qwen3-14B generation collapses from 10.09 to 6.08 tok/s with FA on. This is likely memory pressure: the model uses 8.38 GiB plus FA intermediate buffers, pushing against the available GPU pool and causing the xe driver to spill.

The prefill gap vs IPEX-LLM (e.g. qwen3-8b: 323 vs 522 tok/s) is an open gap. IPEX-LLM shipped Intel-patched Xe-specific FA kernels that were never upstreamed into llama.cpp — there is no equivalent in the current SYCL backend.

**Baseline reference — IPEX-LLM (Q4\_K\_M, Arc 140V, CTX=8192, Flash Attention on):**

| Model | Gen tok/s | Prefill tok/s | TTFT ms |
|---|---|---|---|
| qwen2.5-coder:7b | 20.0 | 814 | 56 ms |
| qwen3:8b | 18.1 | 522 | 62 ms |
| llama3.1:8b-instruct | 18.9 | 429 | 56 ms |
| gemma3:12b | 10.5 | 240 | 100 ms |
| qwen2.5:14b-instruct | 10.7 | 451 | 100 ms |

### 8.4 Speculative decoding ✅ (validated — not viable on this hardware)

Speculative decoding uses a small "draft" model to generate candidate tokens, which a larger "target" model verifies in a single forward pass. When the draft's predictions are correct, multiple tokens are confirmed at once — multiplying generation throughput without changing output quality.

Two draft mechanisms exist in principle; only one is usable with llama.cpp upstream:

- **Separate draft model** ✅ — a full smaller model of the same architecture family (same tokenizer required). Supported via `--spec-draft-model` + `--spec-type draft-simple` (see root cause below).
- **MTP head** ❌ — a tiny secondary prediction head trained as part of the target model. The Gemma-4 MTP heads from bartowski/unsloth use `Gemma4Assistant` architecture and require `ctx_other` (the main model's internal context) — they **cannot be loaded as an independent draft model** in llama.cpp upstream (build 9843). The server silently ignores them and falls back to no speculative decoding.

#### Root cause of every early "0/0 accepted" result: missing `--spec-type`

`--spec-draft-model` alone does **not** activate speculative decoding. llama.cpp build 9843 requires an explicit `--spec-type draft-simple` flag to register the implementation (`common/speculative.cpp:2145-2345`, `common/arg.cpp:3769`). Without it, the internal `impls` list stays empty and the server silently logs:

```
no implementations specified for speculative decoding
```

`/props` then reports `"speculative.types": "none"` with no error to the client — indistinguishable from a real incompatibility unless you check the server log at `-lv 5`. This masked the true cause of the DeepSeek-R1 and Gemma-4 MTP failures below for most of the investigation; the vocab-mismatch and `ctx_other` issues are real, but `--spec-type` was *also* missing in every one of those tests.

#### Draft availability — current lineup (final status)

| Target | Draft | Type | Draft size | Combined VRAM | Status |
|---|---|---|---|---|---|
| Gemma-4-12B (7.12 GiB) | `mtp-gemma-4-12B-it-Q4_0` | MTP head | 0.32 GiB | 7.44 GiB | ❌ arch incompatible (`ctx_other`) |
| Gemma-4-E4B (4.62 GiB) | `mtp-gemma-4-E4B-it` | MTP head | 0.10 GiB | 4.72 GiB | ❌ arch incompatible (`ctx_other`) |
| DeepSeek-R1-7B (4.36 GiB) | DeepSeek-R1-Distill-Qwen-1.5B | Separate model | 1.1 GiB | 5.46 GiB | ❌ vocab mismatch (152064 ≠ 151936) |
| Gemma-4-12B (7.12 GiB) | Gemma-4-E2B-it Q4_K_M | Separate model | 3.1 GiB | ~10.8 GiB | ⚠️ activates, net regression (see below) |
| Qwen3-14B (8.38 GiB) | Qwen3-8B | Separate model | 4.86 GiB | 13.24 GiB | ⚠️ activates, net regression (see below) |

Models without a draft option: Phi-4-mini (too small, not needed), Llama-3.1-8B (no compatible small Llama 3.1), Ornith-1.0-9B (unique architecture, no public draft).

> **Gemma-4 MTP heads** (`Gemma4Assistant` architecture): require `ctx_other` — the main model's internal context — and cannot be loaded as independent draft models via `--spec-draft-model`. Waiting for native MTP support upstream.
>
> **DeepSeek-R1 vocab mismatch**: the bartowski 1.5B (`n_vocab = 151936`) and 7B (`n_vocab = 152064`) have different vocabulary sizes — 128 extra tokens in the 7B. llama.cpp requires identical vocabularies for speculative decoding. The 1.5B is tokenizer-compatible with the Qwen3 models (both 151936) but not with the DeepSeek-R1 7B bartowski quant.
>
> **Gemma-4-E2B + Gemma-4-12B**: vocabulary confirmed identical (`n_vocab = 262144` in both — same Gemma-4 tokenizer family, verified via `config.json` and GGUF `tokenizer.ggml.tokens` count). With the correct `--spec-type draft-simple` flag the draft activates and tokens are accepted, but net throughput is *worse* than baseline (see benchmark results below).
>
> **Qwen3-14B + Qwen3-8B**: vocabulary confirmed identical (`n_vocab = 151936` in both). Highest acceptance rate observed (64%), but still a net regression — same conclusion as Gemma.

#### Benchmark results — speculative decoding vs baseline

| Pair | `--spec-draft-n-max` | Gen avg | Baseline (§8.3, no spec) | Δ | Acceptance |
|---|---|---|---|---|---|
| Gemma-4-E2B → Gemma-4-12B | 16 | 2.25 tok/s | 11.34 tok/s | **−80%** | 15% (collapsing 33%→9% across runs) |
| Gemma-4-E2B → Gemma-4-12B | 4 | 6.18 tok/s | 11.34 tok/s | **−45%** | 28% (stable) |
| Qwen3-8B → Qwen3-14B | 4 | 6.21 tok/s | 10.09 tok/s | **−38%** | 64% (stable) |

**Verdict: speculative decoding is not viable on Arc 140V for any tested pair, regardless of vocab compatibility or acceptance rate.** Even the best case (Qwen3, 64% acceptance) is a 38% regression. Lowering `--spec-draft-n-max` from 16→4 substantially reduces the loss (less wasted verify compute on rejected batches) but never closes the gap. The bottleneck is structural, not a tuning problem: Lunar Lake's Arc 140V shares LPDDR5x memory bandwidth between CPU and GPU, and running two model forward passes per step (draft generation + target verification) competes for the same constrained bandwidth that already limits single-model generation. There is no idle compute headroom to hide the draft's cost behind, unlike discrete GPUs with separate VRAM bandwidth where speculative decoding typically wins.

This closes §8.4. The commands below are kept for future reference — revisit if this machine is replaced with a discrete-GPU setup or a future Xe driver/iGPU generation changes the memory-bandwidth-sharing behavior.

#### Verifying vocabulary compatibility before attempting speculative decoding

```bash
# Check n_vocab of two models — they must match exactly
source /opt/intel/oneapi/setvars.sh --force
for f in models/target.gguf models/draft.gguf; do
  echo -n "$f: "
  ./build/bin/llama-server -m "$f" --vocab-only 2>&1 | grep "n_vocab" | head -1
done
```

Or directly from the GGUF metadata without loading:

```bash
python3 -c "
import struct, sys
def gguf_vocab(path):
    with open(path, 'rb') as f:
        f.read(4)  # magic
        f.read(4)  # version
        n_tensors = struct.unpack('<Q', f.read(8))[0]
        n_kv = struct.unpack('<Q', f.read(8))[0]
    print(f'{path}: n_tensors={n_tensors}, n_kv={n_kv}')
for p in sys.argv[1:]: gguf_vocab(p)
" models/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf models/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf
```

#### Downloading the missing draft models

```bash
# Gemma-4-12B MTP head (bartowski — in same repo as the main model)
hf download bartowski/gemma-4-12b-it-GGUF \
  mtp-gemma-4-12B-it-Q4_0.gguf \
  --local-dir ~/llm/llama-cpp-arc/models/

# Gemma-4-E4B MTP head (unsloth)
hf download unsloth/gemma-4-e4b-it-GGUF \
  mtp-gemma-4-E4B-it.gguf \
  --local-dir ~/llm/llama-cpp-arc/models/

# DeepSeek-R1-Distill-Qwen-1.5B (bartowski)
hf download bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF \
  DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf \
  --local-dir ~/llm/llama-cpp-arc/models/

# Gemma-4-E2B (unsloth) — vocab-compatible draft for Gemma-4-12B
hf download unsloth/gemma-4-e2b-it-GGUF \
  gemma-4-E2B-it-Q4_K_M.gguf \
  --local-dir ~/llm/llama-cpp-arc/models/
```

#### Starting the server with speculative decoding

> **Flag changes (llama.cpp ≥ build 9800):**
> - `--draft-model` and `--draft-max` have been removed. Use `--spec-draft-model` and `--spec-draft-n-max` instead.
> - `--spec-draft-model` alone does **not** activate speculative decoding — you must also pass `--spec-type draft-simple` to register the implementation, or the server silently falls back to `speculative.types: none` with no error (see root cause above). This was the actual reason every pair below showed `0/0 accepted` before this flag was found.

```bash
cd ~/llm/llama-cpp-arc/llama.cpp

# Gemma-4-12B + MTP head — NOT VIABLE: Gemma4Assistant requires ctx_other,
# cannot be loaded as an independent --spec-draft-model. Kept for reference
# only; will fail to load regardless of --spec-type.
./build/bin/llama-server \
  -m ../models/gemma-4-12B-it-Q4_K_M.gguf \
  --spec-type draft-simple \
  --spec-draft-model ../models/mtp-gemma-4-12B-it-Q4_0.gguf \
  --spec-draft-n-max 8 \
  --spec-draft-ngl 999 \
  -ngl 999 --port 8080

# Gemma-4-E4B + MTP head — same ctx_other incompatibility as above
./build/bin/llama-server \
  -m ../models/gemma-4-E4B-it-Q4_K_M.gguf \
  --spec-type draft-simple \
  --spec-draft-model ../models/mtp-gemma-4-E4B-it.gguf \
  --spec-draft-n-max 8 \
  --spec-draft-ngl 999 \
  -ngl 999 --port 8080

# DeepSeek-R1-7B + 1.5B draft — NOT VIABLE: vocab mismatch (152064 ≠ 151936)
./build/bin/llama-server \
  -m ../models/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf \
  --spec-type draft-simple \
  --spec-draft-model ../models/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf \
  --spec-draft-n-max 8 \
  --spec-draft-ngl 999 \
  -ngl 999 --port 8080

# Gemma-4-12B + Gemma-4-E2B draft — ACTIVATES, net regression on this hardware
# (see §8.4 benchmark table). --parallel 1 required: with the default 4 slots
# kv_unified=true and the draft is silently ignored.
./build/bin/llama-server \
  -m ../models/gemma-4-12B-it-Q4_K_M.gguf \
  --spec-type draft-simple \
  --spec-draft-model ../models/gemma-4-E2B-it-Q4_K_M.gguf \
  --spec-draft-n-max 4 \
  --spec-draft-ngl 999 \
  -ngl 999 --parallel 1 --port 8080

# Qwen3-14B + Qwen3-8B draft — ACTIVATES, net regression on this hardware
# (see §8.4 benchmark table). Combined 13.24 GiB — requires fresh GPU pool.
./build/bin/llama-server \
  -m ../models/Qwen3-14B-Q4_K_M.gguf \
  --spec-type draft-simple \
  --spec-draft-model ../models/Qwen3-8B-Q4_K_M.gguf \
  --spec-draft-n-max 4 \
  --spec-draft-ngl 999 \
  -ngl 999 --parallel 1 --port 8080
```

| Parameter | Description |
|---|---|
| `--spec-type draft-simple` | **Required** to activate a separate-model draft. Without it, `--spec-draft-model` is loaded into VRAM but never used (see root cause above) |
| `--spec-draft-model` | Path to draft model (replaces removed `--draft-model`) |
| `--spec-draft-n-max` | Max speculative tokens per step — default 3. On Arc 140V, 4 minimizes wasted verify compute versus higher values like 8–16 (§8.4 benchmark table) |
| `--spec-draft-ngl` | GPU layers for the draft model — set to 999 to keep draft on GPU |
| `--parallel 1` | Required for speculative decoding to activate at all — with the server default of 4 slots, `kv_unified=true` and the draft is silently ignored |

#### Benchmarking speculative decoding vs baseline

`llama-bench` does not support draft models — benchmarking must go through `llama-server`.
Start the server with `--spec-type draft-simple` + `--spec-draft-model` (see commands above),
then use `bench-spec.sh` to drive the `/completion` endpoint and average `timings.predicted_per_second`
across multiple runs:

```bash
# 1. Start the server (in a separate terminal) — example: Qwen3 pair
cd ~/llm/llama-cpp-arc/llama.cpp
source /opt/intel/oneapi/setvars.sh --force
export GGML_SYCL_DEVICE=0 SYCL_CACHE_PERSISTENT=0 ZES_ENABLE_SYSMAN=1

./build/bin/llama-server \
  -m ../models/Qwen3-14B-Q4_K_M.gguf \
  --spec-type draft-simple \
  --spec-draft-model ../models/Qwen3-8B-Q4_K_M.gguf \
  --spec-draft-n-max 4 \
  --spec-draft-ngl 999 \
  -ngl 999 --parallel 1 --port 8080

# 2. Measure gen tok/s (in another terminal) — averages 3 runs by default
cd ~/llm/llama-cpp-arc
./bench-spec.sh -n 3
```

Compare `Avg gen` against the §8.3 llama-bench baseline (`tg128`) for the target model.
`Acceptance` (`draft_n_accepted / draft_n`) is the fraction of drafted tokens confirmed —
higher means more potential speedup, but as shown in the §8.4 results table, a high acceptance
rate does **not** guarantee a net win if the draft model's own compute cost outweighs the
tokens it saves.

> **Diagnosing `0/0 accepted`:** if `bench-spec.sh` reports `accepted: 0/0` with the flags above, check the server log (start with `-lv 5`) for `adding speculative implementation 'draft-simple'` and `speculative decoding context initialized`. If instead you see `no implementations specified for speculative decoding`, verify: `--spec-type draft-simple` is present, `--parallel 1` is set (not the default 4 slots), and both models report identical `n_vocab` (§8.4 vocab verification snippet above).

---

## 9. Integration with external tools ⚠️

The llama-server endpoint is compatible with the OpenAI spec. The difference from the IPEX-LLM stack is the port (`8080` instead of `11434`) and the absence of a model registry — the model is specified when starting the server, not when calling the API.

### 9.1 Connection details

| Parameter | Value |
|---|---|
| OpenAI-compatible endpoint | `http://localhost:8080/v1` |
| Native llama.cpp endpoint | `http://localhost:8080` |
| API Key | any non-empty value (e.g. `llama`) |
| Available models | the model active when the server was started |

### 9.2 VS Code — extensions

#### Twinny — inline autocomplete + chat

| Setting | Value |
|---|---|
| API hostname | `localhost` |
| API port | `8080` |
| Fill-in-middle model | `phi4-mini` (or the name shown in `/v1/models`) |
| Chat model | `qwen3:8b` |
| API provider | `llamacpp` or `OpenAI Compatible` |

> ⚠️ Verify what `model` value Twinny accepts when the backend is llama-server (the field may require the GGUF filename or any string depending on the version).

#### Cline / Roo Code — coding agent

| Setting | Value |
|---|---|
| API Provider | `OpenAI Compatible` |
| Base URL | `http://localhost:8080/v1` |
| API Key | `llama` |
| Model | (name returned by `/v1/models`) |

#### CodeGPT — simple chat

| Setting | Value |
|---|---|
| LLM Provider | `Custom` / `OpenAI Compatible` |
| API URL | `http://localhost:8080/v1` |
| Model | (name of the active model) |

### 9.3 OpenAI-compatible API (Python scripts)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8080/v1",
    api_key="llama",  # Required by the client but ignored by llama-server
)

response = client.chat.completions.create(
    model="local",
    messages=[
        {"role": "system", "content": "You are a helpful assistant. Reply only in JSON."},
        {"role": "user", "content": "Extract vendor and total from: Invoice from Acme Corp, total $1,234.56"},
    ],
    temperature=0.1,
)
print(response.choices[0].message.content)
```

---

## 10. Systemd service (autostart) ⚠️

```bash
sudo tee /etc/systemd/system/llama-server.service > /dev/null <<'EOF'
[Unit]
Description=llama-server SYCL (Intel Arc 140V)
After=multi-user.target
Wants=network-online.target

[Service]
Type=simple
User=YOUR_USER
WorkingDirectory=/home/YOUR_USER/llm/llama-cpp-arc

# Activate oneAPI before starting the server
ExecStartPre=/bin/bash -c 'source /opt/intel/oneapi/setvars.sh --force'
ExecStart=/home/YOUR_USER/llm/llama-cpp-arc/start-server.sh

Environment=GGML_SYCL_DEVICE=0
Environment=SYCL_CACHE_PERSISTENT=1
Environment=ZES_ENABLE_SYSMAN=1

Restart=on-failure
RestartSec=10s
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

# Replace YOUR_USER with your username
sudo sed -i "s/YOUR_USER/$USER/g" /etc/systemd/system/llama-server.service

# Enable
sudo systemctl daemon-reload
sudo systemctl enable --now llama-server.service

# Status
sudo systemctl status llama-server.service
```

> ⚠️ **`source` in ExecStartPre:** systemd does not propagate environment variables between directives. It may be necessary to inline the content of `setvars.sh` into the service or use `EnvironmentFile`. The correct way to activate oneAPI in a service unit is pending validation.

---

## 11. OS tuning for performance ✅

Two configuration files that improve inference stability and performance. Independent of the server — persist across reboots. Identical to those in the previous IPEX-LLM stack.

### sysctl (`/etc/sysctl.d/99-llm-performance.conf`)

```bash
sudo tee /etc/sysctl.d/99-llm-performance.conf > /dev/null <<'EOF'
# Memory
vm.swappiness = 10               # Avoid swap with 30 GB of available RAM
vm.dirty_background_ratio = 5    # Flush writes at 5%
vm.dirty_ratio = 15
vm.vfs_cache_pressure = 50       # Retain inode/dentry cache — faster model loads
vm.min_free_kbytes = 524288      # Reserve 512 MB free

# Network (API at localhost:8080)
net.ipv4.tcp_fastopen = 3        # Reduce latency on localhost TCP connections
EOF

# Apply without reboot
sudo sysctl -p /etc/sysctl.d/99-llm-performance.conf
```

### CPU governor + HWP dynamic boost

```bash
sudo tee /etc/systemd/system/cpu-performance.service > /dev/null <<'EOF'
[Unit]
Description=CPU performance governor and HWP dynamic boost
After=multi-user.target
Before=llama-server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$f"; done'
ExecStart=-/bin/sh -c 'echo 1 > /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost'

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload && sudo systemctl enable --now cpu-performance.service
```

> **`Before=llama-server.service`:** the governor must be active before the server starts compiling SYCL kernels on first boot.

Verification:

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor  # performance
cat /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost  # 1
cat /proc/sys/vm/swappiness                                 # 10
```

---

## 12. Troubleshooting

### `sycl-ls` does not show the Arc 140V

```bash
# Verify Level Zero detects the GPU
clinfo -l
# If "Intel Arc" does not appear → Level Zero host-side problem (see §3)

# Verify user groups
groups $USER
# Must include: render video

# If groups are not active after being added:
newgrp render  # Activate in current session without logging out
```

### Build error: `icx: command not found`

```bash
# oneAPI is not activated in the current session
source /opt/intel/oneapi/setvars.sh
icx --version
```

### Server does not detect GPU (inference falls back to CPU)

```bash
# Verify the server sees the GPU at startup
./build/bin/llama-server --list-devices
# If "Intel Arc" is not shown → SYCL is not configured correctly

# Verify sycl-ls works before starting the server
source /opt/intel/oneapi/setvars.sh
sycl-ls

# During active inference, verify GPU utilization:
sudo xpu-smi dump -d 0 -m 0,5,18 -i 1
# GPU util (column 0) should be > 80% during generation
# If GPU util ~0% → inference is running on CPU
```

### SYCL runtime error: "No device of requested type available"

```bash
# Most likely cause: Level Zero does not detect the GPU correctly
# or GGML_SYCL_DEVICE points to a wrong index

# List available devices
source /opt/intel/oneapi/setvars.sh && sycl-ls

# Try with GGML_SYCL_DEVICE=0 (first GPU)
GGML_SYCL_DEVICE=0 ./build/bin/llama-server --list-devices
```

### First inference takes 2–5 minutes

Normal behavior. The SYCL runtime compiles kernels for the Arc 140V Xe2 on first use. Compilations are cached in `~/.cache/sycl/` (with `SYCL_CACHE_PERSISTENT=1` active). Subsequent loads are nearly instantaneous.

### RAM is not recovered after stopping the server

```bash
# Check memory before releasing
xpu-smi dump -d 0 -m 5 -i 1 -n 1

# Release GPU pool without reboot (stop server first)
sudo sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo swapoff -a && sudo swapon -a

# Verify result
free -h
```

> The `xe` driver retains pages in the GPU pool even when the server is stopped. `drop_caches` forces page cache release. A reboot remains the cleanest option but is not required.

### OOM — model fails to load

```bash
# Check available memory
free -h

# If MemAvailable < model size → release memory (see above)
# or use a smaller model / more aggressive quantization (IQ4_XS instead of Q4_K_M)
```

---

## Quick Reference

```bash
# Activate oneAPI environment (required before building or starting)
source /opt/intel/oneapi/setvars.sh

# Verify GPU
sycl-ls
clinfo -l

# Start server (default model)
./start-server.sh

# Start with specific model
./start-server.sh models/Qwen3-8B-Q4_K_M.gguf

# Verify server responds
curl http://localhost:8080/health

# Quick inference test
curl -s http://localhost:8080/completion \
  -d '{"prompt":"Hello","n_predict":16,"stream":false}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); \
    t=d['timings']; print(f\"{t['predicted_per_second']:.1f} tok/s\")"

# GPU monitoring during inference
sudo xpu-smi dump -d 0 -m 0,5,18 -i 1

# Benchmark
./build/bin/llama-bench -m models/<model>.gguf -n 128 -ngl 999

# Rebuild llama.cpp (after pulling new versions)
source /opt/intel/oneapi/setvars.sh
cmake --build build --config Release -j$(nproc) \
  --target llama-server llama-bench llama-cli
```
