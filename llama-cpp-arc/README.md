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

**Settled as the production backend (2026-07-22).** The OVMS evaluation (`../ovms-arc/`)
closed without a switch — OVMS won on raw performance, but this stack's production models
(`Ornith-1.0-9B`, `Gemma-4-12B`) have no OVMS conversion, and Hermes Agent's own
context-window requirement ruled out the OVMS-covered alternatives. Full rationale:
`../ovms-arc/CLAUDE.md`.

**Development still separately paused (since 2026-07-21) — waiting on upstream.** No
further spikes or feature work planned here until upstream llama.cpp changes something
worth re-validating (SYCL cache-crash fix, Xe2 Flash Attention kernels, etc. — see
`TODO.md` for the specific reopen triggers already tracked per item). Production use
(Hermes Agent, VS Code clients) is unaffected either way.

> Sections pending validation are marked with ⚠️ in the full guide.

| Phase | Status |
|---|---|
| Level Zero / xe driver | ✅ Validated (inherited from IPEX-LLM) |
| oneAPI — icx/icpx + MKL | ✅ Validated |
| llama.cpp SYCL build | ✅ Validated |
| llama-server validated on Arc 140V | ✅ Validated |
| Benchmarks vs IPEX-LLM | ✅ Validated (prefill gap on some models remains open — §8.3) |
| Speculative decoding | ✅ Validated — not viable on this hardware (§8.4) |
| VS Code client integration (Twinny/Cline) | ✅ Validated |

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

## Performance — llama.cpp SYCL (Arc 140V, `-p 512 -n 128 -ngl 999`, no Flash Attention)

| Model | Quant | Gen tok/s | Prefill tok/s |
|---|---|---|---|
| phi4-mini | Q4\_K\_M | **33.97** | **819** |
| gemma4-e4b | Q4\_K\_M | **26.73** | **617** |
| deepseek-r1-distill-qwen-7b | Q4\_K\_M | **20.93** | **525** |
| qwen2.5-coder-7b | Q4\_K\_M | **19.42** | **479** |
| llama3.1-8b-instruct | Q4\_K\_M | **18.87** | **358** |
| qwen3-8b | Q4\_K\_M | **15.25** | **323** |
| gemma4-12b | UD-Q4\_K\_XL | **11.95** | **284** |
| ornith-1.0-9b | Q6\_K | **10.20** | **330** |
| qwen3-14b *(optional)* | Q4\_K\_M | **10.09** | **225** |
| qwen2.5-coder-14b | Q4\_K\_M | **9.92** | **227** |

**Evaluated and rejected:** Bonsai 27B (PrismML), `Q1_0` 1-bit variant — 4.36 tok/s
generation, worse than every model above despite a 3.53 GiB footprint. SYCL kernel
support exists ([llama.cpp#24721](https://github.com/ggml-org/llama.cpp/pull/24721)) but
is correctness-only, with no decode-optimized path yet. Qwen3.6-27B dense, `Q4_K_M`
(15.65 GiB) — 5.22 tok/s generation, roughly half of `qwen3-14b`; a memory-ceiling failure
(swap-bound decode), not a kernel one — this machine's ~11-12 GB OS baseline leaves too
little headroom for dense models above ~10-12 GB disk size. Also surfaced a separate
`xe` driver hang when two model-loading processes ran concurrently — never load two models
at once on this hardware. Full rationale in
[local-llm-yoga-slim7-ubuntu2404-llamacpp.md §7.3](local-llm-yoga-slim7-ubuntu2404-llamacpp.md#73-evaluated-and-rejected-models).
**Gemma-4-26B-A4B** (MoE, 256K native context, 16.9 GiB) — also rejected: same memory-ceiling
failure as Qwen3.6-27B, confirmed before the load even finished (swap 7.8/8 GiB). MoE's
active-parameter advantage only helps decode speed, not resident memory — same §7.3.

**Context window:** `--ctx-size` past a model's native training window clamps silently
instead of erroring. Verified per catalog model at 65536 and 131072 — only the three Gemma-4
models (E2B/E4B/12B) serve 131072 safely; the whole Qwen2.5-Coder/Qwen3 line clamps well
below 64K without YaRN. Full table and per-model memory readings in
[local-llm-yoga-slim7-ubuntu2404-llamacpp.md §7.1](local-llm-yoga-slim7-ubuntu2404-llamacpp.md#71-recommended-models-ggufs-from-hugging-face).

## IPEX-LLM baseline (previous stack, Flash Attention on, Q4\_K\_M)

| Model | Gen tok/s | Prefill tok/s | TTFT ms |
|---|---|---|---|
| qwen2.5-coder:7b | 20.0 | 814 | 56 ms |
| qwen3:8b | 18.1 | 522 | 62 ms |
| llama3.1:8b-instruct | 18.9 | 429 | 56 ms |
| gemma3:12b | 10.5 | 240 | 100 ms |
| qwen2.5:14b-instruct | 10.7 | 451 | 100 ms |

## Full documentation

→ **[local-llm-yoga-slim7-ubuntu2404-llamacpp.md](local-llm-yoga-slim7-ubuntu2404-llamacpp.md)**

Covers: prerequisites, Level Zero and oneAPI installation, llama.cpp build, server configuration, recommended models, VS Code integration, OS tuning, and troubleshooting.
