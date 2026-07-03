#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_URL="${API_URL:-http://localhost:5000}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/docker/docker-compose.yml}"
DATASET_DIR="${DATASET_DIR:-$ROOT_DIR/dataset}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/documentacao/experimentos}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
BATCH_SIZE="${BATCH_SIZE:-1000}"
STOP_NODE="${STOP_NODE:-mongo3}"
SKIP_DOCKER_UP="${SKIP_DOCKER_UP:-0}"

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
  elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
  else
    echo "Erro: python3 ou python precisa estar disponivel no PATH." >&2
    exit 1
  fi
fi

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/experimentos-$RUN_ID.log"
SUMMARY_FILE="$LOG_DIR/experimentos-$RUN_ID.csv"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE"
}

require_file() {
  if [[ ! -f "$1" ]]; then
    log "ERRO arquivo obrigatorio nao encontrado: $1"
    exit 1
  fi
}

http_get() {
  "$PYTHON_BIN" - "$1" <<'PY'
import sys
import urllib.request

url = sys.argv[1]
with urllib.request.urlopen(url, timeout=120) as response:
    body = response.read().decode("utf-8", errors="replace")
    print(body)
PY
}

measure_get() {
  local label="$1"
  local url="$2"
  local output_file="$3"

  "$PYTHON_BIN" - "$label" "$url" "$output_file" "$SUMMARY_FILE" <<'PY'
import csv
import hashlib
import sys
import time
import urllib.request

label, url, output_file, summary_file = sys.argv[1:5]
started = time.perf_counter()
with urllib.request.urlopen(url, timeout=300) as response:
    body = response.read()
elapsed = time.perf_counter() - started
digest = hashlib.sha256(body).hexdigest()

with open(output_file, "wb") as file:
    file.write(body)

with open(summary_file, "a", newline="", encoding="utf-8") as file:
    writer = csv.writer(file)
    writer.writerow([label, "consulta", "", f"{elapsed:.6f}", len(body), digest, url])

print(f"{label};seconds={elapsed:.6f};bytes={len(body)};sha256={digest}")
PY
}

bulk_insert_jsonl() {
  local dataset_file="$1"
  local collection="$2"
  local volume_label="$3"

  "$PYTHON_BIN" - "$dataset_file" "$collection" "$volume_label" "$API_URL" "$BATCH_SIZE" "$SUMMARY_FILE" <<'PY'
import csv
import json
import sys
import time
import urllib.parse
import urllib.request

dataset_file, collection, volume_label, api_url, batch_size, summary_file = sys.argv[1:7]
batch_size = int(batch_size)
endpoint = f"{api_url.rstrip('/')}/interrupcoes/bulk?collection={urllib.parse.quote(collection)}"

inserted = 0
batches = 0
batch = []
started = time.perf_counter()

def send_batch(items):
    data = json.dumps(items, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        endpoint,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=600) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return int(payload["insertedCount"])

with open(dataset_file, "r", encoding="utf-8") as file:
    for line in file:
        line = line.strip()
        if not line:
            continue
        batch.append(json.loads(line))
        if len(batch) >= batch_size:
            inserted += send_batch(batch)
            batches += 1
            batch.clear()

if batch:
    inserted += send_batch(batch)
    batches += 1

elapsed = time.perf_counter() - started

with open(summary_file, "a", newline="", encoding="utf-8") as file:
    writer = csv.writer(file)
    writer.writerow([f"insercao_{volume_label}", "insercao", inserted, f"{elapsed:.6f}", "", "", endpoint])

print(f"volume={volume_label};collection={collection};inserted={inserted};batches={batches};seconds={elapsed:.6f}")
PY
}

wait_for_api() {
  log "Aguardando API em $API_URL/health"
  for attempt in $(seq 1 60); do
    if http_get "$API_URL/health" >/dev/null 2>&1; then
      log "API disponivel"
      return 0
    fi
    sleep 2
  done
  log "ERRO API nao respondeu dentro do tempo esperado"
  exit 1
}

run_test_1_insertion() {
  log "TESTE 1 - Insercao"
  for volume in 1k 50k 100k; do
    local dataset_file="$DATASET_DIR/dataset_${volume}.jsonl"
    local collection="interrupcoes_exp_${RUN_ID}_${volume}"
    require_file "$dataset_file"

    log "Iniciando insercao volume=$volume dataset=$dataset_file collection=$collection batch_size=$BATCH_SIZE"
    local result
    result="$(bulk_insert_jsonl "$dataset_file" "$collection" "$volume")"
    log "Resultado insercao: $result"
  done
}

