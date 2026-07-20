# TODO — llm-intel-arc monorepo

Cross-stack ideas, improvements and bugs (not specific to any single sub-stack).
For stack-specific items see the `TODO.md` inside each subdirectory.

## Ideas

- [ ] **Evaluate vLLM / alternative inference engines** — in progress, not started. Full
      landscape and rationale per candidate in `README.md` §"Inference engine landscape".
      - [x] llama.cpp Vulkan backend — spiked 2026-07-02, **ruled out** (-35% prefill /
            -55% generation vs the SYCL baseline). Full record in
            `llama-cpp-arc/vulkan-spike-notes.md`.
      - [ ] OpenVINO Model Server (OVMS) — not started. First-party Xe2 support, already
            OpenAI-compatible. **Next step, validate this first** (lowest validation cost
            of the remaining candidates).
      - [ ] Native Ollama SYCL (v0.17+, independent of the archived IPEX-LLM fork) —
            not started.
      - Parked/monitored, no action: `vllm-openvino` (low activity, no tagged releases),
        `llm-scaler` (Intel excludes client/iGPU hardware for now).

## Improvements

- *(none pending)*

## Bugs

- *(none known)*
