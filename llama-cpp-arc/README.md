# llama.cpp SYCL nativo — Intel Arc 140V (Yoga Slim 7)
**Ubuntu 24.04 LTS · Intel Core Ultra 7 258V · Intel Arc 140V (Xe2) · 32 GB LPDDR5X**

Sucesor de `../ipex-llm/` — llama.cpp upstream compilado con `GGML_SYCL=ON`, sin Docker.

---

## Por qué este stack

`intel/ipex-llm` fue archivado en enero 2026 con security issues sin resolver y su imagen Docker congelada, sin soporte para modelos nuevos ni features como speculative decoding. Este proyecto usa llama.cpp upstream directamente, compilado con el backend SYCL nativo de Intel oneAPI.

Lo que se gana frente al stack anterior:

- **Speculative decoding** (draft model) — potencial +50–150 % en generación
- **IQ quantizations** (IQ4\_XS, IQ3\_M) — mejor calidad por GB que K\_M
- **Modelos al día** con llama.cpp upstream
- **Security patches** continuos

## Arquitectura

```
VS Code (Twinny / Cline / Roo Code) · Open WebUI · Scripts Python
                     │
                     │  OpenAI-compatible REST  (localhost:8080)
                     ▼
            llama-server  (llama.cpp SYCL)
                     │
                     │  SYCL / Level Zero
                     ▼
          Intel Arc 140V  (Xe2, driver xe)
          ──────────────────────────────────
          LPDDR5X-8533  ·  32 GB  unificada
```

## Estado del proyecto

> Las secciones pendientes de validación están marcadas con ⚠️ en la guía completa.

| Fase | Estado |
|---|---|
| Level Zero / driver xe | ✅ Validado (heredado de IPEX-LLM) |
| oneAPI — icx/icpx + MKL | ⏳ Pendiente |
| llama.cpp compilación SYCL | ⏳ Pendiente |
| llama-server validado en Arc 140V | ⏳ Pendiente |
| Benchmarks vs IPEX-LLM | ⏳ Pendiente |
| Speculative decoding | ⏳ Pendiente |

## Quick start (una vez compilado)

```bash
# 1. Activar entorno oneAPI
source /opt/intel/oneapi/setvars.sh

# 2. Arrancar el servidor (ajustar ruta al modelo)
./build/bin/llama-server \
  -m models/qwen2.5-coder-14b-instruct-q4_k_m.gguf \
  --port 8080 \
  --n-gpu-layers 999 \
  --ctx-size 8192

# 3. Verificar
curl http://localhost:8080/health
```

## Línea base de rendimiento — referencia a superar

Medido con IPEX-LLM + Flash Attention en el mismo hardware, Q4\_K\_M, CTX=8192:

| Modelo | Gen tok/s | Prefill tok/s | TTFT ms |
|---|---|---|---|
| qwen2.5-coder:7b | 20.0 | 814 | 56 ms |
| qwen3:8b | 18.1 | 522 | 62 ms |
| llama3.1:8b-instruct | 18.9 | 429 | 56 ms |
| gemma3:12b | 10.5 | 240 | 100 ms |
| qwen2.5:14b-instruct | 10.7 | 451 | 100 ms |

## Documentación completa

→ **[local-llm-yoga-slim7-ubuntu2404-llamacpp.md](local-llm-yoga-slim7-ubuntu2404-llamacpp.md)**

Incluye: prerequisitos, instalación de Level Zero y oneAPI, compilación de llama.cpp,
configuración del servidor, modelos recomendados, integración con VS Code, systemd,
tuning de SO y troubleshooting.
