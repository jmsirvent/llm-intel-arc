# ~/llm — Local LLM Inference (Intel Arc 140V)

Shared context for all local inference projects under this directory.
Projects inherit these instructions; each has its own CLAUDE.md for stack-specific details.

## Hardware

- **Machine**: Lenovo Yoga Slim 7 — Intel Core Ultra 7 258V (Lunar Lake)
- **iGPU**: Arc 140V (Xe2, 8 Xe-cores) — shared memory with CPU (LPDDR5x)
- **Total RAM**: 32 GB LPDDR5X-8533 | ~20 GB available in daily use (OS + desktop + apps consume ~12 GB)
- **OS**: Ubuntu 24.04 LTS

## Drivers and compute stack

- **Kernel driver**: `xe` (NOT `i915` — Xe2 uses a different driver)
- **Compute stack**: Level Zero → SYCL (oneAPI) — same stack across all projects
- **GPU drivers**: use `ppa:ubuntu-oem/intel-graphics-preview` (the official Intel repo `repositories.intel.com` does NOT work for Xe2/Lunar Lake on Ubuntu 24.04)

## GPU monitoring

`intel_gpu_top` does NOT work with the `xe` driver (it uses `i915` PMU). Alternative:

```bash
sudo xpu-smi dump -d 0 -m 0,5,18 -i 1   # utilization, VRAM, power — sudo needed for engines
xpu-smi stats -d 0                        # point-in-time snapshot: frequency, temperature, memory
```

## Intel LLM ecosystem status (June 2026)

| Project | Status | Notes |
|---|---|---|
| `intel/ipex-llm` | **Archived** January 2026 | Known security issues; Docker image frozen |
| `ipex-llm/ipex-llm` | Active community fork | 139 stars, last release April 2025 — uncertain |
| `intel-oneapi-*` (apt) | **Active** | SYCL compiler (icx/icpx) + MKL available on Ubuntu 24.04 |
| `llama.cpp` upstream | **Active** | Real backend for all stacks; SYCL supported with oneAPI |

## Projects

| Directory | Stack | Status | Purpose |
|---|---|---|---|
| `ipex-llm/` | IPEX-LLM (Ollama SYCL fork, Docker) | Production, frozen | Current functional stack |
| `llama-cpp-arc/` | llama.cpp native SYCL (no Docker) | In development | Future stack — access to upstream features (speculative decoding, IQ quants, new models) |

## Architecture decision

Projects under `~/llm/` prioritize **native installation over Docker** for local single-machine inference:
- Direct GPU access without passthrough or device mapping
- Lower management overhead
- Docker was used with IPEX-LLM because it was the only way to distribute that stack — not by preference
