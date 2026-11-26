#!/bin/bash
# Build and start the sandbox with sensible defaults derived from config/models:
#   OLLAMA_MODEL=qwen2.5-coder:14b ./up.sh          -> MODEL_FAMILY=qwen MODEL_PROFILE=16gb MEM_LIMIT=16g
#   MODEL_FAMILY=gemma MODEL_PROFILE=8gb ./up.sh    -> OLLAMA_MODEL from the table, MEM_LIMIT=8g
# Anything you export explicitly (MEM_LIMIT, MODEL_PROFILE, ...) wins over the derived value.
set -euo pipefail
cd "$(dirname "$0")"
if [ -n "${OLLAMA_MODEL:-}" ]; then
  read -r fam prof < <(awk -v t="$OLLAMA_MODEL" '$1==t{print $2, $3}' config/models) || true
  if [ -z "${fam:-}" ]; then
    echo "up.sh: $OLLAMA_MODEL is not in config/models; assuming MODEL_PROFILE=${MODEL_PROFILE:-16gb} (export MEM_LIMIT if that is wrong)" >&2
    fam=custom; prof=${MODEL_PROFILE:-16gb}
  fi
  export MODEL_FAMILY=${MODEL_FAMILY:-$fam} MODEL_PROFILE=${MODEL_PROFILE:-$prof}
fi
export MODEL_FAMILY=${MODEL_FAMILY:-qwen} MODEL_PROFILE=${MODEL_PROFILE:-8gb}
export MEM_LIMIT=${MEM_LIMIT:-${MODEL_PROFILE%gb}g}
echo "up.sh: model=${OLLAMA_MODEL:-<config/models: $MODEL_FAMILY $MODEL_PROFILE>} family=$MODEL_FAMILY profile=$MODEL_PROFILE mem_limit=$MEM_LIMIT"
exec docker compose up -d --build "$@"
