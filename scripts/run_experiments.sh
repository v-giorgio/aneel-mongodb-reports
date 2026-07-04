#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_URL="${API_URL:-http://localhost:5000}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/docker/docker-compose.yml}"
DATASET_DIR="${DATASET_DIR:-$ROOT_DIR/dataset}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/documentacao/experimentos}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
BATCH_SIZE="${BATCH_SIZE:-1000}"
LOG_EVERY_BATCH="${LOG_EVERY_BATCH:-10}"
STOP_NODE="${STOP_NODE:-mongo3}"
SKIP_DOCKER_UP="${SKIP_DOCKER_UP:-0}"
HEALTHCHECK_ONLY="${HEALTHCHECK_ONLY:-0}"

PYTHON_BIN="${PYTHON_BIN:-}"
PYTHON_CMD=()

python_candidate_works() {
  "$@" -c "import sys; print(sys.version)" >/dev/null 2>&1
}

detect_python() {
  if [[ -n "$PYTHON_BIN" ]]; then
    read -r -a PYTHON_CMD <<< "$PYTHON_BIN"
    if python_candidate_works "${PYTHON_CMD[@]}"; then
      return 0
    fi
    echo "Erro: PYTHON_BIN='$PYTHON_BIN' nao executa Python corretamente." >&2
    exit 1
  fi

  local win_userprofile="${USERPROFILE:-}"
  win_userprofile="${win_userprofile//\\//}"

  local candidates=(
    "python3"
    "python"
    "py -3"
    "py"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -z "$candidate" ]]; then
      continue
    fi
    read -r -a PYTHON_CMD <<< "$candidate"
    if command -v "${PYTHON_CMD[0]}" >/dev/null 2>&1 && python_candidate_works "${PYTHON_CMD[@]}"; then
      PYTHON_BIN="$candidate"
      return 0
    fi
  done

  echo "Erro: nenhum Python funcional encontrado. Tente: PYTHON_BIN='py -3' ./scripts/run_experiments.sh" >&2
  exit 1
}

python_run() {
  "${PYTHON_CMD[@]}" "$@"
}

ensure_log_dir() {
  local parent_dir="${LOG_DIR%/*}"
  if [[ ! -d "$parent_dir" ]]; then
    mkdir -p "$parent_dir"
  fi
  if [[ ! -d "$LOG_DIR" ]]; then
    mkdir "$LOG_DIR"
  fi
}

detect_python

ensure_log_dir
LOG_FILE="$LOG_DIR/experimentos-$RUN_ID.log"
SUMMARY_FILE="$LOG_DIR/experimentos-$RUN_ID.csv"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE"
}

trap 'log "ERRO linha=$LINENO status=$? comando=$BASH_COMMAND"' ERR

require_file() {
  if [[ ! -f "$1" ]]; then
    log "ERRO arquivo obrigatorio nao encontrado: $1"
    exit 1
  fi
}

dataset_info() {
  python_run - "$1" <<'PY'
import os
import sys

path = sys.argv[1]
records = 0
with open(path, "r", encoding="utf-8") as file:
    for line in file:
        if line.strip():
            records += 1
print(f"path={path};records={records};bytes={os.path.getsize(path)}")
PY
}

dataset_record_count() {
  python_run - "$1" <<'PY'
import sys

records = 0
with open(sys.argv[1], "r", encoding="utf-8") as file:
    for line in file:
        if line.strip():
            records += 1
print(records)
PY
}

http_get() {
  python_run - "$1" <<'PY'
import sys
import urllib.request

url = sys.argv[1]
with urllib.request.urlopen(url, timeout=120) as response:
    print(response.read().decode("utf-8", errors="replace"))
PY
}

measure_get() {
  local label="$1"
  local url="$2"
  local output_file="$3"

  log "Iniciando consulta label=$label output=$output_file url=$url"
  local result
  result="$(python_run - "$label" "$url" "$output_file" "$SUMMARY_FILE" <<'PY'
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
)"
  log "Resultado consulta: $result"
}

