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

The previous stack (`../ipex-llm/`) used IPEX-LLM, an Intel-patched fork of Ollama for SYCL/Level Zero. That project was archived in January 2026. llama.cpp is the actual underlying inference engine — IPEX-LLM wrapped it in Docker to distribute the precompiled Intel toolchain.

This stack compiles llama.cpp directly with the Intel `icx/icpx` compiler (oneAPI), no Docker intermediary. What you gain:

- Speculative decoding (draft model) — potential +50–150% on generation throughput
- IQ quantizations (IQ4\_XS, IQ3\_M) — better quality per GB than K\_M
- Up-to-date model support with llama.cpp upstream
- OpenAI-compatible API at `localhost:8080` — same clients as Ollama, only the port changes

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

> **29283 MiB total (~28.6 GB):** the `xe` driver exposes almost all unified RAM as the GPU pool — expected on Lunar Lake. Free memory varies with OS load; ~7–12 GB free in daily desktop use.

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
  -m ../models/llama3.1-8b-instruct-q4_k_m.gguf \
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
| `--port` | 8080 | API port (different from Ollama which uses 11434) |
| `--host` | 0.0.0.0 | Listen on all interfaces |

### 6.3 First model load

Every startup compiles SYCL kernels JIT for the Arc 140V Xe2 — this takes **2–5 minutes** and is normal. The persistent kernel cache (`SYCL_CACHE_PERSISTENT=1`) is disabled due to a bug in oneAPI 2026.0 (`libsycl.so.9`) that causes a SIGSEGV in `PersistentDeviceCodeCache::getItemFromDisc`. Re-enable it once Intel ships a fix.

> **Cache directories** (if re-enabling after a fix): `~/.cache/libsycl_cache/` and `~/.cache/neo_compiler_cache/` — these are the actual locations used by oneAPI 2026.0, not `~/.cache/sycl/`. Clear both if switching between oneAPI versions or after a kernel driver update.

### 6.4 Startup script

Create `~/llm/llama-cpp-arc/start-server.sh`:

```bash
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
MODEL="${1:-${MODELS_DIR}/qwen2.5-coder-14b-instruct-q4_k_m.gguf}"

exec "${LLAMACPP_DIR}/build/bin/llama-server" \
  -m "${MODEL}" \
  --port 8080 \
  --host 0.0.0.0 \
  --n-gpu-layers 999 \
  --ctx-size 8192 \
  --parallel 1
```

```bash
chmod +x ~/llm/llama-cpp-arc/start-server.sh

# Usage
./start-server.sh                                          # default model
./start-server.sh models/qwen3-8b-q4_k_m.gguf            # specific model
```

---

## 7. Recommended models ⚠️

### Memory budget

- Total RAM: 32 GB
- OS + desktop + apps in use: ~11–12 GB
- Available for models (measured with IPEX-LLM): ~19–20 GB after clean reboot
- **Safe ceiling in daily use: 16 GB of model**

> With 32 GB of unified RAM it is not possible to separate "GPU VRAM" from the rest of RAM. The Arc 140V accesses the same LPDDR5X pool as the CPU.

> ⚠️ **xe driver behavior:** once the xe driver assigns RAM pages to the GPU pool (on first model load), it does not return them to the system even if the model is unloaded. Memory is only fully recovered with a reboot or `echo 3 > /proc/sys/vm/drop_caches` after stopping the server.

### 7.1 Recommended models (GGUFs from Hugging Face)

Always use verified publishers: **bartowski**, **unsloth**, **lmstudio-community**. Do not use unknown publishers.

