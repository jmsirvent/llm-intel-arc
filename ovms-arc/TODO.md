# TODO — ovms-arc

Stack-specific items for the OpenVINO Model Server spike (candidate 3 of the
inference-engine evaluation, see `../TODO.md` and `../README.md` §"Inference engine
landscape"). `../llama-cpp-arc/` remains the production backend throughout.

## Bugs (upstream, not ours to fix)

- [ ] **Gemma4 VLM pipeline broken in OVMS 2026.2.1** — `openvinotoolkit/model_server#4178`

  **Status:** open upstream since May 2026, "work is still very much in progress."

  **Symptom:** two independent failure modes hit, both blocking, no workaround found for
  either. `Gemma-4-E2B` crashes the LLM executor on every chat completion request
  (`Argument shapes are inconsistent` in an `Add` node), with or without an image.
  `Gemma-4-E4B` fails at load time (`No ScaledDotProductAttention operation observed,
  cannot perform the SDPAToPagedAttention transformation`) — even manually patching the
  generated `graph.pbtxt` to add `pipeline_type: LM` doesn't help, since a separate
  directory-content validation gate rejects any non-VLM pipeline type when vision files
  are present.

  **Workaround:** none. Use `Qwen3-VL-8B-Instruct-int4-ov` instead for vision/tool-calling
  needs — confirmed fully working (§7.3 of `local-llm-yoga-slim7-ubuntu2404-ovms.md`).

  **Reopen when:** the upstream issue closes with a confirmed fix, then re-test
  `Gemma-4-E2B`/`E4B` per the exact repro steps in `local-llm-yoga-slim7-ubuntu2404-ovms.md` §7.1.

## Improvements

- [x] **Benchmark all 6 non-multimodal catalog models with an official OVMS conversion** —
      done 2026-07-21/22. Prefill wins unconditionally (+114% to +350%); generation is
      architecture-dependent, not size-dependent (+9-13% "normal", Qwen3-8B anomaly +42%,
      Phi-4-mini regression -5.7%). Full table and methodology in
      `local-llm-yoga-slim7-ubuntu2404-ovms.md` §5.2/§6.

- [x] **Validate vision on OVMS** — done 2026-07-22. Whole Gemma-4 family ruled out (see
      Bugs above); `Qwen3-VL-8B-Instruct-int4-ov` confirmed working for vision AND
      tool-calling combined (`--tool_parser hermes3`). Full record in
      `local-llm-yoga-slim7-ubuntu2404-ovms.md` §7.

- [x] **Run a quality battery on all 6 non-multimodal candidates** — done 2026-07-22.
      Ported `../llama-cpp-arc/quality-test.sh` to `quality-test.sh` (OVMS's `/v3/` API,
      requires `--model` since OVMS doesn't ignore a mismatched model field). Diffed
      against the existing SYCL baselines in `../llama-cpp-arc/quality-baselines/`.
      **No systematic quality winner** — SYCL and OVMS each fail on different
      model-specific prompts (Qwen3-8B: 2 real OVMS bugs; Phi-4-mini: 1 real SYCL math
      error; DeepSeek-R1-Distill: OVMS returns zero content on 1 prompt where SYCL
      completes). Qwen3-14B and both Qwen2.5-Coder sizes show no difference at all. Full
      per-model table in `local-llm-yoga-slim7-ubuntu2404-ovms.md` §6.4 and the
      `project-vllm-arc-evaluation` memory. Quality no longer blocks a production
      decision — only long-context behavior does now.

- [ ] **Check long-context / multi-turn behavior** — `llama-cpp-arc`'s real operational
      pain point (prefill degrading ~177→50 tok/s within a single 24.4K-token agentic
      prompt, see its `local-llm-yoga-slim7-ubuntu2404-llamacpp.md` §8.3) has no
      OVMS-equivalent measurement yet. OVMS's paged-attention design is a plausible reason
      to expect better behavior, but that's unverified. **Blocking a production decision.**

## Ideas

- [ ] **Close the Llama-3.1-8B-Instruct / Gemma-4-12B coverage gap** — neither has a
      trusted pre-converted `OpenVINO/*-int4-ov` model (only unverified community
      conversions). Revisit if a trusted quantizer (bartowski/unsloth/lmstudio-community/
      original publisher) publishes one, or accept a local `optimum-intel` conversion if
      these two specifically become important to the vision/tool-calling use case later.
