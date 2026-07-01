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
- **GPU drivers**: use `ppa:kobuk-team/intel-graphics` (successor to the discontinued `ubuntu-oem/intel-graphics-preview`; `repositories.intel.com` provides Level Zero 1.21.x — too old for Xe2)

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

### Pending: normalize client-facing API across backends

**Status: decided, not yet implemented.** Only one inference backend runs at a time on this
machine (single GPU, shared memory — see the memory budget in `llama-cpp-arc`'s guide, §7), so
a reverse proxy is unnecessary complexity. Instead, standardize on a fixed convention so coding
clients (OpenCode, Twinny, Cline, CodeGPT) never need reconfiguring when switching backends:

- **Port `8080`** and the **OpenAI-compatible surface (`/v1`)** for every backend — IPEX-LLM/Ollama
  (currently on `11434`, would need `OLLAMA_HOST=0.0.0.0:8080`), `llama-cpp-arc` (already on `8080`
  by convention), and any future vLLM setup (`--port 8080` by default).
- Clients get configured **once** as "OpenAI Compatible, `localhost:8080`, `/v1`" and stay that way
  regardless of which backend is actually serving requests.
- **Residual friction that doesn't go away:** the `model` field differs per backend (Ollama tags
  like `qwen3:8b`, llama.cpp GGUF filenames, vLLM HF repo ids) — switching backends still means
  updating that one field per client, just not the whole connection config.
- **Cross-project scope:** implementing this touches both `ipex-llm/` (change Ollama's port) and
  `llama-cpp-arc/` (already compliant) — coordinate changes across both when this gets picked up.
