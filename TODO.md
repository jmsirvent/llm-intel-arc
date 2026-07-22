# TODO — llm-intel-arc monorepo

Cross-stack ideas, improvements and bugs (not specific to any single sub-stack).
For stack-specific items see the `TODO.md` inside each subdirectory.

## Ideas

- [ ] **Evaluate vLLM / alternative inference engines** — in progress, not started. Full
      landscape and rationale per candidate in `README.md` §"Inference engine landscape".
      - [x] llama.cpp Vulkan backend — spiked 2026-07-02, **ruled out** (-35% prefill /
            -55% generation vs the SYCL baseline). Full record in
            `llama-cpp-arc/vulkan-spike-notes.md`.
      - [x] Native Ollama — spiked 2026-07-21, **ruled out**. No SYCL backend in any
            stable release (`ollama/ollama#11160` still open/unmerged); only Vulkan
            available (added 0.12.x), and it underperforms even llama.cpp's own Vulkan
            spike (Qwen3-8B-Q4_K_M: 132.65 prefill / 8.30 gen tok/s vs 215.92 / 7.35,
            both far below the SYCL baseline's 323 / 15.25). Also drops integrated GPUs
            by default (`OLLAMA_IGPU_ENABLE=1` required). Full record in `README.md`
            §"Inference engine landscape" and the `project-vllm-arc-evaluation` memory.
            Revisit once the SYCL PR merges into a stable release.
      - [x] OpenVINO Model Server (OVMS) — spike **closed 2026-07-22, decision: stay on
            `llama-cpp-arc`.** Not a performance verdict — OVMS won every raw metric tested:
            prefill beats SYCL unconditionally (+114% to +350%, all 6 non-multimodal catalog
            models), generation mostly ahead (+9-13% typical, Qwen3-8B +42% outlier,
            Phi-4-mini −5.7% regression), quality battery a wash, and long-context/multi-turn
            behavior (`context-test.sh`) resolves SYCL's exact per-turn-slowdown pain point
            (marginal rate flat to ~22K tokens with prefix caching; even OVMS's cold worst
            case beats SYCL's best case). **Decided against switching anyway**, on a
            Hermes-fit check run last: `Ornith-1.0-9B` (production default) and `Gemma-4-12B`
            (production vision/tool-calling model) have no OVMS conversion; Hermes
            hard-requires ≥64K context, which rules out `Qwen3-8B/14B` and both
            `Qwen2.5-Coder` sizes; of what's left, `Qwen2.5-VL` has no tool parser and
            `DeepSeek-R1-Distill-Qwen-7B` fabricates fake results instead of calling tools.
            `llama-cpp-arc/` resumes as the settled production backend, no longer "paused
            pending evaluation." Whole Gemma-4 family also independently blocked by an
            upstream bug ([model_server#4178](https://github.com/openvinotoolkit/model_server/issues/4178)).
            The client/tool-choice question this raised (what should pair with OVMS, or any
            future backend, for lighter task profiles) moved to its own project:
            [`llm-tooling-landscape`](https://github.com/jmsirvent/llm-tooling-landscape).
            Full rationale: [`ovms-arc/README.md`](ovms-arc/README.md) ·
            [`ovms-arc/CLAUDE.md`](ovms-arc/CLAUDE.md) ·
            [`ovms-arc/TODO.md`](ovms-arc/TODO.md).
      - Parked/monitored, no action: `vllm-openvino` (low activity, no tagged releases),
        `llm-scaler` (Intel excludes client/iGPU hardware for now; watch — open PRs as of
        2026-07-21 add Lunar Lake iGPU compatibility work, no stable release yet).

## Improvements

- *(none pending)*

## Bugs

- *(none known)*
