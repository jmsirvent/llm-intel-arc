# OpenVINO Model Server (OVMS) spike — notes

> **Provisional document.** Tracks candidate 3 of the inference-engine evaluation
> (`~/llm/README.md` §"Inference engine landscape", `~/llm/TODO.md`), run after llama.cpp's
> Vulkan backend and native Ollama, both ruled out. `../llama-cpp-arc/` (SYCL) stays the
> production backend throughout — this is a parallel evaluation, not a migration in
> progress. Once results are complete enough for a production decision, this content is
> either promoted into a permanent guide or the decision is documented and this file stays
> as the closed record — same pattern as `../llama-cpp-arc/vulkan-spike-notes.md`.

## Goal

Determine whether OVMS is viable as a complement or replacement for the SYCL `llama-server`
backend on this hardware — throughput, memory behavior, and (still pending) quality and
long-context behavior — without touching the production `llama-cpp-arc/` install.

## Status

🔶 In progress. 6/6 non-multimodal catalog models benchmarked; vision validated on a
non-Gemma4 architecture after the whole Gemma-4 family turned out blocked. Quality battery
and long-context/multi-turn behavior not yet run — no production decision made.

## 1. Native install (no Docker)

```bash
mkdir -p ~/llm/ovms-arc && cd ~/llm/ovms-arc
curl -fSL -o ovms_ubuntu24_2026.2.1_python_on.tar.gz.sha256 \
  "https://github.com/openvinotoolkit/model_server/releases/download/v2026.2.1/ovms_ubuntu24_2026.2.1_python_on.tar.gz.sha256"
curl -fSL -o ovms_ubuntu24_2026.2.1_python_on.tar.gz \
  "https://github.com/openvinotoolkit/model_server/releases/download/v2026.2.1/ovms_ubuntu24_2026.2.1_python_on.tar.gz"
sha256sum -c ovms_ubuntu24_2026.2.1_python_on.tar.gz.sha256   # verify before extracting
tar -xzf ovms_ubuntu24_2026.2.1_python_on.tar.gz
```

Chose the `python_on` variant over `python_off` because `--source_model`'s auto-pull and
tool-calling support both need it. Downloaded via plain `curl` (no pipe to a shell), same
pattern as the earlier Ollama spike, per this org's script-transparency policy.

**GPU prerequisite already satisfied** — `intel-opencl-icd` (installed for the `xe`/Level
Zero stack used by `llama-cpp-arc`) is exactly what OVMS's GPU plugin needs. `clinfo`
already showed `Intel(R) Arc(TM) Graphics` correctly; no driver work required for this
candidate, unlike the Vulkan/Ollama spikes which needed their own prerequisite checks.

### Setup gotchas (undocumented, found by trial)

- **`ModuleNotFoundError: No module named 'pyovms'`** on every launch unless `PYTHONPATH`
  includes `<install>/lib/python/`. The log makes this look like a clean shutdown
  (`PythonInterpreterModule shutting down` right after `starting`) — the actual cause is a
  debug-level line easy to miss: `PythonBackend initialization failed: ModuleNotFoundError`.
- `LD_LIBRARY_PATH` must include `<install>/lib/` — the binary bundles its own
  `libopenvino_intel_gpu_plugin.so`, `libOpenCL.so`, `libtbb.so`, etc.

## 2. Model coverage check

Before benchmarking, checked which of the 11 `llama-cpp-arc` catalog models have an
official pre-converted `OpenVINO/*-int4-ov` repo — avoids a local `optimum-intel`
conversion step entirely for anything covered. Checked via the HF API against the
`OpenVINO` org specifically (not fuzzy web search):

```bash
curl -s "https://huggingface.co/api/models?author=OpenVINO&search=<name>"
```

**9/11 covered.** `Llama-3.1-8B-Instruct` and `Gemma-4-12B` are the two gaps — only
third-party community conversions exist for either (e.g. `EmbeddedLLM/...` for Llama-3.1,
`HarmenWessels/...`/`Wondernutts/...` for Gemma-4-12B), none from a quantizer meeting this
project's trust bar (`bartowski`/`unsloth`/`lmstudio-community`/original publisher — see
`../CLAUDE.md`). **Decision: exclude both from this spike** rather than lower the trust bar
or reintroduce local conversion. `Ornith-1.0-9B` (deepreinforce-ai, niche) has no conversion
anywhere and was never expected to.

## 3. Benchmark methodology

- **Prefill**: unique random-word-salad prompt per sample (never the same prompt twice —
  `--enable_prefix_caching` defaults to `true`; a repeated prompt returns near-instantly as
  a cache hit, not real throughput). Always launched with `--enable_prefix_caching false`
  as an extra safeguard. tok/s = `prompt_tokens / time_total`, `max_tokens: 1`. First
  sample per model discarded as cold-start warmup; remaining 3 averaged.
- **Generation**: short warm prompt, `max_tokens: 200`, tok/s = `completion_tokens /
  time_total` (prefill cost negligible at this prompt length). 2-3 repeats averaged.
