# Local LLM Inference — Yoga Slim 7 14ILL10 (OpenVINO Model Server)
**Ubuntu 24.04 LTS · Intel Core Ultra 7 258V · Intel Arc 140V (Xe2) · 32 GB LPDDR5X**

> **Living document.** Sections validated on real hardware are marked ✅.
> Sections marked ⚠️ are documented but pending validation.
> Candidate 3 of the inference-engine spike (`../TODO.md`, `../README.md` §"Inference
> engine landscape") — evaluated after llama.cpp's Vulkan backend and native Ollama, both
> ruled out. `../llama-cpp-arc/` (SYCL) remains the production backend while this runs.

---

## Table of contents

1. [Hardware summary and solution architecture](#1-hardware-summary-and-solution-architecture)
2. [System prerequisites](#2-system-prerequisites)
3. [OVMS native binary install](#3-ovms-native-binary-install)
4. [`ovms` — configuration and startup](#4-ovms--configuration-and-startup)
5. [Recommended models](#5-recommended-models)
6. [Model management and benchmarking](#6-model-management-and-benchmarking)
   - [6.4 Quality battery](#64-quality-battery-)
7. [Vision and tool-calling](#7-vision-and-tool-calling)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Hardware summary and solution architecture

| Component | Detail |
|---|---|
| CPU | Intel Core Ultra 7 258V (Lunar Lake, 8 cores @ 4.7 GHz) |
| GPU | Intel Arc 140V (Xe2 iGPU, 8 Xe2 cores, driver: `xe`) |
| NPU | Intel AI Boost / Lunar Lake NPU (`intel_vpu`) — not used by this stack |
| RAM | 32 GB LPDDR5X-8533 unified (shared CPU/GPU/NPU, ~97 GB/s) |
| Storage | Samsung NVMe PM9C1b 1 TB |
| OS | Ubuntu 24.04 LTS, kernel 6.19.10 |

### Why OVMS

Documented first-party Xe2 support and a native OpenAI-compatible API
(`/v3/chat/completions`, `/v3/models`) made OVMS the strongest remaining candidate after
llama.cpp's Vulkan backend and native Ollama both underperformed llama.cpp's own SYCL
build (`../llama-cpp-arc/`). Unlike those two, OVMS uses a structurally different
inference stack — OpenVINO's own GPU plugin, paged attention, continuous batching —
instead of the same GGML/llama.cpp kernels. It's the first candidate with a real chance of
beating the SYCL baseline outright, not just losing less badly, and it delivered: prefill
wins unconditionally across every model tested (§5).

```
curl / OpenAI-compatible client
                     │
                     │  OpenAI-compatible REST  (localhost:9000)
                     ▼
                  ovms  (OpenVINO GenAI, paged attention)
                     │
                     │  OpenVINO GPU plugin (reuses intel-opencl-icd)
                     ▼
          Intel Arc 140V  (Xe2, driver xe)
          ──────────────────────────────────
          LPDDR5X-8533  ·  32 GB  unified memory
```

---

## 2. System prerequisites ✅

OVMS's GPU plugin needs the Intel Compute Runtime's OpenCL driver — **already installed**
on this machine for the `xe`/Level Zero stack `../llama-cpp-arc/` depends on. No new driver
work is needed if that project's §2-3 are already done.

```bash
# Confirm the xe driver is active (same check as llama-cpp-arc §2.1)
lspci -k | grep -A3 -i "VGA\|Display"
# Expected: Kernel driver in use: xe

# Confirm the OpenCL runtime OVMS's GPU plugin needs is installed
dpkg -l | grep intel-opencl-icd
# Expected: ii  intel-opencl-icd  <version>

clinfo --list
# Expected:
# Platform #0: Intel(R) OpenCL Graphics
#  `-- Device #0: Intel(R) Arc(TM) Graphics
```

If `clinfo` doesn't show the Arc 140V, the problem is the driver stack, not OVMS — fix that
via `../llama-cpp-arc/local-llm-yoga-slim7-ubuntu2404-llamacpp.md` §2-3 first.

---

## 3. OVMS native binary install ✅

No Docker, no build step — OVMS ships as a precompiled binary tarball. Two variants exist
per release: `python_off` and `python_on`. **Use `python_on`** — tool-calling support and
`--source_model`'s Hugging Face auto-pull both need the bundled Python interpreter.

```bash
mkdir -p ~/llm/ovms-arc && cd ~/llm/ovms-arc

# Plain curl, no pipe to a shell — download the checksum first, verify after
curl -fSL -o ovms_ubuntu24_2026.2.1_python_on.tar.gz.sha256 \
  "https://github.com/openvinotoolkit/model_server/releases/download/v2026.2.1/ovms_ubuntu24_2026.2.1_python_on.tar.gz.sha256"
curl -fSL -o ovms_ubuntu24_2026.2.1_python_on.tar.gz \
  "https://github.com/openvinotoolkit/model_server/releases/download/v2026.2.1/ovms_ubuntu24_2026.2.1_python_on.tar.gz"

sha256sum -c ovms_ubuntu24_2026.2.1_python_on.tar.gz.sha256
# Expected: ovms_ubuntu24_2026.2.1_python_on.tar.gz: OK

tar -xzf ovms_ubuntu24_2026.2.1_python_on.tar.gz
# Extracts to ./ovms/ — bin/, lib/, models/ (created on first model pull)

./ovms/bin/ovms --version
# Expected:
# OpenVINO Model Server 2026.2.1.1122f03bf
# OpenVINO backend 2026.2.1-...
# OpenVINO GenAI backend 2026.2.1.0-...
```

Check for a newer release before starting a fresh install:
[github.com/openvinotoolkit/model_server/releases](https://github.com/openvinotoolkit/model_server/releases).

---

## 4. `ovms` — configuration and startup ✅

### 4.1 Required environment variables

⚠️ **Not needed for `python_off` builds — required for `python_on`.** Skipping either of
these makes every launch fail with `ModuleNotFoundError: No module named 'pyovms'`, and the
log looks like a clean shutdown unless you scroll up to the `error`-level line.

```bash
cd ~/llm/ovms-arc/ovms
export LD_LIBRARY_PATH="$(pwd)/lib:${LD_LIBRARY_PATH:-}"   # bundled libopenvino_intel_gpu_plugin.so, libOpenCL.so, etc.
export PYTHONPATH="$(pwd)/lib/python:${PYTHONPATH:-}"      # the pyovms module
```

### 4.2 Start the server

```bash
./bin/ovms --source_model OpenVINO/Qwen3-8B-int4-ov \
  --model_repository_path ./models \
  --target_device GPU \
  --task text_generation \
  --enable_prefix_caching false \
  --rest_port 9000
```

- `--source_model <HF repo>` — pulls and prepares the model automatically (git+LFS) into
  `--model_repository_path` on first launch; subsequent launches skip the download and
  reuse the local copy.
- `--target_device GPU` — without this OVMS defaults to CPU.
- `--enable_prefix_caching false` — see §6.1 before removing this; it changes benchmark
  numbers, not just a minor knob.
- `--rest_port 9000` — this project's convention (`llama-cpp-arc` uses `8080`, the deleted
  `ollama-arc` spike used `11500`).
- Add `--tool_parser hermes3` (or another value from §7) when the workload needs
  tool-calling — see §7 for which models actually support it.

### 4.3 Verify

```bash
curl http://127.0.0.1:9000/v3/models
# Expected: {"data":[{"id":"OpenVINO/Qwen3-8B-int4-ov","object":"model",...}],"object":"list"}

curl http://127.0.0.1:9000/v3/chat/completions -H "Content-Type: application/json" -d '{
  "model": "OpenVINO/Qwen3-8B-int4-ov",
  "messages": [{"role": "user", "content": "Say hello in one word."}],
  "max_tokens": 10
}'
```

First launch for a new model takes longer than subsequent ones — the model has to
download (a few GB) and the GPU pipeline has to initialize before `/v3/models` lists it as
available. Poll `/v3/models` in a loop rather than assuming a fixed sleep is enough.

### 4.4 Stop the server

```bash
pgrep -fa "bin/ovms"   # find the real PID
kill <PID>             # never `kill %N` — job-control state doesn't survive across
                        # separate shell invocations, see ../CLAUDE.md
```

⚠️ Same `xe` driver risk documented in `../llama-cpp-arc/CLAUDE.md`: never run two
model-loading processes at once. Confirm no `bin/ovms` or `llama-server` is running before
starting a new one.

---

## 5. Recommended models ✅

### 5.1 Catalog coverage

Before benchmarking, checked which of the 11 models in the `llama-cpp-arc` catalog have an
official pre-converted `OpenVINO/*-int4-ov` repo — this avoids a local `optimum-intel`
conversion step for anything covered.

```bash
curl -s "https://huggingface.co/api/models?author=OpenVINO&search=<model-name>"
```

**9/11 covered.** `Llama-3.1-8B-Instruct` and `Gemma-4-12B` are the two gaps — only
third-party community conversions exist for either, none from a quantizer meeting this
project's trust bar (`bartowski`/`unsloth`/`lmstudio-community`/original publisher — see
`../CLAUDE.md`). Excluded from this spike rather than lowering that bar or reintroducing
local conversion. `Ornith-1.0-9B` (niche, deepreinforce-ai) has no conversion anywhere.

### 5.2 Performance — OVMS vs. the llama.cpp SYCL baseline

int4, GPU, `--enable_prefix_caching false`, methodology in §6.1.

| Model | Params | SYCL prefill | OVMS prefill | Δ prefill | SYCL gen | OVMS gen | Δ gen |
|---|---|---|---|---|---|---|---|
| Phi-4-mini | ~3.8B | 819 | ~1788 | +118% | 33.97 | ~32.05 | **−5.7%** |
| DeepSeek-R1-Distill-Qwen-7B | 7B | 398.86 | ~1091 | +173% | 19.87 | ~21.65 | +9.0% |
| Qwen2.5-Coder-7B-Instruct | 7B | 412.14 | ~1702 | +313% | 19.92 | ~22.59 | +13.4% |
| Qwen3-8B | 8B | 323.04 | ~1455 | +350% | 15.25 | ~21.72 | **+42%** |
| Qwen2.5-Coder-14B-Instruct | 14B | 227 | ~510 | +125% | 9.92 | ~11.24 | +13.3% |
| Qwen3-14B | 14B | 225 | ~482 | +114% | 10.09 | ~10.18 | +0.9% |

**Prefill wins robustly and unconditionally** — every model, every size, no exceptions.
**Generation is architecture/kernel-dependent, not size-dependent**: most models
(DeepSeek-R1-Distill, both Qwen2.5-Coder sizes) cluster around a consistent **+9% to
+13%** — the "normal" case. Qwen3 breaks that norm in both directions: Qwen3-8B massively
exceeds it (+42%), Qwen3-14B falls below it to nearly flat (+0.9%) — same architecture,
size alone swings the result over 40 points. Phi-4-mini (smallest model tested) is the sole
regression. **Neither "smaller is better" nor "bigger is better" explains the spread** —
whatever drives it is architecture/kernel specific, not a clean function of parameter
count. Don't quote a single blanket "OVMS vs SYCL" percentage without checking where the
target model's architecture falls.

**Memory, not just speed:** Qwen3-14B loaded with 11 GiB `disponible` on OVMS vs.
llama.cpp SYCL's documented "dangerous" 1.8-3.2 GiB `disponible` on the same model (see
`../llama-cpp-arc/local-llm-yoga-slim7-ubuntu2404-llamacpp.md` §7.1). OVMS's
paged-attention/dynamic KV-cache allocation handles large models more gracefully, even
where its throughput edge over SYCL is smallest.

---

## 6. Model management and benchmarking ✅

### 6.1 Benchmark methodology — the prefix-caching trap

`--enable_prefix_caching` defaults to **`true`**. A second identical request returns
near-instantly (measured 0.056s for 713 prompt tokens once) because it's a cache hit, not
real throughput — an easy way to get a meaningless, wildly-inflated prefill number. Always
launch with `--enable_prefix_caching false` for benchmarking, or use a unique prompt per
sample if you need caching enabled for the actual workload being tested.

```bash
# Prefill: unique random prompt per sample, max_tokens: 1, tok/s = prompt_tokens / time_total
curl -s -o /tmp/resp.json -w "%{time_total}" http://127.0.0.1:9000/v3/chat/completions \
  -H "Content-Type: application/json" -d '{"model":"<model>","messages":[{"role":"user","content":"<unique long prompt>"}],"max_tokens":1}'

# Generation: short warm prompt, max_tokens: 200, tok/s = completion_tokens / time_total
curl -s -o /tmp/resp.json -w "%{time_total}" http://127.0.0.1:9000/v3/chat/completions \
  -H "Content-Type: application/json" -d '{"model":"<model>","messages":[{"role":"user","content":"Write a 300-word essay about the history of trains."}],"max_tokens":200}'
```

Discard the first sample of any run as cold-start warmup; average the rest (3-4 samples
was enough to get a stable number throughout this spike).

### 6.2 GPU monitoring during inference ✅

Same tooling as `../llama-cpp-arc/` — `xpu-smi`, since `intel_gpu_top` doesn't work with
the `xe` driver.

```bash
sudo xpu-smi dump -d 0 -m 0,5 -i 1
# Run concurrently with a generation request. Expected during real GPU inference:
# ~16-17% engine utilization, rising GPU memory — consistent across every model tested in
# this spike. ~0% utilization would mean a silent CPU fallback.
```

Ran this check on **every** model in §5.2 and §7, not just once — cheap enough to be worth
the certainty, especially given how easy it is to accidentally launch without
`--target_device GPU` and get a working-but-wrong CPU-only result.

### 6.3 Memory and swap

14B-class models push swap to 4.7-6.2 GiB during load; 7-8B models are much lighter. Same
remediation as documented for `../llama-cpp-arc/`:

```bash
sync
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo swapoff -a && sudo swapon -a
```

Run this after stopping any 14B-class model before starting another benchmark — swap
doesn't self-recover just from killing the process.

### 6.4 Quality battery ✅

Speed alone doesn't tell you if a faster engine is quietly worse. `quality-test.sh` ports
`../llama-cpp-arc/quality-test.sh`'s 5-prompt battery to OVMS's `/v3/` API:

```bash
./quality-test.sh --model OpenVINO/Qwen3-8B-int4-ov --save qwen3-8b-ovms
```

Unlike llama-server, **OVMS does not ignore a mismatched `model` field** — `--model` must
match exactly what `/v3/models` reports, so it's a required flag (llama.cpp's version
hardcodes a placeholder string that llama-server ignores; that shortcut doesn't work here).
`chat_template_kwargs: {"enable_thinking": false}` was confirmed to work identically on
OVMS (same Jinja chat-template mechanism as llama.cpp) before relying on it for Qwen3.

Diffed each of the 6 non-multimodal models against the **existing** SYCL baseline in
`../llama-cpp-arc/quality-baselines/<model>/` — no need to regenerate those.

| Model | Verdict | Notable finding |
|---|---|---|
| Qwen3-8B | SYCL better (2/5) | OVMS: `fib(0)=1` math bug (contradicts its own stated "0-based indexing"); OVMS: "fixed" divide-by-zero example left a bare `print()` that would still crash as written |
| Qwen3-14B | Tied | Only prompt 4 differs (prime factors vs all divisors) — prompt ambiguity, not an error |
| Phi-4-mini | Roughly tied, 1 each way | **SYCL got the train-catchup math wrong** (0.8h instead of the correct 4h) — OVMS got it right. OVMS's own divide-by-zero fix was flawed (returns the unfiltered list instead of `[]`) |
| DeepSeek-R1-Distill-Qwen-7B | SYCL better (1/5) | Both loop unboundedly on prompt 5 (model-level issue, not engine-specific) — but on prompt 1, SYCL's loop resolves into a correct answer while OVMS never closes `</think>` and returns zero usable content, even at 3072 max_tokens |
| Qwen2.5-Coder-7B-Instruct | Tied | No bugs on either side |
| Qwen2.5-Coder-14B-Instruct | Tied | No bugs on either side; prompt 2 is character-for-character identical |

**No systematic quality winner.** Errors are model+prompt-specific, not
engine-systematic — each engine has its own real bugs on different models, and half the
models tested show no quality difference at all. Consistent with int4 quantization-scheme
differences (OpenVINO `INT4_ASYM` group-size 128 vs GGUF `Q4_K_M`) plus the
already-documented temperature-0 non-determinism in parallel reduction order — small
numerical divergences occasionally push one engine off a greedy-decoding path the other
stays on, in either direction.

**The one finding worth operational concern**: OVMS returning zero usable content on
DeepSeek-R1-Distill-Qwen-7B's prompt 1 is a reliability gap, not a quality nuance — worth
re-testing with a higher `--max-tokens` budget before trusting this model on OVMS for
anything reasoning-heavy.

---

## 7. Vision and tool-calling ✅

### 7.1 The entire Gemma-4 family is unusable on OVMS today

**Gemma-4-E2B** (`OpenVINO/gemma-4-E2B-it-int4-ov`) loads fine (`AVAILABLE`), but **every
chat completion request crashes the LLM executor**, with or without an image:
```
Exception from .../infer_request.cpp:224: Check 'TRShape::broadcast_merge_into(...)' failed
...While validating node 'opset1::Add Add_...' ... Argument shapes are inconsistent.
```

**Gemma-4-E4B** (`OpenVINO/gemma-4-E4B-it-int4-ov`) fails earlier and harder — **at load
time**, before serving anything:
```
Check 'ov::op::util::has_op_with_type<ov::op::v13::ScaledDotProductAttention>(model)' failed
...No ScaledDotProductAttention operation observed in the graph, cannot perform the
SDPAToPagedAttention transformation.
```
The documented workaround (manually add `pipeline_type: LM` to the auto-generated
`graph.pbtxt`) **does not work on this OVMS version** — a separate, harder validation gate
rejects any non-VLM `pipeline_type` the moment it detects vision-model files in the
directory, regardless of the manual edit.

**Verdict: don't attempt any Gemma-4 model on OVMS.** Tracked upstream:
[openvinotoolkit/model_server#4178](https://github.com/openvinotoolkit/model_server/issues/4178)
(open since May 2026). Revisit only once that issue closes.

### 7.2 Qwen2.5-VL-7B-Instruct — vision works, tool-calling doesn't

`OpenVINO/Qwen2.5-VL-7B-Instruct-int4-ov` loads cleanly and **correctly answers vision
questions** (~20.56 tok/s generation, GPU-confirmed) — proves the Gemma4 bug is
architecture-specific, not a general "VLM is broken on OVMS" problem.

**Gap:** combining an image with a `tools` schema produces a well-formed tool call as raw
text in `content`, but `tool_calls` stays `[]` — unparsed. Neither auto-detection nor
manually forcing `--tool_parser hermes3` fixes it. Confirmed root cause from the upstream
`docs/llm/reference.md`: **OVMS ships tool parsers for `hermes3` (also covers Qwen3),
`llama3`, `phi4`, `mistral`, `devstral`, `gptoss`, `qwen3coder`, `lfm2`, `gemma4` — there is
no parser for Qwen2.5** (base or VL).

### 7.3 Qwen3-VL-8B-Instruct — vision + tool-calling both work

```bash
./bin/ovms --source_model OpenVINO/Qwen3-VL-8B-Instruct-int4-ov \
  --model_repository_path ./models --target_device GPU --task text_generation \
  --tool_parser hermes3 --enable_prefix_caching false --rest_port 9000
```

- Loads cleanly (one harmless warning, "BOS token was not found in model files" — cosmetic,
  same as other Qwen models).
- Text-only chat and vision (image understanding) both work correctly.
- **Vision + tool-calling combined — full success**: `finish_reason: tool_calls`, a
  properly parsed `tool_calls` array, correct function name and argument extracted from
  the image content. First fully-working vision+tool-calling result across this *entire*
  evaluation (both `llama-cpp-arc` and `ovms-arc`).
- Generation: ~20.2 tok/s average, GPU-confirmed (~16.6% engine utilization, ~78% GPU
  memory — same signature as every other model in this guide).

**`Qwen3-VL-8B-Instruct-int4-ov` is the confirmed model for any workload needing vision
and/or tool-calling on OVMS.**

---

## 8. Troubleshooting

### `ModuleNotFoundError: No module named 'pyovms'`

```bash
# Cause: PYTHONPATH doesn't include the bundled pyovms module (python_on builds only)
export PYTHONPATH="$(pwd)/lib/python:${PYTHONPATH:-}"
```
The server log makes this look like a clean shutdown (`PythonInterpreterModule shutting
down` immediately after `starting`) unless you scroll to the debug-level line just above it.

### A repeated benchmark request returns suspiciously fast

```bash
# Cause: --enable_prefix_caching defaults to true — that's a cache hit, not real throughput
./bin/ovms ... --enable_prefix_caching false
```
See §6.1.

### `Models directory content indicates VLM pipeline, but pipeline type is set to non-VLM type`

Cannot be worked around. OVMS inspects the model directory for vision-model files and
unconditionally rejects any non-VLM `pipeline_type` (CLI flag or manual `graph.pbtxt` edit)
the moment it finds them. See §7.1 — this is specifically what blocks the Gemma-4 family.

### `tool_calls` stays empty even though the model generated a valid-looking tool call

The model's family has no matching `--tool_parser`. Check §7.2/§7.3 and the upstream list
(`hermes3`/Qwen3, `llama3`, `phi4`, `mistral`, `devstral`, `gptoss`, `qwen3coder`, `lfm2`,
`gemma4`) — if the model isn't on that list, there's no fix available in this OVMS release.

### GPU utilization stays at ~0% during inference

```bash
sudo xpu-smi dump -d 0 -m 0,5 -i 1   # run during a generation request
```
~0% means a silent CPU fallback — check `--target_device GPU` was actually passed, and
that `clinfo --list` still shows the Arc 140V (§2).

### RAM/swap not recovered after stopping the server

Same as `../llama-cpp-arc/`'s troubleshooting §11 — swap doesn't self-recover just from
killing the process:
```bash
sync; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'; sudo swapoff -a && sudo swapon -a
```

### Killing the server doesn't seem to work

```bash
pgrep -fa "bin/ovms"   # find the real PID — never trust kill %N across separate shells
kill <PID>
ss -ltnp | grep 9000   # confirm the port is actually free before starting a new one
```
