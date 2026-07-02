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

- [ ] **Benchmark llama.cpp SYCL vs IPEX-LLM baseline** — run `llama-bench` on the
      same models and context sizes used in the IPEX-LLM baseline (Q4\_K\_M, CTX=8192).
      Target: beat or match the numbers in `../README.md`.

- [x] **Vulkan backend A/B spike** — done 2026-07-02. Built cleanly (`build-vulkan/`,
      SYCL `build/` untouched), GPU detected correctly, but Qwen3-8B-Q4_K_M benchmark
      showed Vulkan -35% prefill / -55% generation vs the SYCL baseline. **Not a
      viable candidate** — no promotion to the main guide planned. Full record in
      `vulkan-spike-notes.md`. Part of the wider inference-engine evaluation — see
      `~/llm/README.md` §"Inference engine landscape" and the
      `project-vllm-arc-evaluation` memory.

- [ ] **Validate speculative decoding** — test draft model setup once the server is stable.

## Ideas

- [ ] **Enable persistent SYCL cache** once `intel/llvm#21972` is fixed — reduces cold
      start from 2–5 min to near-instantaneous.
