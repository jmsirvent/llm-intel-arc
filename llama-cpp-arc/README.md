# llama.cpp native SYCL — Intel Arc 140V (Yoga Slim 7)
**Ubuntu 24.04 LTS · Intel Core Ultra 7 258V · Intel Arc 140V (Xe2) · 32 GB LPDDR5X**

Successor to `../ipex-llm/` — llama.cpp upstream compiled with `GGML_SYCL=ON`, no Docker.

---

## Why this stack

`intel/ipex-llm` was archived in January 2026 with unresolved security issues and its Docker image frozen, with no support for new models or features like speculative decoding. This project uses llama.cpp upstream directly, compiled with Intel oneAPI's native SYCL backend.

What you gain over the previous stack:

- **Speculative decoding** (draft model) — potential +50–150% on generation throughput
- **IQ quantizations** (IQ4\_XS, IQ3\_M) — better quality per GB than K\_M
- **Up-to-date models** with llama.cpp upstream
- **Continuous security patches**

## Architecture

```
VS Code (Twinny / Cline / Roo Code) · Open WebUI · Python scripts
                     │
                     │  OpenAI-compatible REST  (localhost:8080)
                     ▼
            llama-server  (llama.cpp SYCL)
                     │
                     │  SYCL / Level Zero
                     ▼
          Intel Arc 140V  (Xe2, driver xe)
          ──────────────────────────────────
          LPDDR5X-8533  ·  32 GB  unified memory
```

## Project status

> Sections pending validation are marked with ⚠️ in the full guide.

| Phase | Status |
|---|---|
| Level Zero / xe driver | ✅ Validated (inherited from IPEX-LLM) |
| oneAPI — icx/icpx + MKL | ✅ Validated |
| llama.cpp SYCL build | ✅ Validated |
| llama-server validated on Arc 140V | ✅ Validated |
| Benchmarks vs IPEX-LLM | ⏳ Pending |
| Speculative decoding | ⏳ Pending |

## Quick start (once built)

```bash
# 1. Activate oneAPI environment
source /opt/intel/oneapi/setvars.sh

# 2. Start the server (adjust model path)
./build/bin/llama-server \
  -m models/qwen2.5-coder-14b-instruct-q4_k_m.gguf \
  --port 8080 \
  --n-gpu-layers 999 \
  --ctx-size 8192

# 3. Verify
curl http://localhost:8080/health
```

## Performance baseline — reference to beat

Measured with IPEX-LLM + Flash Attention on the same hardware, Q4\_K\_M, CTX=8192:

| Model | Gen tok/s | Prefill tok/s | TTFT ms |
|---|---|---|---|
| qwen2.5-coder:7b | 20.0 | 814 | 56 ms |
| qwen3:8b | 18.1 | 522 | 62 ms |
| llama3.1:8b-instruct | 18.9 | 429 | 56 ms |
| gemma3:12b | 10.5 | 240 | 100 ms |
| qwen2.5:14b-instruct | 10.7 | 451 | 100 ms |

## Full documentation

→ **[local-llm-yoga-slim7-ubuntu2404-llamacpp.md](local-llm-yoga-slim7-ubuntu2404-llamacpp.md)**

Covers: prerequisites, Level Zero and oneAPI installation, llama.cpp build, server configuration, recommended models, VS Code integration, systemd, OS tuning, and troubleshooting.
