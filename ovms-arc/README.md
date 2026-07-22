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

**Spike complete (2026-07-21/22) — no remaining technical gap.** Native binary install (no
Docker), self-contained under this directory, no systemd unit. All 6 non-multimodal catalog
models with an official `OpenVINO`-org conversion have been benchmarked for speed AND
quality against the `llama-cpp-arc` SYCL baseline; vision has been validated on a
non-Gemma4 model after the whole Gemma-4 family turned out blocked by an upstream bug.
Long-context/multi-turn behavior — the last item blocking a production decision — has now
been checked too (see "Long-context and multi-turn behavior" below): OVMS resolves the
real SYCL pain point for the realistic growing-session usage pattern. **The production
switch itself is still a separate, unmade decision** — see `../TODO.md` for the tracked
next steps.

## Quick start (once installed)

```bash
./start-server.sh                 # interactive menu — pick from the validated catalog
./start-server.sh Qwen3-8B         # by name substring
./start-server.sh OpenVINO/<repo>  # explicit source_model repo id
```

Handles `LD_LIBRARY_PATH`/`PYTHONPATH`, the per-model flags validated in this project (e.g.
`--tool_parser hermes3` only for `Qwen3-VL-8B-Instruct`), and pulls the model automatically
via `--source_model` if it isn't downloaded yet — no separate download step like
`llama-cpp-arc`'s launcher needs, OVMS handles that itself.

Equivalent manual command, if you need to run it by hand (e.g. with flags not in the
catalog):

```bash
cd ovms-arc/ovms
export LD_LIBRARY_PATH="$(pwd)/lib:${LD_LIBRARY_PATH:-}"
export PYTHONPATH="$(pwd)/lib/python:${PYTHONPATH:-}"

./bin/ovms --source_model OpenVINO/Qwen3-8B-int4-ov \
  --model_repository_path ./models --target_device GPU --task text_generation \
  --rest_port 9000

curl http://127.0.0.1:9000/v3/models   # verify once started
```

For the install steps (download, checksum, extract) see
[local-llm-yoga-slim7-ubuntu2404-ovms.md §3](local-llm-yoga-slim7-ubuntu2404-ovms.md#3-ovms-native-binary-install).
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
confirmation (`xpu-smi` on every run) in
[local-llm-yoga-slim7-ubuntu2404-ovms.md §5-6](local-llm-yoga-slim7-ubuntu2404-ovms.md#5-recommended-models).

**Quality: no systematic winner.** Ran a 5-prompt battery (`quality-test.sh`) against all 6
models above, diffed against the existing SYCL baselines. Each engine has its own
model-specific bugs — SYCL got a math problem wrong on Phi-4-mini; OVMS has a `fib(0)=1`
bug and a broken divide-by-zero fix on Qwen3-8B, and returns zero content on one
DeepSeek-R1-Distill prompt where SYCL completes. Half the models (Qwen3-14B, both
Qwen2.5-Coder sizes) show no quality difference at all. Full per-model table in
[local-llm-yoga-slim7-ubuntu2404-ovms.md §6.4](local-llm-yoga-slim7-ubuntu2404-ovms.md#64-quality-battery-).

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
and/or tool-calling on OVMS. Full test transcripts in
[local-llm-yoga-slim7-ubuntu2404-ovms.md §7](local-llm-yoga-slim7-ubuntu2404-ovms.md#7-vision-and-tool-calling).

## Long-context and multi-turn behavior

The one item this spike hadn't checked: `llama-cpp-arc` found real production pain from
live Hermes usage — prefill degraded from ~177 to ~50 tok/s within a single 24.4K-token
agentic prompt (5+ min just to process it). Tested the OVMS-equivalent with
`context-test.sh` on `Qwen3-8B`:

| Scenario | Result |
|---|---|
| Cold, single prompt, no caching (comparable to the SYCL finding) | 1,270 → 214 tok/s across 0→24.5K tokens — degrades proportionally about as much as SYCL, but **the worst OVMS point still beats SYCL's best point** |
| Growing multi-turn session, prefix caching on (the real Hermes usage pattern) | Marginal per-turn rate stays flat (927–10,799 tok/s, noisy but no decay) up to ~22K accumulated tokens — full 12-turn session in 12.3s |

**Verdict: the SYCL pain point doesn't reproduce on OVMS** when the client resends the full
growing history each turn (exactly how Hermes behaves) — prefix caching absorbs the
repeated-history cost. One new operational note: sustained long-context traffic pushed swap
to near-full even on this 8B model (previously only seen on 14B-class models under
short-prompt benchmarking) — same standard remediation clears it. Full methodology and
tables: [local-llm-yoga-slim7-ubuntu2404-ovms.md §8](local-llm-yoga-slim7-ubuntu2404-ovms.md#8-long-context-and-multi-turn-behavior).

## Model coverage

9 of the 11 models in the `llama-cpp-arc` catalog have an official pre-converted
`OpenVINO/*-int4-ov` repo (checked via the HF API against the `OpenVINO` org specifically).
**Llama-3.1-8B-Instruct and Gemma-4-12B don't** — only unverified third-party conversions
exist, which don't meet this project's quantizer-trust bar (see `../CLAUDE.md`) — excluded
from this spike rather than either lowering that bar or reintroducing a local
`optimum-intel` conversion step.

## Full documentation

→ **[local-llm-yoga-slim7-ubuntu2404-ovms.md](local-llm-yoga-slim7-ubuntu2404-ovms.md)**

Covers: prerequisites, native binary install, server configuration and startup, model
catalog and benchmarking methodology, vision/tool-calling, and troubleshooting — same
structure as `../llama-cpp-arc/local-llm-yoga-slim7-ubuntu2404-llamacpp.md`.
