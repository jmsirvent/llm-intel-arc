---
name: llm-status
description: Diagnóstico completo del stack IPEX-LLM — estado del contenedor, API Ollama, modelos cargados y métricas de memoria
disable-model-invocation: true
---

Run all diagnostics below and present results in a single summary table. Be concise.

## Steps

1. **Container state**
   ```
   docker compose -f ~/llm/ipex-llm/docker-compose.yml ps
   ```

2. **Healthcheck status**
   ```
   docker inspect ipex-llm --format '{{.State.Health.Status}}' 2>/dev/null || echo "container not running"
   ```

3. **Ollama API + loaded models**
   ```
   curl -s http://localhost:11434/api/tags 2>/dev/null | python3 -c "
   import sys, json
   data = json.load(sys.stdin)
   models = data.get('models', [])
   if not models:
       print('No models loaded')
   else:
       for m in models:
           size_gb = m.get('size', 0) / 1e9
           print(f\"  • {m['name']} ({size_gb:.1f} GB)\")
   " 2>/dev/null || echo "Ollama API not responding"
   ```

4. **Memory usage**
   ```
   docker stats ipex-llm --no-stream --format "Memory: {{.MemUsage}} / {{.MemPerc}}" 2>/dev/null || echo "Container not running"
   ```

## Output format

Present as a table:

| Check | Status |
|-------|--------|
| Container | running / stopped |
| Healthcheck | healthy / unhealthy / starting |
| Ollama API | up / down |
| Models | list or "none" |
| Memory | usage / limit |

If the container is stopped, suggest:
```
docker compose -f ~/llm/ipex-llm/docker-compose.yml up -d
```
And note that the first start after reboot takes ~60s for SYCL kernel compilation.
