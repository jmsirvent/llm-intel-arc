# OpenVINO Model Server — Intel Arc 140V (Yoga Slim 7)
**Ubuntu 24.04 LTS · Intel Core Ultra 7 258V · Intel Arc 140V (Xe2) · 32 GB LPDDR5X**

Candidate 3 of the inference-engine spike tracked in `../TODO.md` and `../README.md`
§"Inference engine landscape" — evaluated after llama.cpp's Vulkan backend and native
Ollama, both ruled out. `../llama-cpp-arc/` (SYCL) remains the production backend while
this spike runs; development there is paused, not replaced, pending this evaluation's
outcome.

---

## Why this candidate

Documented first-party Xe2 support and a native OpenAI-compatible API
(`/v3/chat/completions`, `/v3/models`) made OVMS the strongest remaining candidate after
Vulkan and Ollama both underperformed llama.cpp's own SYCL build. Unlike those two, OVMS
uses a structurally different inference stack (OpenVINO's own GPU plugin, paged attention,
continuous batching) rather than the same GGML/llama.cpp kernels — the first candidate with
a real chance of beating the SYCL baseline outright, not just losing less badly.

## Architecture

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

## Project status

**In progress (started 2026-07-21).** Native binary install (no Docker), self-contained
under this directory, no systemd unit. All 6 non-multimodal catalog models with an official
`OpenVINO`-org conversion have been benchmarked against the `llama-cpp-arc` SYCL baseline;
vision has been validated on a non-Gemma4 model after the whole Gemma-4 family turned out
blocked by an upstream bug. **Not a production decision yet** — quality (not just speed)
and long-context/multi-turn behavior remain unvalidated. See `../TODO.md` for the tracked
next steps.

## Quick start

```bash
cd ovms-arc/ovms
export LD_LIBRARY_PATH="$(pwd)/lib:${LD_LIBRARY_PATH:-}"
export PYTHONPATH="$(pwd)/lib/python:${PYTHONPATH:-}"

./bin/ovms --source_model OpenVINO/Qwen3-8B-int4-ov \
  --model_repository_path ./models --target_device GPU --task text_generation \
  --enable_prefix_caching false --rest_port 9000

curl http://127.0.0.1:9000/v3/models
```

See `CLAUDE.md` for the full gotcha list before relying on this (PYTHONPATH requirement,
prefix-caching default, VLM pipeline detection, tool-parser coverage).

## Performance — OVMS vs. the llama.cpp SYCL baseline (int4, GPU, prefix caching disabled)

| Model | Params | Prefill Δ vs SYCL | Generation Δ vs SYCL |
|---|---|---|---|
| Phi-4-mini | ~3.8B | +118% | **−5.7%** |
| DeepSeek-R1-Distill-Qwen-7B | 7B | +173% | +9.0% |
| Qwen2.5-Coder-7B-Instruct | 7B | +313% | +13.4% |
| Qwen3-8B | 8B | +350% | **+42%** |
| Qwen2.5-Coder-14B-Instruct | 14B | +125% | +13.3% |
| Qwen3-14B | 14B | +114% | +0.9% |

**Prefill wins robustly and unconditionally** across every model and size tested — no
exceptions. **Generation is architecture/kernel-dependent, not size-dependent**: most models
cluster around a modest but real **+9% to +13%**; Qwen3-8B is a striking positive outlier
(+42%) while Qwen3-14B — same family, one size up — is nearly flat (+0.9%); Phi-4-mini
(smallest model tested) is the only regression. No clean size trend explains the spread —
don't quote a single blanket percentage for "OVMS vs SYCL" without checking the specific
model's architecture. Full methodology, per-model raw numbers, and GPU-residency
confirmation (`xpu-smi` on every run) in `ovms-spike-notes.md`.

**Memory, not just speed:** Qwen3-14B loaded with 11 GiB `disponible` on OVMS vs.
llama.cpp SYCL's documented "dangerous" 1.8-3.2 GiB on the same model — OVMS's
paged-attention/dynamic KV-cache allocation handles large models more gracefully, even
where its throughput edge is smallest.

## Vision and tool-calling

The entire **Gemma-4 family is unusable on OVMS today** (E2B and E4B both hit independent,
unfixable bugs in the Gemma4 VLM pipeline — see [model_server#4178](https://github.com/openvinotoolkit/model_server/issues/4178)).
A non-Gemma4 architecture closes the gap instead:

| Model | Vision | Tool-calling + vision combined |
|---|---|---|
| Gemma-4-E2B / E4B | ❌ blocked (upstream bug) | ❌ |
| Qwen2.5-VL-7B-Instruct | ✅ works | ❌ (no OVMS tool parser for Qwen2.5) |
| **Qwen3-VL-8B-Instruct** | ✅ works | ✅ **works** (`--tool_parser hermes3`) |

`Qwen3-VL-8B-Instruct-int4-ov` is the confirmed choice for any workload needing vision
and/or tool-calling on OVMS. Full test transcripts in `ovms-spike-notes.md`.

## Model coverage

9 of the 11 models in the `llama-cpp-arc` catalog have an official pre-converted
`OpenVINO/*-int4-ov` repo (checked via the HF API against the `OpenVINO` org specifically).
**Llama-3.1-8B-Instruct and Gemma-4-12B don't** — only unverified third-party conversions
exist, which don't meet this project's quantizer-trust bar (see `../CLAUDE.md`) — excluded
from this spike rather than either lowering that bar or reintroducing a local
`optimum-intel` conversion step.

## Full documentation

→ **[ovms-spike-notes.md](ovms-spike-notes.md)**

Covers: native install steps, every benchmark run with raw numbers and methodology notes,
the Gemma4 VLM bug investigation (including the failed `graph.pbtxt` workaround attempt),
the tool-parser findings, and the open questions blocking a production decision.
