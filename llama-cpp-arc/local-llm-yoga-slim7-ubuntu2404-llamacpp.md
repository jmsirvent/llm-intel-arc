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
   - [8.5 Quality regression / candidate testing](#85-quality-regression--candidate-testing-with-quality-testsh)
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
  --ctx-size 32768 \
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
| `--ctx-size` | 32768 | Default context — raised from 8192 after agentic clients (OpenCode) exceeded it with tool-schema + system-prompt overhead; watch RAM on 14B models |
| `--parallel` | 1 | Explicit single-user — avoids reserving buffers for parallel requests |
| `--port` | 8080 | API port for this server |
| `--host` | 0.0.0.0 | Listen on all interfaces |
| `--skip-chat-parsing` | (add when needed) | Forces everything (including chain-of-thought) into `message.content` instead of splitting it into `message.reasoning_content`. Needed with reasoning models (Ornith, Qwen3, DeepSeek-R1) when the client doesn't read `reasoning_content` — see §9.2. |

### 6.3 First model load

Every startup compiles SYCL kernels JIT for the Arc 140V Xe2 — this takes **2–5 minutes** and is normal. The persistent kernel cache (`SYCL_CACHE_PERSISTENT=1`) is disabled due to a bug in oneAPI 2026.0 (`libsycl.so.9`) that causes a SIGSEGV in `PersistentDeviceCodeCache::getItemFromDisc`. Re-enable it once Intel ships a fix.

> **Cache directories** (if re-enabling after a fix): `~/.cache/libsycl_cache/` and `~/.cache/neo_compiler_cache/` — these are the actual locations used by oneAPI 2026.0, not `~/.cache/sycl/`. Clear both if switching between oneAPI versions or after a kernel driver update.

### 6.4 Startup script

`~/llm/llama-cpp-arc/start-server.sh` is an interactive launcher, not a fixed one-model script — no need to have read §7.1 or §8.3 first, they're just where the model lineup and `benchmark.sh` (which shares this same catalog) are covered in more depth. With no arguments, it shows a menu listing every model in the catalog: available ones (✓, ready to start) and not-yet-downloaded ones (✗, with a ready-to-run `hf download` command and an interactive download prompt). Selecting an available model starts `llama-server` with the baseline params from §6.2 (`--n-gpu-layers 999 --ctx-size 8192 --parallel 1 --port 8080`).

```bash
chmod +x ~/llm/llama-cpp-arc/start-server.sh

# Usage
./start-server.sh                             # interactive menu
./start-server.sh Qwen3-8B-Q4_K_M.gguf        # start a specific GGUF by filename
./start-server.sh Gemma                       # match by display-name substring
./start-server.sh models/Qwen3-8B-Q4_K_M.gguf # explicit path (back-compat)
```

See the script itself for the full implementation — the catalog, download-prompt, and menu logic mirror `benchmark.sh` (§8.3) exactly, so both scripts should be updated together when the model lineup changes.

> **`OCL_ICD_FILENAMES: variable sin asignar` on startup:** Intel's `setvars.sh` references unset variables internally; under this script's `set -euo pipefail`, that aborts the whole script before `llama-server` ever starts (symptom: nothing listens on `:8080`, and any OpenAI-compatible client — e.g. Twinny — just hangs waiting for a connection). Fixed by bracketing the `source` call with `set +u` / `set -u`, since `set -u` errors are fatal even inside a `||` guard (unlike `set -e`, they are not suppressed by `&&`/`||` context). Same fix applied in `benchmark.sh`.

> **`missing_names: variable sin asignar` in the menu:** happens when every catalog model is already downloaded (the "Not downloaded" list stays empty). Under `set -u`, `local -a arr` alone does **not** count as "set" for `${#arr[@]}` — only an explicit `arr=()` assignment does; an untouched local array reference aborts the script. Fixed by declaring every local array with `=()` (`local -a missing_names=() ...`). Same fix applied in `benchmark.sh`.

---

## 7. Recommended models ✅

### Memory budget

- Total RAM: 32 GB
- OS + desktop + apps in use: ~11–12 GB in typical daily use

There is no fixed "available for models" figure — free memory on this unified-memory system varies with OS load and, more importantly, with the `xe` driver's GPU pool retention behavior (next note). Observed free memory has ranged from ~7 GB (GPU pool populated by a prior session, driver not reclaiming pages) up to ~19–20 GB (clean reboot, no prior GPU allocations). Treat any single number in this document as a snapshot, not a ceiling — always check current availability before loading a large model (`free -h`, `xpu-smi stats -d 0`).

> With 32 GB of unified RAM it is not possible to separate "GPU VRAM" from the rest of RAM. The Arc 140V accesses the same LPDDR5X pool as the CPU.

> ⚠️ **xe driver behavior:** once the xe driver assigns RAM pages to the GPU pool (on first model load), it does not return them to the system even if the model is unloaded. Memory is only fully recovered with a reboot or `echo 3 > /proc/sys/vm/drop_caches` after stopping the server.

> **GPU pool allocation causes real (if minor) swap activity, not a `vm.swappiness` misconfiguration:** loading a model triggers brief swap-out bursts (observed: ~130 MB across two bursts while loading Qwen3-8B) as the kernel reclaims RSS from page cache/applications to satisfy the unified-memory allocation for the GPU. `swappiness = 10` (§11) reduces the tendency to swap but does not prevent it under genuine memory pressure — this is expected, not a bug. To tell transient allocation swap from real memory pressure, check `vmstat`'s `si`/`so` columns for active in/out traffic rather than the total swap-used figure from `free -h`, which persists from past peaks until something touches those pages again (or until `echo 3 > /proc/sys/vm/drop_caches`, which also lets the kernel swap idle pages back in once memory is freed).

> ⚠️ **Never load two models concurrently — it can hang the `xe` driver, not just OOM.** Running `llama-bench` on a ~16 GB model while a separate `llama-server` process still held an earlier model resident (with `disponible` already down to ~16 GB, short of a clean ~20 GB boot) froze the entire system, requiring a hard reboot. `journalctl -b -1` showed no clean OOM-kill — instead a kernel hung-task warning: a thread blocked 614+ seconds on `xe_validation_lock`, held by `llama-bench` itself inside `xe_gem_create_ioctl` → `ttm_pool_alloc`, i.e. mid-allocation of a GPU buffer under memory pressure. This is a driver-level stability bug in `xe`'s TTM/validation path, not a graceful failure. **Always stop any resident `llama-server`/`llama-bench` process and confirm `free -h` shows recovered memory (`echo 3 > /proc/sys/vm/drop_caches` if needed) before starting another model load** — never run two model-loading processes at once on this hardware.

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
| Gemma-4-12B-IT | UD-Q4\_K\_XL | 7.4 GB | 6.85 GiB | Vision + audio multimodal reasoning | Long-document analysis / summarization, leveraging the 256K context window | unsloth/gemma-4-12b-it-GGUF | **11.95** |
| Ornith-1.0-9B | Q6\_K | 7.4 GB | 6.84 GiB | Agentic coding / tool-calling | Terminal/devops automation — trained on Terminal-Bench, not just SWE-Bench | deepreinforce-ai/Ornith-1.0-9B-GGUF | **10.20** |
| Qwen3-14B *(optional)* | Q4\_K\_M | 9.0 GB | 8.38 GiB | Deep reasoning | Knowledge-intensive Q&A benefiting from the larger parameter count vs Qwen3-8B | unsloth | **10.09** |
| Qwen2.5-Coder-14B-Instruct | Q4\_K\_M | 9.0 GB | 8.37 GiB | Agentic coding (Cline) | Code review / explaining unfamiliar code — larger model gives more reliable explanations than the 7B | bartowski | **9.92** |

> RAM column: memory allocated by llama.cpp SYCL during `llama-bench` (`-p 512 -n 128 -ngl 999`).
> Full benchmark results and IPEX-LLM comparison: §8.3.
> Qwen3-14B: same speed as the 14B coders but double the RAM of Qwen3-8B — only worth it when reasoning depth matters more than throughput. Speculative decoding with Qwen3-8B as draft was tested and found not viable on this hardware (§8.4) — despite 64% acceptance, net throughput regresses 38%.
> Gemma-4-12B: replaces Gemma-3-12B (+52% gen speed: 11.95 vs 7.84 tok/s), adds 256K context, audio/video, configurable thinking mode. Repo: `unsloth/gemma-4-12b-it-GGUF`, quant `UD-Q4_K_XL` (Unsloth Dynamic 2.0 — per-layer precision allocation, not the uniform K-quant scheme). Swapped in 2026-07-20, replacing `bartowski/gemma-4-12b-it-GGUF` `Q4_K_M`: a 5-prompt quality battery (code gen, bug-fix, reasoning, strict JSON, race-condition explanation) at `temperature 0` with thinking disabled (`chat_template_kwargs: {"enable_thinking": false}`) found Unsloth equal-or-better on every prompt, with one objective win — bartowski's bug-fix answer returned a string (`"Error: ..."`) on the zero-divisor path instead of keeping the function's list return type consistent, Unsloth returned `[]`. Same size class (6.85 vs 7.12 GiB) and no throughput regression (see §8.3) — a low-risk swap, not a dramatic one. The `mtp-gemma-4-12B-it-Q4_0.gguf` MTP head is not usable as a draft model in llama.cpp upstream (`ctx_other` requirement, §8.4) — no download needed for speculative decoding purposes.
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

### 7.3 Evaluated and rejected models

**Bonsai 27B (PrismML), `Q1_0` 1-bit variant — rejected 2026-07-20.** Bonsai 27B compresses
Qwen3.6-27B to 1-bit/ternary weights. Only the 1-bit GGUF (`prism-ml/Bonsai-27B-gguf`,
`Bonsai-27B-Q1_0.gguf`, 3.8 GB) has upstream SYCL support — merged via
[llama.cpp#24721](https://github.com/ggml-org/llama.cpp/pull/24721) (2026-06-18,
`MUL_MAT`/`OUT_PROD` for `Q1_0`), no fork or rebuild required. Loads cleanly on Arc 140V
(no CPU-fallback warnings), but benchmarked with the project baseline
(`-p 512 -n 128 -ngl 999`) at **4.36 tok/s generation** (pp512: 70.51 tok/s) — worse than
every model in the §7.1 table above, including ones 2.5x its 3.53 GiB disk size. Not viable.

Root cause: PR #24721 only implements generic `MUL_MAT`/`OUT_PROD` for `Q1_0` —
correctness, not the decode-optimized kernels (`mmvq`-style) that every model in this
guide's catalog benefits from via `Q4_K_M`. The pp512/tg128 split (mediocre prefill, very
poor decode) is the fingerprint of that gap: decode is memory-bound and overhead-sensitive,
exactly where a generic kernel loses the most. The parallel Vulkan PR for the ternary type
([#25850](https://github.com/ggml-org/llama.cpp/pull/25850)) explicitly defers its
integer-dot/MMQ decode path to a follow-up — SYCL has not even started that work.

The **ternary** Bonsai variant (`Q2_0`/`TQ2_0`, 5.9 GB, higher quality than 1-bit) was not
tested — it has no SYCL kernel at all upstream. A prior attempt
([#22910](https://github.com/ggml-org/llama.cpp/pull/22910)) was closed without merging.

**Revisit if:** upstream lands a dedicated SYCL decode kernel for `Q1_0`, or any SYCL
kernel for `Q2_0`/`TQ2_0` merges. Watch `ggml-org/llama.cpp` PRs combining `sycl` with
`Q1_0`/`Q2_0`/`TQ1_0`/`TQ2_0`.

**Qwen3.6-27B dense, `Q4_K_M` — rejected 2026-07-20.** No kernel-support risk (standard
`Q4_K_M`, same quant type as every model in §7.1), so this failure is different in kind
from Bonsai's. Benchmarked with the project baseline at **5.22 tok/s generation** (pp512:
72.75 tok/s) — worse than every model in §7.1, roughly half of `qwen3-14b`, despite the
model's 15.65 GiB footprint and reported quality gains (SWE-bench Verified 77.2, ties
Sonnet 4.6 on AA Agentic Index per Qwen's own published numbers).

Root cause: a **memory-ceiling failure, not a backend one**. Loading pushed `disponible`
down to 7-8 GiB and swap usage to 5+ GiB of the 8 GiB configured (confirmed live via
`free -h`/`vmstat`, not inferred). The pp512/tg128 split (mediocre prefill, very poor
decode) matches a swap-bound bottleneck: prefill amortizes page-fault cost across large
batches, decode pays the full cost per token. This is a structural ceiling of this
machine given the ~11-12 GB OS/desktop baseline (see the Memory budget note above), not
specific to this model — expect the same outcome from any dense/MoE-active-weight model
above ~10-12 GB disk size, including the pending `Qwen3-Coder-30B-A3B-Instruct` candidate
(≈18.7 GB). The `qwen3-14b`/`qwen2.5-coder-14b` entries already in §7.1 (9 GB class) are
close to this machine's practical ceiling for dense models, not a conservative floor.

**Revisit if:** available RAM on this machine increases, or a smaller quant is tested with
a confirmed clean ~20 GB `disponible` and the result still shows swap activity below the
Qwen3-8B baseline (~130 MB) rather than multi-GB.

The first load attempt (before this clean result) also surfaced a separate operational
hazard — running a second model-loading process while one was already resident hung the
`xe` driver and required a hard reboot. See the ⚠️ callout under "Memory budget" above.

### 7.4 Downloading models

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

# Download Llama-3.1-8B-Instruct (used as the §6.2 startup example)
hf download bartowski/Meta-Llama-3.1-8B-Instruct-GGUF \
  Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf \
  --local-dir ~/llm/llama-cpp-arc/models
```

The remaining models in the §7.1 lineup follow the same pattern — the "Publisher" column there gives the exact repo id for each.

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

### 8.3 Benchmark with llama-bench ⚠️ (validated — one open TODO below)

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
| gemma4-e2b | Q4\_K\_M | 2.88 GiB | **45.79** | **1083** | — ² | — ² |
| phi4-mini | Q4\_K\_M | 2.31 GiB | **33.97** | **819** | — ² | — ² |
| gemma4-e4b | Q4\_K\_M | 4.62 GiB | **26.73** | **617** | — ² | — ² |
| deepseek-r1-distill-qwen-7b | Q4\_K\_M | 4.36 GiB | **20.93** | **525** | — ² | — ² |
| qwen2.5-coder-7b | Q4\_K\_M | 4.36 GiB | **19.42** | **479** | ≈ (−3%) | −41% ⁴ |
| llama3.1-8b-instruct | Q4\_K\_M | 4.58 GiB | **18.87** | **358** | ≈ (−0%) | −17% ¹ |
| qwen3-8b | Q4\_K\_M | 4.86 GiB | **15.25** | **323** | −16% | −38% ¹ |
| gemma4-12b | UD-Q4\_K\_XL | 6.85 GiB | **11.95** | **284** | +14% ⁵ | +18% ⁵ |
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
> ⁵ Gemma-4-12B replaces Gemma-3-12B (IPEX-LLM baseline: 10.5 tok/s gen, 240 tok/s prefill). Gemma-4 (Unsloth Dynamic `UD-Q4_K_XL`, swapped in 2026-07-20 after a bartowski-vs-Unsloth quality comparison — see §7.1 note) is +14% faster on generation and +18% on prefill despite running without Flash Attention.

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

> **TODO (open, not a permanent limitation):** the prefill gap vs IPEX-LLM (e.g. qwen3-8b: 323 vs 522 tok/s) remains unresolved. IPEX-LLM shipped Intel-patched Xe-specific FA kernels that were never upstreamed into llama.cpp — the current SYCL backend has no equivalent. **Reopen this when:** upstream `llama.cpp` merges improved SYCL FA kernels for Xe2, or a new oneAPI release changes SYCL FA performance characteristics — re-run the §8.3 benchmark table against IPEX-LLM's numbers (`benchmark-reference-ipex-llm` memory) at that point to check whether the gap closed.

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

> Historical note: the commands below reference `gemma-4-12B-it-Q4_K_M.gguf` (bartowski), the file actually used when these speculative-decoding tests ran. That file was superseded by `gemma-4-12b-it-UD-Q4_K_XL.gguf` (Unsloth) on 2026-07-20 (§7.1) and removed from `models/`. The verdict above is unaffected — same architecture, same conclusion would apply — but the exact paths won't resolve if copy-pasted as-is.

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

> These were downloaded only to reproduce the speculative-decoding tests below and have since
> been deleted from `models/` (§8.4's verdict is negative — not part of the active lineup, see
> §7.1). Re-download only if revisiting speculative decoding after a hardware change.

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
then use `~/llm/llama-cpp-arc/bench-spec.sh` — a small script (not `llama-bench`) that sends
repeated prompts to the running server's `/completion` endpoint and averages
`timings.predicted_per_second` and the draft acceptance rate across multiple runs:

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

### 8.5 Quality regression / candidate testing with `quality-test.sh`

`llama-bench` (§8.3) only measures speed — it says nothing about whether a model's actual
answers are correct or well-formed. `quality-test.sh` runs a fixed 5-prompt battery (code
generation, bug-fix, multi-step reasoning, strict JSON, race-condition explanation) against
a running `llama-server` and either saves the outputs as a named baseline or diffs a fresh
run against one. Built for, and validated by, the 2026-07-20 Gemma-4-12B comparison (§7.1)
that caught a real bug: one quant variant's bug-fix answer broke the function's declared
return type on an edge case, something no tok/s number would have surfaced.

```bash
# Save a baseline for the model currently loaded on :8080
./quality-test.sh --save gemma-4-12b-ud-q4_k_xl

# Later — after a llama.cpp rebuild, a re-pulled GGUF, or to compare a new candidate
# against the same model already loaded on :8080:
./quality-test.sh --diff gemma-4-12b-ud-q4_k_xl

# List what's saved
./quality-test.sh --list
```

Not a substitute for §8.3 — run both: `llama-bench` for throughput, `quality-test.sh` for
"did the answers change or break." Two things to know before trusting a `--diff` result:

- **Not a rigorous benchmark.** 5 prompts, no automated pass/fail scoring — you read the
  diffs yourself. Good at catching obvious breaks (empty output, wrong answer, broken
  format, a changed type contract), not a substitute for a real eval suite.
- **Expect ~1/5 prompts to drift even with zero real change.** Confirmed empirically: running
  the battery twice against the *same* model, same server, `temperature 0`, produced a
  wording-level difference in 1 of 5 prompts (SYCL's parallel reduction order isn't
  guaranteed deterministic — ties in logits can flip run to run). Treat a single
  stylistically-different-but-still-correct prompt as noise. Multiple changed prompts, or
  any prompt whose *conclusion* changed (wrong fix, broken format, wrong answer), is the
  real signal.
- **Gemma-4 (and other models with configurable thinking) need `enable_thinking: false`**
  to avoid burning the entire `max_tokens` budget on `reasoning_content` and returning empty
  `content` — the script already sets this via `chat_template_kwargs`, but it's why the
  payload looks the way it does if you're extending the script for a model without this
  quirk.
- **The server-side reasoning flag needed differs by model — using the wrong one silently
  produces empty output, which looks like a regression in `--diff` but isn't.** Confirmed
  while generating baselines for the full catalog (2026-07-20):
  - `--reasoning off` **works** for Qwen3 (`qwen3-8b`, `qwen3-14b`) — the template supports a
    real on/off toggle, content comes back non-empty and complete.
  - `--reasoning off` **does not work** for DeepSeek-R1-Distill-Qwen-7B — the model always
    emits a `<think>` trace regardless of the flag (it's baked in by training, not
    template-controlled); with `--reasoning off` alone it burned the full token budget on
    `reasoning_content` and returned **empty `content`** (confirmed via a raw API check, not
    assumed). Fix: start with `--skip-chat-parsing` instead (dumps everything, including the
    think trace, into `content`) and raise `--max-tokens` well above the default (used 3072).
  - Ornith-1.0-9B has the same always-reasons behavior as DeepSeek-R1-Distill — same fix
    (`--skip-chat-parsing` + higher `--max-tokens`), applied preemptively without needing to
    rediscover the empty-content failure first.
  - Models with no reasoning mode (Phi-4-mini, Gemma-4-E2B/E4B/12B, Llama-3.1-8B,
    Qwen2.5-Coder-7B/14B) need neither flag — started plain.
  **When re-running `--diff` against a saved baseline, start the server with the same
  reasoning-handling flag used when that baseline was saved** (see the per-model list above),
  or a real "no change" will misreport as a regression.

---

## 9. Integration with external tools ✅

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

Twinny 3.x manages providers through its own UI, not `settings.json` — open the command palette and run **"Twinny: Manage Providers"**, then add a provider with these values (verified working):

| Setting | Value |
|---|---|
| Type | `chat` (add a second provider with type `fim` for autocomplete) |
| Provider | `OpenAI Compatible` |
| Protocol | `http` |
| Hostname | `localhost` |
| Port | `8080` |
| Path | `/v1` |
| Model | the exact filename of the GGUF currently loaded by `llama-server` (check `/v1/models`) |

> **One model at a time:** unlike Ollama, `llama-server` only serves the single GGUF it was started with. FIM and Chat providers must point to the *same* model unless you run two `llama-server` instances on two different ports (doubles memory use — see the variable budget in §7). The "Phi-4-mini for FIM / Qwen3-8B for chat" split only works with that two-instance setup.

> **Blank chat responses with reasoning models:** Ornith, Qwen3, and DeepSeek-R1 split their chain-of-thought into `message.reasoning_content`, separate from `message.content` — Twinny only reads `content`, so if the model's reasoning doesn't finish before hitting `max_tokens`, the panel shows nothing. Fix: add `--skip-chat-parsing` to the server params (§6.2) — forces everything, including the reasoning trace, into `content`.

#### Cline — coding agent

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
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=YOUR_USER
WorkingDirectory=/home/YOUR_USER/llm/llama-cpp-arc

# No ExecStartPre / Environment= needed here: start-server.sh sources
# setvars.sh and exports the SYCL variables itself before exec'ing
# llama-server (see §6.4). Duplicating that in the unit would be redundant.
# Explicit model filename required — with no argument, start-server.sh shows
# the interactive menu, which blocks indefinitely without a TTY under systemd.
ExecStart=/home/YOUR_USER/llm/llama-cpp-arc/start-server.sh Qwen3-8B-Q4_K_M.gguf

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

> **oneAPI activation:** no `ExecStartPre` or `Environment=` is needed for SYCL — systemd doesn't propagate environment variables between directives anyway, but that's moot here because `start-server.sh` is self-contained: it sources `setvars.sh` and exports `GGML_SYCL_DEVICE` / `SYCL_CACHE_PERSISTENT` / `ZES_ENABLE_SYSMAN` itself, right before `exec`-ing `llama-server` (§6.4). The unit only needs to invoke the script.
>
> **`After=network-online.target`, not `multi-user.target`:** a unit with `WantedBy=multi-user.target` cannot also declare `After=multi-user.target` — that's an ordering cycle (reaching `multi-user.target` would have to wait for this unit, which itself waits for `multi-user.target`). systemd detects and breaks the cycle, silently dropping the intended ordering. Since the unit already declares `Wants=network-online.target`, `After=` must reference that same target.

---

## 11. OS tuning for performance ✅

Two configuration files that improve inference stability and performance. Independent of the server — persist across reboots. Identical to those in the previous IPEX-LLM stack.

### sysctl (`/etc/sysctl.d/99-llm-performance.conf`)

```bash
sudo tee /etc/sysctl.d/99-llm-performance.conf > /dev/null <<'EOF'
# Memory
vm.swappiness = 10               # Reduce swap tendency (32 GB total, but free RAM varies — see §7)
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

> **`Before=llama-server.service`:** the governor must be active before the server starts compiling SYCL kernels on first boot. No `After=multi-user.target` is needed (or correct) here: paired with `WantedBy=multi-user.target` it would be an ordering cycle (same bug fixed in §10) — `cpufreq` sysfs paths are available from early boot regardless, and the `Before=` relation already guarantees this unit runs ahead of `llama-server.service`.

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

### Every server startup takes 2–5 minutes

Expected with the current workaround, not a one-time cost. `SYCL_CACHE_PERSISTENT` is kept at `0` (§6.1, §6.3) because `=1` triggers a SIGSEGV in `libsycl.so.9` (`intel/llvm#21972`) — with persistence disabled, the SYCL runtime recompiles kernels for the Arc 140V Xe2 JIT on **every** startup, not just the first. There is no working cache to warm up; this stays true until Intel ships a fix and `SYCL_CACHE_PERSISTENT=1` can be re-enabled.

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
