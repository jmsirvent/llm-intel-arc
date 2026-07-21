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
      - [ ] OpenVINO Model Server (OVMS) — not started. **Next step** — only remaining
            active-spike candidate; strongest documented Xe2 support of all candidates
            found.
      - Parked/monitored, no action: `vllm-openvino` (low activity, no tagged releases),
        `llm-scaler` (Intel excludes client/iGPU hardware for now; watch — open PRs as of
        2026-07-21 add Lunar Lake iGPU compatibility work, no stable release yet).

## Improvements

- *(none pending)*

## Bugs

- *(none known)*