bulk_insert_jsonl() {
  local dataset_file="$1"
  local collection="$2"
  local volume_label="$3"

  python_run - "$dataset_file" "$collection" "$volume_label" "$API_URL" "$BATCH_SIZE" "$SUMMARY_FILE" "$LOG_FILE" "$LOG_EVERY_BATCH" <<'PY'
import csv
from datetime import datetime, timezone
import json
import sys
import time
import urllib.parse
import urllib.request

dataset_file, collection, volume_label, api_url, batch_size, summary_file, log_file, log_every_batch = sys.argv[1:9]
batch_size = int(batch_size)
log_every_batch = int(log_every_batch)
endpoint = f"{api_url.rstrip('/')}/interrupcoes/bulk?collection={urllib.parse.quote(collection)}"

inserted = 0
batches = 0
batch = []
started = time.perf_counter()

def append_log(message):
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(log_file, "a", encoding="utf-8") as file:
        file.write(f"{timestamp} {message}\n")

def send_batch(items):
    batch_started = time.perf_counter()
    data = json.dumps(items, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        endpoint,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=600) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return int(payload["insertedCount"]), time.perf_counter() - batch_started

append_log(
    f"Iniciando carga JSONL volume={volume_label} collection={collection} "
    f"dataset={dataset_file} batch_size={batch_size} endpoint={endpoint}"
)

with open(dataset_file, "r", encoding="utf-8") as file:
    for line in file:
        line = line.strip()
        if not line:
            continue
        batch.append(json.loads(line))
        if len(batch) >= batch_size:
            batch_inserted, batch_seconds = send_batch(batch)
            inserted += batch_inserted
            batches += 1
            if batches == 1 or batches % log_every_batch == 0:
                append_log(
                    f"Progresso insercao volume={volume_label} collection={collection} "
                    f"batch={batches} inserted={inserted} last_batch_seconds={batch_seconds:.6f}"
                )
            batch.clear()

if batch:
    batch_inserted, batch_seconds = send_batch(batch)
    inserted += batch_inserted
    batches += 1
    append_log(
        f"Progresso insercao volume={volume_label} collection={collection} "
        f"batch={batches} inserted={inserted} last_batch_seconds={batch_seconds:.6f}"
    )

elapsed = time.perf_counter() - started
with open(summary_file, "a", newline="", encoding="utf-8") as file:
    writer = csv.writer(file)
    writer.writerow([f"insercao_{volume_label}", "insercao", inserted, f"{elapsed:.6f}", "", "", endpoint])

append_log(
    f"Fim carga JSONL volume={volume_label} collection={collection} "
    f"inserted={inserted} batches={batches} seconds={elapsed:.6f}"
)
print(f"volume={volume_label};collection={collection};inserted={inserted};batches={batches};seconds={elapsed:.6f}")
PY
}

verify_collection_count() {
  local collection="$1"
  local volume_label="$2"
  local expected_count="$3"
  local result
  local status

  set +e
  result="$(python_run - "$collection" "$volume_label" "$expected_count" "$API_URL" "$SUMMARY_FILE" <<'PY' 2>&1
import csv
import hashlib
import json
import sys
import time
import urllib.parse
import urllib.request

collection, volume_label, expected_count, api_url, summary_file = sys.argv[1:6]
expected_count = int(expected_count)
endpoint = f"{api_url.rstrip('/')}/interrupcoes/count?collection={urllib.parse.quote(collection)}"

started = time.perf_counter()
with urllib.request.urlopen(endpoint, timeout=120) as response:
    body = response.read()
elapsed = time.perf_counter() - started
payload = json.loads(body.decode("utf-8"))
count = int(payload["count"])
digest = hashlib.sha256(body).hexdigest()

with open(summary_file, "a", newline="", encoding="utf-8") as file:
    writer = csv.writer(file)
    writer.writerow([f"verificacao_{volume_label}", "verificacao_contagem", count, f"{elapsed:.6f}", len(body), digest, endpoint])

print(
    f"volume={volume_label};collection={collection};expected={expected_count};"
    f"count={count};seconds={elapsed:.6f};url={endpoint}"
)

if count != expected_count:
    print(
        f"ERRO contagem divergente para collection={collection}: "
        f"expected={expected_count};count={count}",
        file=sys.stderr,
    )
    sys.exit(1)
PY
)"
  status=$?
  set -e

  log "Verificacao contagem: $result"
  if [[ "$status" -ne 0 ]]; then
    exit "$status"
  fi
}