- **GPU-residency check**: `xpu-smi dump -d 0 -m 0,5 -i 1` run concurrently with a
  generation request on every single model tested — confirms non-zero GPU engine
  utilization (~16-17% consistently) and rising GPU memory, ruling out a silent CPU
  fallback. Never skipped, even after the pattern became repetitive.
- **Comparison baseline**: `llama-bench -m <model> -p 512 -n 128 -ngl 999` on the existing
  SYCL build in `../llama-cpp-arc/`, `GGML_SYCL_DEVICE=0`, `SYCL_CACHE_PERSISTENT=0`. Two
  models (Phi-4-mini, DeepSeek-R1-Distill-Qwen-7B/Qwen2.5-Coder-7B) had never been
  benchmarked standalone before this spike — only as a speculative-decoding draft or from a
  memory note without the prefill number — so a fresh SYCL baseline was generated first.

## 4. Results — non-multimodal catalog (6/6 tested)

| Model | Params | SYCL prefill | OVMS prefill | Δ prefill | SYCL gen | OVMS gen | Δ gen |
|---|---|---|---|---|---|---|---|
| Phi-4-mini | ~3.8B | 819 | ~1788 | +118% | 33.97 | ~32.05 | **−5.7%** |
| DeepSeek-R1-Distill-Qwen-7B | 7B | 398.86 | ~1091 | +173% | 19.87 | ~21.65 | +9.0% |
| Qwen2.5-Coder-7B-Instruct | 7B | 412.14 | ~1702 | +313% | 19.92 | ~22.59 | +13.4% |
| Qwen3-8B | 8B | 323.04 | ~1455 | +350% | 15.25 | ~21.72 | **+42%** |
| Qwen2.5-Coder-14B-Instruct | 14B | 227 | ~510 | +125% | 9.92 | ~11.24 | +13.3% |
| Qwen3-14B | 14B | 225 | ~482 | +114% | 10.09 | ~10.18 | +0.9% |

### Conclusion from this table

- **Prefill wins robustly and unconditionally.** +114% to +350%, every model, every size,
  no exceptions. This is OVMS's dependable, architecture-independent advantage on this
  hardware — no need to re-verify per model going forward.
- **Generation is the nuanced part, and it isn't a size trend.** Three models
  (DeepSeek-R1-Distill, both Qwen2.5-Coder sizes) cluster tightly around **+9% to +13%** —
  the "normal" expected generation improvement. Qwen3 breaks that norm in both
  directions: Qwen3-8B massively exceeds it (+42%), Qwen3-14B falls below it to nearly flat
  (+0.9%) — same architecture, size alone swings the result over 40 points. Phi-4-mini
  (smallest model tested) is the sole regression. **Neither "smaller is better" nor
  "bigger is better" explains the spread** — whatever drives it is architecture/kernel
  specific (likely a particular optimization path in OpenVINO GenAI that benefits Qwen3-8B
  disproportionately), not a clean function of parameter count.
- **Memory finding, independent of throughput**: Qwen3-14B loaded with 11 GiB `disponible`
  and moderate swap (4.7/8 GiB peak, remediated after) on OVMS — nowhere near
  `llama-cpp-arc`'s documented "dangerous" 1.8-3.2 GiB `disponible` on the same model.
  OVMS's paged-attention/dynamic KV-cache allocation appears to genuinely handle memory
  pressure better on larger models than llama.cpp's static reservation, independent of
  whichever engine wins on raw tok/s.
- **How to apply going forward**: don't quote a single blanket "OVMS vs SYCL" percentage.
  Prefill can be quoted as a reliable win regardless of model. For generation, check where
  the specific model's architecture falls — most things land near +9-13%, Qwen3 needs its
  own per-size check, and this dataset (6 models) is probably enough that a 7th/8th
  same-family throughput number adds little; the more valuable next step is quality
  validation, not more speed numbers.

## 5. Vision: the whole Gemma-4 family is blocked

**Gemma-4-E2B** (`OpenVINO/gemma-4-E2B-it-int4-ov`) — loads fine (`AVAILABLE`, VLM
continuous-batching servable), but **every chat completion request crashes the LLM
executor**, with or without an image in the request (ruling out "missing image" as the
cause):
```
Exception from .../infer_request.cpp:224: Check 'TRShape::broadcast_merge_into(...)' failed
...While validating node 'opset1::Add Add_...' ... Argument shapes are inconsistent.
```

**Gemma-4-E4B** (`OpenVINO/gemma-4-E4B-it-int4-ov`) — different failure, worse: fails
**before serving anything**, at load time:
```
Check 'ov::op::util::has_op_with_type<ov::op::v13::ScaledDotProductAttention>(model)' failed
...No ScaledDotProductAttention operation observed in the graph, cannot perform the
SDPAToPagedAttention transformation.
```
Tried the fix an Intel maintainer suggested in the tracking issue (edit the auto-generated
`graph.pbtxt`'s `node_options` to add `pipeline_type: LM`, bypassing the PagedAttention
transformation) — **doesn't work on this OVMS version**. A separate, harder validation gate
fires first: `Models directory content indicates VLM pipeline, but pipeline type is set to
non-VLM type` — OVMS inspects the model directory for vision-model files and unconditionally
rejects any non-VLM `pipeline_type`, regardless of manual `graph.pbtxt` edits. (`--pipeline_type`
CLI flag hits the identical wall.) No further workaround attempted — stripping vision files
from the download stops being configuration and starts being an unsupported hack.

