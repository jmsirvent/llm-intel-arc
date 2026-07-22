# TODO — ovms-arc

**Spike closed 2026-07-22 — staying on `llama-cpp-arc`.** OVMS won every raw performance
metric tested (see the Improvements section below); the decision not to switch came from a
Hermes-fit check, not performance — full rationale in `CLAUDE.md`'s Status section and
`README.md`. Remaining items below are kept for the record and for whoever reopens this
(e.g. if the Gemma-4 upstream bug closes, or `Ornith`/`Gemma-4-12B` ever gets an OVMS
conversion) — not active work.

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

- [x] **Check long-context / multi-turn behavior** — done 2026-07-22 with the new
      `context-test.sh`, model `Qwen3-8B`. Cold, single-prompt, no-caching curve (comparable
      to `llama-cpp-arc`'s 177→50 tok/s finding): 1,270→214 tok/s across 0→24.5K tokens —
      degrades proportionally about as much, but OVMS's worst point still beats SYCL's best.
      Growing multi-turn session with prefix caching on (the real Hermes usage pattern):
      marginal per-turn rate stays flat (no decay) up to ~22K accumulated tokens. **The SYCL
      pain point doesn't reproduce on OVMS for the realistic usage pattern.** New
      operational note: sustained long-context traffic pushed swap to near-full even on this
      8B model — previously only seen on 14B-class models (see `CLAUDE.md` Gotchas). Full
      tables and methodology in `local-llm-yoga-slim7-ubuntu2404-ovms.md` §8. **This was the
      last item blocking a production decision — no technical blocker remains.**

- [x] **Check whether OVMS actually fits Hermes Agent, the real production client** — done
      2026-07-22. Three disqualifying facts, found in this order: (1) `Ornith-1.0-9B` and
      `Gemma-4-12B` have no OVMS conversion (known since day one, see Ideas below — just not
      treated as decision-ending until this check ran); (2) Hermes hard-requires ≥64,000
      tokens of context, which `Qwen3-8B`/`14B` (40,960) and both `Qwen2.5-Coder` sizes
      (32,768) fail regardless of backend; (3) of the models that do clear 64K,
      `Qwen2.5-VL-7B-Instruct` has no tool parser and `DeepSeek-R1-Distill-Qwen-7B`, given a
      real tool schema, fabricated a fake result instead of calling it (confirmed via direct
      request). Only `Qwen3-VL-8B-Instruct` clears both bars, but it was only ever validated
      for vision/tool-calling, never as a general daily driver. **Decision: keep
      `Ornith-1.0-9B` + `Gemma-4-12B` on `llama-cpp-arc`, close this spike.** The
      client/tool-choice question this raised (what pairs well with OVMS for lighter task
      profiles) moved to its own project:
      [`llm-tooling-landscape`](https://github.com/jmsirvent/llm-tooling-landscape).

## Ideas

- [ ] **Close the Llama-3.1-8B-Instruct / Gemma-4-12B / Ornith-1.0-9B coverage gap** —
      none has a trusted pre-converted `OpenVINO/*-int4-ov` model (`Llama-3.1`/`Gemma-4-12B`:
      only unverified community conversions; `Ornith`: no conversion anywhere). This is the
      #1 reason the production decision above didn't move to OVMS — revisit if a trusted
      quantizer publishes one, or if `Ornith`'s publisher does an OpenVINO release.
