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

## GPU monitoring

```bash
sudo xpu-smi dump -d 0 -m 0,5,18 -i 1   # utilization, VRAM, power (sudo needed for engines)
xpu-smi stats -d 0                        # point-in-time: frequency, temperature, memory
```

`intel_gpu_top` does not work — it relies on the `i915` PMU, which is absent with the `xe` driver.

## GPU driver install

Use `ppa:kobuk-team/intel-graphics` (successor to the discontinued `ubuntu-oem/intel-graphics-preview`). The official Intel repo (`repositories.intel.com`) provides Level Zero 1.21.x — too old for Xe2/Lunar Lake.