wait_for_api() {
  log "Aguardando API em $API_URL/health"
  for attempt in $(seq 1 60); do
    if [[ "$attempt" == "1" || $((attempt % 10)) -eq 0 ]]; then
      log "Tentativa healthcheck API attempt=$attempt"
    fi
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

    local expected_count
    expected_count="$(dataset_record_count "$dataset_file")"
    log "Dataset insercao volume=$volume $(dataset_info "$dataset_file")"
    log "Iniciando insercao volume=$volume dataset=$dataset_file collection=$collection batch_size=$BATCH_SIZE"
    local result
    result="$(bulk_insert_jsonl "$dataset_file" "$collection" "$volume")"
    log "Resultado insercao: $result"
    verify_collection_count "$collection" "$volume" "$expected_count"
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
      "$output_prefix-tipo.json"
    measure_get "consulta_periodo_${volume}" \
      "$API_URL/interrupcoes/periodo?inicio=2025-01-01&fim=2025-01-31&limit=100&collection=$collection" \
      "$output_prefix-periodo.json"
    measure_get "consulta_geografica_${volume}" \
      "$API_URL/interrupcoes/localizacao?conjuntoConsumidor=Caiaponia&siglaAgente=EQUATORIAL%20GO&limit=100&collection=$collection" \
      "$output_prefix-geografica.json"
    measure_get "consulta_gravidade_${volume}" \
      "$API_URL/interrupcoes/gravidade?minimo=3&limit=100&collection=$collection" \
      "$output_prefix-gravidade.json"
    measure_get "estatisticas_tipo_${volume}" \
      "$API_URL/interrupcoes/estatisticas/tipo?collection=$collection" \
      "$output_prefix-estatisticas-tipo.json"
    measure_get "estatisticas_agente_${volume}" \
      "$API_URL/interrupcoes/estatisticas/agente-regulado?collection=$collection" \
      "$output_prefix-estatisticas-agente.json"
    measure_get "estatisticas_evolucao_${volume}" \
      "$API_URL/interrupcoes/estatisticas/evolucao-temporal?collection=$collection" \
      "$output_prefix-estatisticas-evolucao.json"
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
    "$before_file"

  log "Desligando node $STOP_NODE"
  docker compose -f "$COMPOSE_FILE" stop "$STOP_NODE" | tee -a "$LOG_FILE"
  sleep 10

  log "Consulta apos desligar $STOP_NODE"
  measure_get "falha_no_depois" \
    "$API_URL/interrupcoes/estatisticas/tipo?collection=$collection" \
    "$after_file"

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
  log "LOG_EVERY_BATCH=$LOG_EVERY_BATCH"
  log "STOP_NODE=$STOP_NODE"
  log "SKIP_DOCKER_UP=$SKIP_DOCKER_UP"
  log "HEALTHCHECK_ONLY=$HEALTHCHECK_ONLY"
  log "LOG_FILE=$LOG_FILE"
  log "SUMMARY_FILE=$SUMMARY_FILE"
  log "PYTHON_BIN=$PYTHON_BIN"
  log "Python: $(python_run --version 2>&1)"
  if command -v docker >/dev/null 2>&1; then
    log "Docker: $(docker --version 2>&1)"
  else
    log "Docker: comando docker nao encontrado no PATH"
  fi

  log "Pre-checagem dataset_1k $(dataset_info "$DATASET_DIR/dataset_1k.jsonl")"
  log "Pre-checagem dataset_50k $(dataset_info "$DATASET_DIR/dataset_50k.jsonl")"
  log "Pre-checagem dataset_100k $(dataset_info "$DATASET_DIR/dataset_100k.jsonl")"

  if [[ "$SKIP_DOCKER_UP" != "1" ]]; then
    log "Subindo ambiente Docker"
    docker compose -f "$COMPOSE_FILE" up -d --build | tee -a "$LOG_FILE"
  fi

  wait_for_api
  log "Cluster: $(http_get "$API_URL/cluster")"

  if [[ "$HEALTHCHECK_ONLY" == "1" ]]; then
    log "HEALTHCHECK_ONLY=1; encerrando antes dos experimentos"
    return 0
  fi

  run_test_1_insertion
  run_test_2_queries
  run_test_3_node_failure

  log "Experimentos finalizados"
  log "Resumo CSV: $SUMMARY_FILE"
}

main "$@"
