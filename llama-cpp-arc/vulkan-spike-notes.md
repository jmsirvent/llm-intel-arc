# Vulkan backend A/B spike — notes

> **Provisional document.** Tracks the Vulkan-backend validation spike for llama.cpp on
> the Arc 140V, run alongside the confirmed SYCL build (`local-llm-yoga-slim7-ubuntu2404-llamacpp.md`).
> Once results are in, this content is promoted either into that guide as a new §13, or
> split into a sibling document with the same structure — decision pending outcome.
> Part of the wider inference-engine evaluation: see `~/llm/README.md` §"Inference engine
> landscape" and the `project-vllm-arc-evaluation` memory.

## Goal

Confirm whether llama.cpp's Vulkan backend (`GGML_VULKAN=ON`) is viable on this hardware
and how it compares to the SYCL build already in production, without touching the
existing SYCL build (`llama.cpp/build/`).

## Status

✅ Complete — Vulkan backend builds and runs, but is not a viable replacement for SYCL
on this hardware. No further action planned; kept for reference.

## Steps

### 1. Vulkan prerequisites

```bash
sudo apt install vulkan-tools libvulkan-dev glslang-tools
vulkaninfo --summary
```

Confirmed: Intel Arc 140V detected as `GPU0`, `deviceName = Intel(R) Graphics (LNL)`,
`driverName = Intel open-source Mesa driver`, Mesa 25.2.8, Vulkan API 1.4.318. Ubuntu
24.04's default Mesa (already at 25.2.8 on this machine, likely pulled in via
24.04.2 point-release updates) fully covers Xe2 — no extra PPA needed, unlike the
Level Zero case in the main guide §3.

**Gotcha — two extra packages beyond the ones above:**
- `glslc` is **not** included in `glslang-tools`; it ships in its own `glslc` package
  (pulls in `libshaderc1`). Without it, CMake fails with `Could NOT find Vulkan
  (missing: glslc)`.
- The CMake config file for `SPIRV-Headers` (`SPIRV-HeadersConfig.cmake`) is provided by
  the separate `spirv-headers` package, not by `libvulkan-dev` or `glslang-tools`.
  Without it, CMake fails at `ggml/src/ggml-vulkan/CMakeLists.txt:14` with
  `Could not find a package configuration file provided by "SPIRV-Headers"`.

Full working prerequisite set: `vulkan-tools libvulkan-dev glslang-tools glslc spirv-headers`.

### 2. Parallel build

```bash
cd ~/llm/llama-cpp-arc/llama.cpp
cmake -B build-vulkan -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build-vulkan --config Release -j$(nproc) --target llama-server llama-bench llama-cli
```

Configure step reported `GL_KHR_cooperative_matrix supported by glslc` — the Vulkan
backend can use cooperative-matrix instructions on this GPU. Build completed cleanly,
existing SYCL `build/` untouched.

### 3. Verify GPU detection

```bash
./build-vulkan/bin/llama-server --list-devices
```

Confirmed:
```
Available devices:
  Vulkan0: Intel(R) Graphics (LNL) (23723 MiB, 10537 MiB free)
```

### 4. Benchmark (same model/params as the SYCL baseline)

Model: `Qwen3-8B-Q4_K_M.gguf` (same model used as the SYCL reference point in the main
guide §8.3).

```bash
# SYCL (existing build/)
source /opt/intel/oneapi/setvars.sh
./build/bin/llama-bench -m ../models/Qwen3-8B-Q4_K_M.gguf -p 512 -n 128 -ngl 999 --output md

# Vulkan (build-vulkan/)
./build-vulkan/bin/llama-bench -m ../models/Qwen3-8B-Q4_K_M.gguf -p 512 -n 128 -ngl 999 --output md
```

### 5. Results

| Backend | Model | Prefill (tok/s) | Generation (tok/s) | Notes |
|---|---|---|---|---|
| SYCL | Qwen3-8B-Q4_K_M | 331.04 ± 6.18 | 16.31 ± 0.49 | baseline, existing production build |
| Vulkan | Qwen3-8B-Q4_K_M | 215.92 ± 13.90 | 7.35 ± 0.11 | `uma:1 fp16:1 matrix cores:KHR_coopmat` |
| **Δ** | | **−34.8%** | **−54.9%** | Vulkan slower on both metrics |

**Cross-architecture check** — same command, `Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf`,
to rule out a Qwen3-specific regression before drawing a general conclusion:

| Backend | Model | Prefill (tok/s) | Generation (tok/s) |
|---|---|---|---|
| SYCL | Llama-3.1-8B-Instruct-Q4_K_M | 360.55 ± 2.14 | 17.30 ± 0.77 |
| Vulkan | Llama-3.1-8B-Instruct-Q4_K_M | 154.85 ± 6.37 | 5.39 ± 0.17 |
| **Δ** | | **−57.1%** | **−68.8%** | |

The gap is not model-specific — it's as large or larger on Llama-3.1 than on Qwen3,
confirming a systematic SYCL advantage on this hardware rather than an artifact of one
model's ops.

## Conclusion

Vulkan backend runs correctly on the Arc 140V (Xe2/Lunar Lake) with no driver or build
blockers, but delivers substantially lower throughput than the existing SYCL build across
both models tested: -35%/-55% (Qwen3-8B) and -57%/-69% (Llama-3.1-8B), prefill/generation
respectively. Checking a second model architecture ruled out a Qwen3-specific regression
— the deficit is systematic, not model-dependent. This matches the mixed/negative reports
found during the landscape research (SYCL vs Vulkan parity varies a lot by Intel GPU
generation, and cooperative-matrix support alone doesn't close the gap here).

**Verdict: not a candidate to replace or complement the SYCL build.** No promotion to
the main guide (§13) or a sibling document — this file stays as the closed record of
the spike. `build-vulkan/` can be removed if disk space is needed; kept for now in case
future llama.cpp/Mesa releases change the picture (see main guide §11 for the analogous
SYCL cold-start gotcha, unrelated but same "revisit if upstream changes" pattern).
