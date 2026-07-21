# llm-intel-arc

Local LLM inference on Intel Arc 140V (Xe2) — Lenovo Yoga Slim 7, Ubuntu 24.04 LTS.

## Hardware

| Component | Spec |
|---|---|
| CPU | Intel Core Ultra 7 258V (Lunar Lake) |
| iGPU | Intel Arc 140V (Xe2, 8 Xe-cores) |
| RAM | 32 GB LPDDR5X-8533 (unified CPU+GPU memory) |
| OS | Ubuntu 24.04 LTS |
| Kernel driver | `xe` (NOT `i915` — Xe2 uses a different driver) |
| Compute stack | Level Zero → SYCL (oneAPI) |

## Projects

| Directory | Stack | Status |
|---|---|---|
| [`ipex-llm/`](ipex-llm/) | IPEX-LLM — Ollama SYCL fork, Docker | Production, frozen (archived upstream) |
| [`llama-cpp-arc/`](llama-cpp-arc/) | llama.cpp native SYCL (no Docker) | In development |

## Architecture decision

Native installation over Docker for local single-machine inference: direct GPU access, no passthrough, lower overhead. Docker was used with IPEX-LLM because it was the only distribution method for that stack — not by preference.

## Inference engine landscape (research snapshot, 2026-07)

Survey underpinning the `vllm-arc` evaluation tracked in `TODO.md`. The Arc 140V is a Xe2 **client iGPU** (Lunar Lake); most Intel-GPU support claims in this space target Data Center Max (Ponte Vecchio) or Arc Pro (discrete workstation) parts instead. Each entry below is evaluated against that specific distinction, not against generic "Intel GPU" support.

### Validated in production

| Engine | Status | Reference |
|---|---|---|
| llama.cpp (SYCL, `GGML_SYCL=ON`) | Production, native install | [`llama-cpp-arc/`](llama-cpp-arc/) · [SYCL backend docs](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/SYCL.md) |
| IPEX-LLM (Ollama SYCL fork) | Frozen — upstream repository archived by Intel 2026-01 (known security issues) | [`ipex-llm/`](ipex-llm/) |

### Ruled out

| Option | Rationale |
|---|---|
| vLLM upstream (XPU/IPEX backend) | Documented hardware support is limited to Arc Pro B-Series and Data Center GPU Max; the Arc 140V is not listed as validated. |
| `ipex-llm[serving]` vLLM fork | Inherits the parent project's archival status (2026-01, security); ruled out together with `ipex-llm`. |
| `llm-scaler` (Intel's proposed ipex-llm successor) | Currently covers only Arc Pro and discrete workstation GPUs; Intel states it does not yet replace ipex-llm for client/consumer GPUs or iGPUs. |
| Hugging Face TGI | Intel support is scoped to Data Center Max 1100/1550, with no documented Arc/Xe2 coverage. |
| koboldcpp / LM Studio | Both wrap the same llama.cpp SYCL/Vulkan backend already deployed natively; they add packaging overhead without new capability. |
| MLC-LLM | Advertised Arc support is not corroborated by primary documentation or independent benchmarks; only generic Vulkan support exists, unverified on Xe2. |
| llama.cpp with the Vulkan backend (`GGML_VULKAN=ON`) | Spiked 2026-07-02: builds and runs correctly on Xe2, but Qwen3-8B-Q4_K_M benchmarked at -35% prefill / -55% generation vs the existing SYCL build. Not a viable replacement or complement. Full record in [`llama-cpp-arc/vulkan-spike-notes.md`](llama-cpp-arc/vulkan-spike-notes.md). |
| Native Ollama (v0.32.1, official release) | Spiked 2026-07-21: no SYCL backend in any stable release — `ollama/ollama#11160` (SYCL support) is still open/unmerged. The only GPU path is the Vulkan backend added in 0.12.x, and it's worse than llama.cpp's own Vulkan spike on the same model (Qwen3-8B-Q4_K_M: 132.65 prefill / 8.30 gen tok/s vs llama.cpp Vulkan's 215.92 / 7.35, both far below the SYCL baseline's 323 / 15.25). Also found: Ollama drops integrated GPUs by default, needs `OLLAMA_IGPU_ENABLE=1` to even attempt Vulkan on the Arc 140V. Not a viable candidate today — revisit once the SYCL PR merges into a stable release. |

### Candidates for validation (confirmable as of July 2026)

Ready for a hands-on validation spike on this hardware, with no known documentation blocker:

| Option | Rationale | Reference |
|---|---|---|
| OpenVINO Model Server (OVMS) | First-party Intel Xe2 support, documented; exposes a native OpenAI-compatible API (`/v3/chat/completions`, `/models`) | [openvinotoolkit/model_server](https://github.com/openvinotoolkit/model_server) · [docs](https://docs.openvino.ai/2025/model-server/ovms_what_is_openvino_model_server.html) |
| `optimum-intel` with IPEX | Actively maintained by Hugging Face, with documented GPU inference support; lacks a built-in OpenAI-compatible server, requiring a custom wrapper | [huggingface/optimum-intel](https://github.com/huggingface/optimum-intel) · [docs](https://docs.openvino.ai/2025/openvino-workflow-generative/inference-with-optimum-intel.html) |

**Next step:** validate OpenVINO Model Server — the only remaining active-spike candidate (highest validation cost, but the strongest documented Xe2 support of all candidates found).

### Monitored (unconfirmed timeline)

| Option | Condition for reconsideration |
|---|---|
| `llm-scaler` for client/iGPU hardware | Intel explicitly excludes consumer GPUs (Arc A770/B580) and iGPUs from current coverage; reassess if a future release extends support. As of 2026-07-21, open PRs add Lunar Lake Xe2 iGPU compatibility reports/benchmarks and fix an iGPU-specific `profile_run()` hang — first concrete signal of movement, but no stable release with confirmed iGPU support yet. |
| `vllm-openvino` | Deprioritized: no confirmed documentation blocker, but the repository shows low activity and no tagged releases. Candidates with stronger prospects are being validated first. Reassess if it gains releases and adoption, or if the prioritized candidates fail validation. |

## GPU monitoring

```bash
sudo xpu-smi dump -d 0 -m 0,5,18 -i 1   # utilization, VRAM, power (sudo needed for engines)
xpu-smi stats -d 0                        # point-in-time: frequency, temperature, memory
```

`intel_gpu_top` does not work — it relies on the `i915` PMU, which is absent with the `xe` driver.

## GPU driver install

Use `ppa:kobuk-team/intel-graphics` (successor to the discontinued `ubuntu-oem/intel-graphics-preview`). The official Intel repo (`repositories.intel.com`) provides Level Zero 1.21.x — too old for Xe2/Lunar Lake.
