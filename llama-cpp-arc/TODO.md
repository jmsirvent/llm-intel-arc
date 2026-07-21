# TODO — llama-cpp-arc

Stack-specific items for the llama.cpp native SYCL build on Intel Arc 140V.

## Bugs

- [ ] **`SYCL_CACHE_PERSISTENT=1` crashes on first kernel dispatch** — `intel/llvm#21972`

  **Status:** confirmed upstream bug, no fix as of 2026-06-30.

  **Symptom:** SIGSEGV in `PersistentDeviceCodeCache::getItemFromDisc` →
  `getSortedImages` → `strcmp(null)` on first SYCL kernel dispatch (`ggml_sycl_add`).
  The sort comparator calls `strcmp(A->GetName(), B->GetName())` without null-guarding;
  `GetName()` returns NULL for dynamically-linked kernels (llama.cpp's SYCL backend).
  Not related to `GGML_SYCL_SUPPORT_LEVEL_ZERO_API` — validated with `=ON` (default).

  **Affected versions:** oneAPI DPC++ ≥ 2025.3.x (libsycl.so.9). Last known-good: 2025.2.1.

  **Workaround:** `SYCL_CACHE_PERSISTENT=0` — disables the disk-cache lookup path.
  Cost: 2–5 min of SYCL kernel JIT on every server cold start. Inference speed unaffected.

  **To fix when Intel patches the bug:**
  1. Update oneAPI: `sudo apt upgrade intel-oneapi-dpcpp-cpp-<version>`
  2. Set `SYCL_CACHE_PERSISTENT=1` in `start-server.sh` and §6.1 of the guide
  3. Delete stale cache if needed: `rm -rf ~/.cache/libsycl_cache/ ~/.cache/neo_compiler_cache/`

  **References:** [intel/llvm#21972](https://github.com/intel/llvm/issues/21972) ·
  [ggml-org/llama.cpp#21474](https://github.com/ggml-org/llama.cpp/issues/21474)

## Improvements

- [x] **Benchmark llama.cpp SYCL vs IPEX-LLM baseline** — done. Full comparison table
      in the guide's §8.3 and `README.md` §"Performance", covering the full model
      catalog (Q4\_K\_M, CTX=8192). Mixed result vs IPEX-LLM: generation tok/s roughly
      matches or beats it on most models, but prefill lags behind — open as its own
      tracked TODO below (no equivalent Xe-specific Flash Attention kernel upstream yet).

- [x] **Vulkan backend A/B spike** — done 2026-07-02. Built cleanly (`build-vulkan/`,
      SYCL `build/` untouched), GPU detected correctly, but Qwen3-8B-Q4_K_M benchmark
      showed Vulkan -35% prefill / -55% generation vs the SYCL baseline. **Not a
      viable candidate** — no promotion to the main guide planned. Full record in
      `vulkan-spike-notes.md`. Part of the wider inference-engine evaluation — see
      `~/llm/README.md` §"Inference engine landscape" and the
      `project-vllm-arc-evaluation` memory.

- [x] **Validate speculative decoding** — done. Tested draft-model pairs (Qwen2.5-Coder
      7B↔14B, Qwen3 8B↔14B, Gemma-4 MTP heads, Gemma-4-E2B as a separate draft). **Verdict:
      not viable on this hardware** — even the best pair (Qwen3, 64% acceptance) regresses
      throughput 38%. Structural cause: Arc 140V shares LPDDR5x bandwidth between CPU/GPU,
      so a draft's second forward pass competes for the same constrained bandwidth that
      already limits single-model generation. Full record in the guide's §8.4.

- [ ] **Close the SYCL prefill gap vs IPEX-LLM** — e.g. qwen3-8b: 323 vs 522 tok/s.
      IPEX-LLM shipped Intel-patched Xe-specific Flash Attention kernels never upstreamed
      into llama.cpp; the current SYCL backend has no equivalent. **Reopen when:** upstream
      llama.cpp merges improved SYCL FA kernels for Xe2, or a new oneAPI release changes SYCL
      FA performance — re-run the guide's §8.3 benchmark against the IPEX-LLM baseline then.
      **Real-world stakes confirmed 2026-07-21:** live Hermes Agent + Ornith-1.0-9b usage
      showed prefill degrading from ~177 to ~50 tok/s within a single 24.4K-token agentic
      prompt (317s total, before any response token) — the `-p 512` benchmark only shows
      the fast early part of this curve. Any client that grows context turn-over-turn
      (agentic loops, persistent memory) gets progressively slower per turn, not a flat
      cost. Full curve in the guide's §8.3 "Flash Attention validation" section.

## Ideas

- [ ] **Enable persistent SYCL cache** once `intel/llvm#21972` is fixed — reduces cold
      start from 2–5 min to near-instantaneous.

- [x] **Spike Gemma-4-26B-A4B** — done 2026-07-21. **Rejected**: same memory-ceiling
      failure as Qwen3.6-27B (swap 7.8/8 GiB before the load even finished) — MoE's
      active-parameter advantage only helps decode speed, not resident memory. Full
      record in the guide's §7.3 and the `project-model-catalog-candidates` memory.
