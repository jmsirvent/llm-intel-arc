# IPEX-LLM — Local LLM Inference (Intel Arc 140V)

## Stack
- **IPEX-LLM**: fork Intel de Ollama con soporte nativo SYCL/Level Zero para GPU Intel Arc (no es Ollama estándar — Ollama nativo cae a CPU-only en Linux)
- **API**: OpenAI-compatible REST en `localhost:11434`
- **Container**: `ipex-llm` (docker compose) — configuración en `docker-compose.yml` (único fichero de config del stack)
- **Docs**: `local-llm-yoga-slim7-ubuntu2404.md` (symlink a Dropbox)

## Comandos clave
- `docker compose up -d` — arrancar el stack (primer arranque post-reboot: ~60s para compilar kernels SYCL)
- `docker compose logs -f` — seguir logs del contenedor
- `curl http://localhost:11434/api/tags` — listar modelos cargados
- `docker exec ipex-llm ollama/ollama pull <modelo>` — descargar modelo (binario en `ollama/ollama`, no en PATH)
- `./modelfiles/apply.sh` — re-aplicar todos los Modelfiles tras editar parámetros o recrear el contenedor

## Claude Code — skills disponibles
- `/llm-status` — diagnóstico completo: estado contenedor, API, modelos, memoria
- `/ollama-pull <modelo>` — descargar modelo con verificación de espacio y test de respuesta

## MCP servers (proyecto)
- `ollama-mcp` — interactúa con la API Ollama local
- `docker` — gestiona el contenedor desde Claude

## Gotchas
- Si el contenedor no está corriendo, la API no responde — verificar siempre con `/llm-status` antes de diagnosticar otros problemas
- El hook PostToolUse valida `docker-compose.yml` automáticamente tras cada edición — activo en `.claude/settings.json` (matcher `Edit|Write`)
- **Drivers Xe2**: el repo oficial de Intel (`repositories.intel.com`) NO funciona para Lunar Lake en Ubuntu 24.04 — usar `ppa:ubuntu-oem/intel-graphics-preview` (fuente: https://github.com/canonical/intel-graphics-preview)
- **Monitorización GPU**: `intel_gpu_top` no funciona — Arc 140V usa driver `xe`, no `i915` (PMU). Usar `xpu-smi dump -d 0 -m 0,5,18 -i 1` (con sudo para utilización de engines). Ver sección 7.3 del doc.
- **Modelfiles — stdin no funciona**: `ollama create <model> -f -` falla en IPEX-LLM con "no Modelfile found". Usar siempre `docker cp <fichero> ipex-llm:/tmp/current.Modelfile && docker exec ipex-llm /llm/ollama/ollama create <model> -f /tmp/current.Modelfile`. El script `./modelfiles/apply.sh` ya implementa este patrón.
- **`PARAMETER think` no soportado**: en Modelfiles de IPEX-LLM, `PARAMETER think false` falla. Para desactivar el thinking de qwen3, pasar `"think": false` en el payload de la API o configurarlo en el cliente (Open WebUI, etc.).
