---
name: ollama-pull
description: Descarga un modelo Ollama en el contenedor IPEX-LLM, verifica espacio disponible y confirma que el modelo responde por la API
disable-model-invocation: true
---

Arguments: model name with optional tag (e.g. `qwen3:8b`, `llama3.2:3b`, `qwen2.5-coder:7b-instruct-q4_k_m`)

## Pre-checks

1. **Container running?**
   ```
   docker inspect ipex-llm --format '{{.State.Status}}' 2>/dev/null
   ```
   If not running → stop and tell user: `docker compose -f ~/llm/ipex-llm/docker-compose.yml up -d`

2. **Disk space** (models live in `~/.ollama/models`):
   ```
   df -h ~/.ollama/models
   ```
   Warn if less than 10 GB free.

3. **Model already present?**
   ```
   curl -s http://localhost:11434/api/tags | python3 -c "import sys,json; models=[m['name'] for m in json.load(sys.stdin).get('models',[])]; print('Already loaded' if any('<MODEL>' in m for m in models) else 'Not present')"
   ```

## Pull

```
docker exec ipex-llm ollama/ollama pull <model>
```

Note: the binary is at `ollama/ollama` inside the container, not in PATH. This streams progress. Wait for completion.

## Verify

```
curl -s -X POST http://localhost:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"model":"<model>","prompt":"Say OK","stream":false}' | python3 -c "import sys,json; r=json.load(sys.stdin); print('✓ Model responds:', r.get('response','').strip()[:80])"
```

## Report

- Model name and size pulled
- Time taken (approximate)
- Confirmation that model responds via API
- Reminder: to use with Continue.dev or Open WebUI, just select the model — it appears automatically once loaded.
