# TODO — IPEX-LLM Stack (Intel Arc 140V)

## Ideas

Integraciones opcionales como ficheros `docker-compose.<nombre>.yml` independientes,
conectadas a la API Ollama en `localhost:11434`.

- [ ] **Anything-LLM** — RAG sobre documentos locales (PDFs, Notion, GitHub) sin escribir código.
      Variable: `OLLAMA_BASE_PATH=http://host-gateway:11434` · Puerto: 3001
- [ ] **n8n** — automatizaciones con nodo AI Agent apuntando a la API local.
      Variable: nodo OpenAI con URL custom · Puerto: 5678
- [ ] **Flowise** — visual builder de pipelines LangChain/LlamaIndex.
      Variable: configurado en UI · Puerto: 3001
- [ ] **LibreChat** — chat multi-modelo con herramientas, plugins y memoria persistente.
      Variable: `OLLAMA_BASE_URL` · Puerto: 3080
- [ ] **Perplexica** — búsqueda web aumentada con LLM local (alternativa a Perplexity).
      Variable: `ollamaApiUrl` en config · Puerto: 3001
- [ ] **Hollama** — UI minimalista para Ollama (~10 MB imagen), como alternativa ligera a Open WebUI.
      Variable: `OLLAMA_HOST` · Puerto: 4173

## Mejoras

Ítems identificados en el audit de `local-llm-yoga-slim7-ubuntu2404.md` pendientes de aplicar:

- [x] **§1 diagrama de arquitectura** — eliminar referencias a "OpenCode / Continue.dev" (sustituido por
      guía genérica VS Code en §8.1)
- [x] **§2.1 y §10** — corregir `card0` → `card1` (el sistema tiene `card1` + `renderD128`)
- [x] **§8.1 tabla de modelos** — añadir nota de legacy a `qwen2.5:14b-instruct-q4_K_M`
      o sustituir por `qwen3:8b` / `gemma3:12b`
- [x] **§10 "Verificar que la inferencia usa GPU"** — reemplazar `sudo intel_gpu_top` por
      `xpu-smi dump -d 0 -m 0,5,18 -i 1` (intel_gpu_top no funciona con driver `xe`)
- [x] **Documentar `docker compose pull`** — añadir instrucción para actualizar la imagen
      del contenedor IPEX-LLM en la sección de mantenimiento
- [ ] **Validar `OLLAMA_KV_CACHE_TYPE: q8_0`** — verificar soporte en la build actual de
      IPEX-LLM y activar si funciona (reduce ~50% el KV cache con impacto mínimo en calidad)
- [ ] **Verificar persistencia caché SYCL** — hacer `docker compose down && up` y medir
      tiempo de arranque para confirmar que los volúmenes `neo_compiler_cache` / `libsycl_cache`
      evitan la recompilación

## Bugs

- [ ] *(ninguno conocido actualmente)*
