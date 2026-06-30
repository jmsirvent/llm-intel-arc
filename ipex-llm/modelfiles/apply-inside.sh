#!/usr/bin/env bash
# apply-inside.sh — Aplica Modelfiles desde DENTRO del contenedor.
# Llamado por docker-compose.yml en background tras arrancar el servidor.
# No usar en el host: para eso está apply.sh.

OLLAMA="/llm/ollama/ollama"
DIR="/modelfiles"

declare -A MODELS=(
  ["qwen2.5-coder-14b.Modelfile"]="qwen2.5-coder:14b"
  ["qwen3-8b.Modelfile"]="qwen3:8b"
  ["gemma3-12b.Modelfile"]="gemma3:12b"
  ["llama3.1-8b.Modelfile"]="llama3.1:8b-instruct-q4_K_M"
  ["phi4-mini.Modelfile"]="phi4-mini"
)

# Esperar a que el servidor Ollama esté listo (puede tardar ~60s el primer arranque)
until "$OLLAMA" list >/dev/null 2>&1; do sleep 3; done

echo "[modelfiles] Servidor listo — aplicando Modelfiles..."
for file in qwen2.5-coder-14b.Modelfile qwen3-8b.Modelfile gemma3-12b.Modelfile llama3.1-8b.Modelfile phi4-mini.Modelfile; do
  model="${MODELS[$file]}"
  if "$OLLAMA" create "$model" -f "$DIR/$file" >/dev/null 2>&1; then
    echo "[modelfiles] ✓ $model"
  else
    echo "[modelfiles] ✗ $model — ver logs con: docker compose logs ipex-llm-ollama"
  fi
done
echo "[modelfiles] Listo."
