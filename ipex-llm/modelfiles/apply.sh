#!/usr/bin/env bash
# modelfiles/apply.sh — Aplica todos los Modelfiles al contenedor ipex-llm
# Uso: ./modelfiles/apply.sh
# Los modelos se sobrescriben con el mismo nombre; los pesos no se re-descargan.

set -euo pipefail

CONTAINER="ipex-llm"
OLLAMA="/llm/ollama/ollama"
DIR="$(cd "$(dirname "$0")" && pwd)"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red() { printf '\033[31m✗ %s\033[0m\n' "$*"; }

if ! docker ps --filter "name=^${CONTAINER}$" --filter status=running -q | grep -q .; then
  red "Contenedor '$CONTAINER' no está corriendo. Arranca con: docker compose up -d"
  exit 1
fi

declare -A MODELS=(
  ["qwen2.5-coder-14b.Modelfile"]="qwen2.5-coder:14b"
  ["qwen3-8b.Modelfile"]="qwen3:8b"
  ["gemma3-12b.Modelfile"]="gemma3:12b"
  ["llama3.1-8b.Modelfile"]="llama3.1:8b-instruct-q4_K_M"
  ["phi4-mini.Modelfile"]="phi4-mini"
)

bold "Aplicando Modelfiles → contenedor $CONTAINER"
echo

ERRORS=0
for file in qwen2.5-coder-14b.Modelfile qwen3-8b.Modelfile gemma3-12b.Modelfile llama3.1-8b.Modelfile phi4-mini.Modelfile; do
  model="${MODELS[$file]}"
  printf "  %-45s ... " "$model"
  # docker exec -f - (stdin) no funciona en IPEX-LLM; usar docker cp + ruta
  docker cp "$DIR/$file" "${CONTAINER}:/tmp/current.Modelfile" 2>/dev/null
  if docker exec "$CONTAINER" "$OLLAMA" create "$model" -f /tmp/current.Modelfile > /dev/null 2>&1; then
    green "ok"
  else
    red "FALLO"
    ERRORS=$((ERRORS + 1))
  fi
done

echo
if [[ $ERRORS -eq 0 ]]; then
  bold "Todos los modelos actualizados."
  echo "Verifica con: docker exec $CONTAINER $OLLAMA show <modelo>"
else
  bold "$ERRORS modelo(s) fallaron. Revisa con:"
  echo "  docker exec -i $CONTAINER $OLLAMA create <modelo> -f - < modelfiles/<fichero>"
  exit 1
fi