**Verdict: the entire Gemma-4 family is unusable on OVMS today** (E2B and E4B — two
independent failure modes, same root cause: `gemma4` VLM support is incomplete in OpenVINO
GenAI's PagedAttention/VLM_CB machinery for this OVMS release). Tracked upstream:
[openvinotoolkit/model_server#4178](https://github.com/openvinotoolkit/model_server/issues/4178)
(open since May 2026 — "Gemma4 is not supported... work is still very much in progress").
**Don't re-attempt any Gemma-4 model on OVMS until that issue closes.**

## 6. Vision, take two: non-Gemma4 architectures

### Qwen2.5-VL-7B-Instruct — vision works, tool-calling doesn't

`OpenVINO/Qwen2.5-VL-7B-Instruct-int4-ov` loads cleanly (`AVAILABLE`), handles text-only
chat fine, and **correctly answers a vision question** ("what color is this image?" → the
right answer, both on a short prompt and a longer 150-word description task; ~20.56 tok/s
generation, GPU-confirmed). First working VLM in this entire spike — proves the Gemma4 bug
is architecture-specific, not a general "VLM pipelines are broken on OVMS" problem.

**Gap**: sent a combined image + `tools`-schema request (mirroring the Gemma-4-12B/Hermes
toolset test done earlier on `llama-cpp-arc`). The model reasoned about the image correctly
and generated a well-formed tool-call JSON — but OVMS returned it as raw text in `content`
with `tool_calls: []`, unparsed. Tried both auto-detection and manually forcing
`--tool_parser hermes3` (its docs say `hermes3` "also works for Qwen3 models") — same empty
result both times. Root cause, confirmed from the upstream `docs/llm/reference.md`: **OVMS
ships tool parsers only for `hermes3` (Qwen3), `llama3`, `phi4`, `mistral`, `devstral`,
`gptoss`, `qwen3coder`, `lfm2`, `gemma4` — there is no parser for Qwen2.5** (base or VL).

### Qwen3-VL-8B-Instruct — closes the gap completely

`OpenVINO/Qwen3-VL-8B-Instruct-int4-ov` launched with `--tool_parser hermes3` from the
start:

- Loads cleanly (one harmless warning, "BOS token was not found in model files" — cosmetic,
  same as other Qwen models, no functional impact).
- Text-only chat: works. No sign of the chat-template-loading bug reported in
  [model_server#4322](https://github.com/openvinotoolkit/model_server/issues/4322) (that
  report is for a text decoder extracted from a different, `qwen3_5`-*omni* model — not
  applicable to this standard packaged VLM pipeline).
- Vision: correct ("red" on the color-identification test).
- **Vision + tool-calling combined — full success.** `finish_reason: tool_calls`, a
  properly parsed `tool_calls` array (not raw JSON in `content`), correct function name and
  argument (`{"label":"red"}`, matching the image's actual color).
- Generation: ~20.2 tok/s average across 3 runs, GPU-confirmed (~16.6% engine utilization,
  ~78% GPU memory — same signature as every other model in this spike).

**Verdict: `Qwen3-VL-8B-Instruct-int4-ov` is the confirmed model for any workload needing
vision and/or tool-calling on OVMS.** This is the first fully-working vision+tool-calling
result across the *entire* evaluation (both `llama-cpp-arc` and `ovms-arc`) — Gemma-4-12B
on `llama-cpp-arc`/SYCL passed a similar combined test earlier, but that's a different
engine; this result is OVMS-specific. No further vision-model spiking planned unless this
one fails a future quality check.

## 7. Open questions before any production decision

- **Quality, not just speed** — no battery run yet on any OVMS-served model. The
  `llama-cpp-arc/quality-test.sh` battery (5 fixed prompts, save/diff baselines) is the
  obvious template to port, but OVMS's API surface differs enough (`v3` vs `v1` paths, no
  `chat_template_kwargs` reasoning toggle observed) that it needs adapting, not just
  pointing at a different port.
- **Long-context / multi-turn behavior** — `llama-cpp-arc`'s real operational pain point
  (prefill degrading from ~177 to ~50 tok/s within a single 24.4K-token agentic prompt, see
  its `TODO.md`) has no OVMS equivalent measurement yet. OVMS's paged-attention design is a
  plausible reason to expect better behavior here, but that's a hypothesis, not a result.
- **Llama-3.1-8B-Instruct and Gemma-4-12B** remain uncovered — no trusted pre-converted
  model exists. Revisit if a trusted quantizer publishes one, or accept a local
  `optimum-intel` conversion if those two specifically become important later.