| Model | Quant | Disk size | Role | HF source | IPEX-LLM baseline |
|---|---|---|---|---|---|
| Qwen2.5-Coder-14B-Instruct | Q4\_K\_M | ~9.0 GB | Agentic coding (Cline) | bartowski | — |
| Qwen2.5-14B-Instruct | Q4\_K\_M | ~9.0 GB | General / instruction | bartowski | 10.7 tok/s gen |
| Qwen3-8B | Q4\_K\_M | ~5.2 GB | Reasoning / long context | unsloth | 18.1 tok/s gen |
| Llama-3.1-8B-Instruct | Q4\_K\_M | ~4.9 GB | Fast general purpose | bartowski | 18.9 tok/s gen |
| Gemma-3-12B-IT | Q4\_K\_M | ~8.1 GB | General / vision | bartowski | 10.5 tok/s gen |
| Phi-4-mini-Instruct | Q4\_K\_M | ~2.5 GB | FIM autocomplete (Twinny) | bartowski | — |
| Ornith-1.0-9B | Q6\_K | ~7.4 GB | Agentic coding / tool-calling | deepreinforce-ai | — |

> Runtime RAM values with llama.cpp SYCL **are pending measurement**. As a reference, IPEX-LLM with Flash Attention used ~40% less than the on-disk model size.
> IPEX-LLM baseline figures: Q4\_K\_M, CTX=8192, Flash Attention enabled — same hardware.

### 7.2 Ornith-1.0-9B — specific configuration

Ornith-1.0-9B ([GGUF repo](https://huggingface.co/deepreinforce-ai/Ornith-1.0-9B-GGUF)) is a dense 9B model based on Qwen 3.5, post-trained for agentic coding (SWE-Bench, Terminal-Bench, NL2Repo). It uses internal `<think>` reasoning blocks before answering — expect higher TTFT than a standard 9B model.

**Recommended quantization:** Q6\_K (7.36 GB) — fits comfortably in the ~20 GB available pool leaving headroom for context and OS. Q8\_0 (9.53 GB) is also viable.

**Download:**

```bash
huggingface-cli download deepreinforce-ai/Ornith-1.0-9B-GGUF \
  --include "ornith-1.0-9b-q6_k.gguf" \
  --local-dir ~/llm/llama-cpp-arc/models/
```

**Start the server with the recommended sampling parameters:**

```bash
./build/bin/llama-server \
  -m models/ornith-1.0-9b-q6_k.gguf \
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
# Install huggingface-cli
pip install --user huggingface-hub

mkdir -p ~/llm/llama-cpp-arc/models

# Download a specific model (example: Qwen2.5-Coder-14B Q4_K_M)
huggingface-cli download \
  bartowski/Qwen2.5-Coder-14B-Instruct-GGUF \
  Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf \
  --local-dir ~/llm/llama-cpp-arc/models

# Download Qwen3-8B
huggingface-cli download \
  unsloth/Qwen3-8B-GGUF \
  Qwen3-8B-Q4_K_M.gguf \
  --local-dir ~/llm/llama-cpp-arc/models
```

---

## 8. Model management and benchmarking ⚠️

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

### 8.3 Benchmark with llama-bench

```bash
# Basic benchmark: prefill and generation
./build/bin/llama-bench \
  -m models/qwen3-8b-q4_k_m.gguf \
  -n 128 \
  -ngl 999

# Useful options:
# -n <tokens>       tokens to generate
# -p <tokens>       prompt tokens (prefill)
# -ngl <layers>     GPU layers (999 = all)
# -t <threads>      CPU threads (relevant only if some layers run on CPU)
```

> llama-bench results will be added to this document once validated on the Arc 140V.

**Baseline reference — IPEX-LLM (same models Q4\_K\_M, Arc 140V, CTX=8192):**

| Model | Gen tok/s | Prefill tok/s | TTFT ms |
|---|---|---|---|
| qwen2.5-coder:7b | 20.0 | 814 | 56 ms |
| qwen3:8b | 18.1 | 522 | 62 ms |
| llama3.1:8b-instruct | 18.9 | 429 | 56 ms |
| gemma3:12b | 10.5 | 240 | 100 ms |
| qwen2.5:14b-instruct | 10.7 | 451 | 100 ms |

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
./start-server.sh models/qwen3-8b-q4_k_m.gguf

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
