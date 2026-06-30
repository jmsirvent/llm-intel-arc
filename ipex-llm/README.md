# ipex-llm-arc

Local LLM inference on **Intel Arc 140V (Xe2)** using [IPEX-LLM](https://github.com/intel-analytics/ipex-llm) — Intel's optimized fork of Ollama with native SYCL/Level Zero GPU support.

![Platform](https://img.shields.io/badge/platform-Intel%20Arc%20140V%20%28Xe2%29-blue)
![Runtime](https://img.shields.io/badge/runtime-IPEX--LLM%20%2B%20Ollama-orange)
![OS](https://img.shields.io/badge/OS-Ubuntu%2024.04-purple)

---

## Why IPEX-LLM instead of standard Ollama

Standard Ollama has no Intel Arc GPU support on Linux — it silently falls back to CPU-only (~9 tok/s). IPEX-LLM patches Ollama to use the native SYCL/Level Zero stack, achieving **~18–20 tok/s** on a 7–8B Q4 model: roughly 2× CPU throughput.

---

## Hardware

| Component | Detail |
|-----------|--------|
| CPU | Intel Core Ultra 7 258V (Lunar Lake, 8 cores) |
| GPU | Intel Arc 140V (Xe2 iGPU, 8 Xe2 cores, driver: `xe`) |
| NPU | Intel AI Boost / Lunar Lake NPU |
| RAM | 32 GB LPDDR5X-8533 unified (CPU + GPU + NPU shared pool, ~97 GB/s) |
| OS | Ubuntu 24.04 LTS, kernel 6.19 |

---

## Quick start

```bash
# Start the stack
docker compose up -d

# Verify the API is up (wait ~60s on first boot for SYCL kernel compilation)
curl http://localhost:11434/api/tags

# Pull a model
docker exec ipex-llm ollama/ollama pull qwen3:8b
```

> **Note:** the Ollama binary lives at `ollama/ollama` inside the container — it is not in `$PATH`.

The service exposes an **OpenAI-compatible REST API** on `localhost:11434`, compatible with Continue.dev, Open WebUI, and any OpenAI SDK client.

---

## Models

| Model | RAM | tok/s | Use case |
|-------|-----|-------|----------|
| `qwen3:8b` Q4_K_M | 5.2 GB | ~18–20 | Chat, RAG (fast) |
| `gemma3:12b` Q4_K_M | 8.1 GB | ~13–16 | RAG, summarization, invoice vision |
| `qwen2.5-coder:7b-instruct-q4_K_M` | 4.7 GB | ~20–22 | Coding assistant |
| `qwen2.5:14b-instruct-q4_K_M` | 8.7 GB | ~12–14 | Structured output, document analysis |

All models fit comfortably within the 26 GB container memory limit. Running two simultaneously is the typical operating mode (coding + chat).

---

## Claude Code integration

This repo includes Claude Code skills and project settings:

| Command | Description |
|---------|-------------|
| `/llm-status` | Container health, API status, loaded models, memory usage |
| `/ollama-pull <model>` | Pull a model with pre-flight checks (disk space, container state) and post-pull API verification |

MCP servers (`ollama-mcp`, `docker`) are configured in `.claude/settings.json` and activate automatically when opening this project in Claude Code.

---

## Full setup guide

Step-by-step installation — Docker, Intel GPU drivers (Canonical PPA for Xe2), IPEX-LLM, model management, Continue.dev/Open WebUI integration, NPU backend, and troubleshooting:

→ [`local-llm-yoga-slim7-ubuntu2404.md`](local-llm-yoga-slim7-ubuntu2404.md)

---

## Key gotchas

- **Intel GPU drivers:** the official Intel repo (`repositories.intel.com`) does not ship Xe2-compatible packages for Ubuntu 24.04 Noble. Use `ppa:ubuntu-oem/intel-graphics-preview` ([source](https://github.com/canonical/intel-graphics-preview)).
- **First boot:** IPEX-LLM compiles SYCL kernels on first model load — takes 2–5 min, fully cached on subsequent runs.
- **Context window:** default is 8K (`OLLAMA_NUM_CTX=8192`). Pass `num_ctx` per-request for RAG or long-context workloads (16K–32K).