run_test_2_queries() {
  log "TESTE 2 - Consultas"
  for volume in 1k 50k 100k; do
    local collection="interrupcoes_exp_${RUN_ID}_${volume}"
    local output_prefix="$LOG_DIR/${RUN_ID}-${volume}"

    log "Executando consultas volume=$volume collection=$collection"
    measure_get "consulta_tipo_${volume}" \
      "$API_URL/interrupcoes/tipo?tipo=nao_programada&limit=100&collection=$collection" \
      "$output_prefix-tipo.json" | tee -a "$LOG_FILE"

    measure_get "consulta_periodo_${volume}" \
      "$API_URL/interrupcoes/periodo?inicio=2025-01-01&fim=2025-01-31&limit=100&collection=$collection" \
      "$output_prefix-periodo.json" | tee -a "$LOG_FILE"

    measure_get "consulta_geografica_${volume}" \
      "$API_URL/interrupcoes/localizacao?conjuntoConsumidor=Caiaponia&siglaAgente=EQUATORIAL%20GO&limit=100&collection=$collection" \
      "$output_prefix-geografica.json" | tee -a "$LOG_FILE"

    measure_get "consulta_gravidade_${volume}" \
      "$API_URL/interrupcoes/gravidade?minimo=3&limit=100&collection=$collection" \
      "$output_prefix-gravidade.json" | tee -a "$LOG_FILE"

    measure_get "estatisticas_tipo_${volume}" \
      "$API_URL/interrupcoes/estatisticas/tipo?collection=$collection" \
      "$output_prefix-estatisticas-tipo.json" | tee -a "$LOG_FILE"

    measure_get "estatisticas_agente_${volume}" \
      "$API_URL/interrupcoes/estatisticas/agente-regulado?collection=$collection" \
      "$output_prefix-estatisticas-agente.json" | tee -a "$LOG_FILE"

    measure_get "estatisticas_evolucao_${volume}" \
      "$API_URL/interrupcoes/estatisticas/evolucao-temporal?collection=$collection" \
      "$output_prefix-estatisticas-evolucao.json" | tee -a "$LOG_FILE"
  done
}

run_test_3_node_failure() {
  local collection="interrupcoes_exp_${RUN_ID}_1k"
  local before_file="$LOG_DIR/${RUN_ID}-falha-before.json"
  local after_file="$LOG_DIR/${RUN_ID}-falha-after.json"

  log "TESTE 3 - Falha de no"
  log "Consulta normal antes da falha collection=$collection"
  measure_get "falha_no_antes" \
    "$API_URL/interrupcoes/estatisticas/tipo?collection=$collection" \
    "$before_file" | tee -a "$LOG_FILE"

  log "Desligando node $STOP_NODE"
  docker compose -f "$COMPOSE_FILE" stop "$STOP_NODE" | tee -a "$LOG_FILE"
  sleep 10

  log "Consulta apos desligar $STOP_NODE"
  measure_get "falha_no_depois" \
    "$API_URL/interrupcoes/estatisticas/tipo?collection=$collection" \
    "$after_file" | tee -a "$LOG_FILE"

  log "Religando node $STOP_NODE"
  docker compose -f "$COMPOSE_FILE" up -d "$STOP_NODE" | tee -a "$LOG_FILE"
  wait_for_api

  if cmp -s "$before_file" "$after_file"; then
    log "Comparacao falha de no: resultados identicos"
  else
    log "Comparacao falha de no: resultados diferentes; verificar $before_file e $after_file"
  fi
}

main() {
  require_file "$DATASET_DIR/dataset_1k.jsonl"
  require_file "$DATASET_DIR/dataset_50k.jsonl"
  require_file "$DATASET_DIR/dataset_100k.jsonl"

  printf 'label,tipo,quantidade,segundos,bytes,sha256,url\n' > "$SUMMARY_FILE"

  log "Inicio dos experimentos item 8"
  log "RUN_ID=$RUN_ID"
  log "API_URL=$API_URL"
  log "COMPOSE_FILE=$COMPOSE_FILE"
  log "DATASET_DIR=$DATASET_DIR"
  log "BATCH_SIZE=$BATCH_SIZE"
  log "LOG_FILE=$LOG_FILE"
  log "SUMMARY_FILE=$SUMMARY_FILE"

  if [[ "$SKIP_DOCKER_UP" != "1" ]]; then
    log "Subindo ambiente Docker"
    docker compose -f "$COMPOSE_FILE" up -d --build | tee -a "$LOG_FILE"
  fi

  wait_for_api
  log "Cluster: $(http_get "$API_URL/cluster")"

  run_test_1_insertion
  run_test_2_queries
  run_test_3_node_failure

  log "Experimentos finalizados"
  log "Resumo CSV: $SUMMARY_FILE"
}

main "$@"
