# Trabalho BD2

Ambiente com:

- API Python/Flask
- Frontend React com Bootstrap
- cluster MongoDB com 3 instancias em replica set
- leituras com `readPreference=secondaryPreferred`, permitindo distribuicao entre replicas pelo driver

## Estrutura

```text
scripts/       codigo da API Flask
scripts/frontend/  frontend React
dataset/       arquivos de dados
docker/        Dockerfile, Compose e scripts do MongoDB
documentacao/  instrucoes do projeto
```

## Subir o ambiente

Se voce ja tinha subido a versao antiga com MongoDB standalone e usuario/senha,
limpe os volumes antes da primeira execucao do cluster:

```bash
docker compose -f docker/docker-compose.yml down -v
```

Depois suba tudo:

```bash
docker compose -f docker/docker-compose.yml up --build -d
```

API:

```text
http://localhost:5000
```

Frontend:

```text
http://localhost:3000
```

O frontend chama os endpoints do item 6:

- insercao de uma interrupcao
- insercao em lote
- consulta por tipo de interrupcao
- consulta por periodo
- consulta geografica por `conjuntoConsumidor` e `siglaAgente`
- consulta por gravidade
- estatisticas por tipo, agente regulado e evolucao temporal

## Verificar cluster

```bash
curl http://localhost:5000/health
curl http://localhost:5000/cluster
```

## Replicacao e distribuicao de leituras

O ambiente usa um replica set MongoDB chamado `rs0` com 3 nodes:

```text
mongo1: PRIMARY
mongo2: SECONDARY
mongo3: SECONDARY
```

No MongoDB replica set, as escritas sao recebidas pelo node `PRIMARY` e depois
replicadas automaticamente para os nodes `SECONDARY`. Se o primary ficar
indisponivel, os nodes restantes podem eleger um novo primary, mantendo o banco
disponivel para a aplicacao.

A API se conecta usando a URI:

```text
mongodb://mongo1:27017,mongo2:27017,mongo3:27017/bd2?replicaSet=rs0&readPreference=secondaryPreferred
```

O parametro `readPreference=secondaryPreferred` faz o driver PyMongo preferir os
nodes secundarios para leituras. Assim, as consultas podem ser distribuidas entre
as replicas. As operacoes de escrita continuam indo para o primary, que e o
comportamento correto em replica set MongoDB.

Resumo:

```text
insert/update/delete -> PRIMARY
find/consultas       -> preferencialmente SECONDARY
```

Nao ha um load balancer externo como Nginx ou HAProxy. A distribuicao de leituras
e feita pelo proprio driver MongoDB, que descobre os membros do replica set pela
URI de conexao.

## O que vem da imagem MongoDB e o que foi configurado

A imagem oficial `mongo:7.0` fornece o servidor MongoDB (`mongod`) e o shell
`mongosh`, mas ela nao cria automaticamente um cluster com 3 nodes.

O cluster distribuido e configurado por estes arquivos do projeto:

- `docker/docker-compose.yml`: sobe 3 containers MongoDB e inicia cada um com
  `mongod --replSet rs0 --bind_ip_all`.
- `docker/mongo/init-replica-set.js`: executa `rs.initiate(...)` e registra os
  membros `mongo1`, `mongo2` e `mongo3` no replica set.
- `MONGO_URI` no servico `api`: informa ao PyMongo os 3 nodes, o nome do replica
  set e a preferencia de leitura.

Portanto, a replicacao automatica dos dados e uma funcionalidade nativa do
MongoDB, mas ela so acontece porque o projeto configura explicitamente o
replica set no Docker Compose e no script de inicializacao.

## Criar uma collection

```bash
curl -X POST http://localhost:5000/collections/usuarios
```

## Endpoints de interrupcoes

A collection padrao dos endpoints abaixo e `interrupcoes`. Para usar outra
collection, informe `?collection=nome_da_collection`.

### Inserir uma interrupcao

```bash
curl -X POST http://localhost:5000/interrupcoes \
  -H "Content-Type: application/json" \
  -d "{\"idEvento\":\"EVT000001\",\"descricao\":\"Interna;Nao Programada;Meio Ambiente;Descarga Atmosferica\",\"dataHoraInicio\":\"2025-06-14T15:45:20\",\"dataHoraFim\":\"2025-06-14T19:53:00\",\"duracaoMinutos\":247.67,\"gravidade\":5,\"conjuntoConsumidor\":\"Caiaponia\",\"alimentador\":\"32\",\"subestacao\":\"30\",\"tipoInterrupcao\":\"Nao Programada\",\"agenteRegulado\":\"EQUATORIAL GOIAS DISTRIBUIDORA DE ENERGIA S/A\",\"siglaAgente\":\"EQUATORIAL GO\"}"
```

### Inserir varias interrupcoes

```bash
curl -X POST http://localhost:5000/interrupcoes/bulk \
  -H "Content-Type: application/json" \
  -d "[{\"idEvento\":\"EVT000001\",\"tipoInterrupcao\":\"Nao Programada\",\"dataHoraInicio\":\"2025-06-14T15:45:20\"},{\"idEvento\":\"EVT000002\",\"tipoInterrupcao\":\"Programada\",\"dataHoraInicio\":\"2025-06-15T10:00:00\"}]"
```

Tambem existe o endpoint generico para qualquer collection:

```bash
curl -X POST http://localhost:5000/collections/interrupcoes/documents/bulk \
  -H "Content-Type: application/json" \
  -d "[{\"idEvento\":\"EVT000001\"},{\"idEvento\":\"EVT000002\"}]"
```

### Consulta por tipo de interrupcao

Aceita `programada` ou `nao_programada`.

```bash
curl "http://localhost:5000/interrupcoes/tipo?tipo=nao_programada&limit=50"
```

O endpoint consulta documentos no formato do dataset:

```json
{
  "tipoInterrupcao": "Nao Programada"
}
```

### Consulta por periodo

Usa `dataHoraInicio`.

```bash
curl "http://localhost:5000/interrupcoes/periodo?inicio=2025-01-01&fim=2025-01-31"
```

### Consulta por localizacao

Neste projeto, a consulta geografica foi adaptada para filtros por
`conjuntoConsumidor`, que representa o municipio/conjunto consumidor no dataset.
Tambem e possivel combinar com `siglaAgente`.

```bash
curl "http://localhost:5000/interrupcoes/localizacao?conjuntoConsumidor=Caiaponia&siglaAgente=EQUATORIAL%20GO"
```

Tambem e aceito o alias `municipio` para consultar `conjuntoConsumidor`:

```bash
curl "http://localhost:5000/interrupcoes/localizacao?municipio=Caiaponia"
```

### Consulta por gravidade

Retorna eventos com `gravidade` maior que o valor informado.

```bash
curl "http://localhost:5000/interrupcoes/gravidade?minimo=3"
```

### Estatisticas

Quantidade por tipo de interrupcao:

```bash
curl http://localhost:5000/interrupcoes/estatisticas/tipo
```

Quantidade por agente regulado:

```bash
curl http://localhost:5000/interrupcoes/estatisticas/agente-regulado
```

Alias usado para atender o item "bairro" do enunciado com o campo disponivel no
dataset:

```bash
curl http://localhost:5000/interrupcoes/estatisticas/bairro
```

Evolucao temporal por dia:

```bash
curl http://localhost:5000/interrupcoes/estatisticas/evolucao-temporal
```

As estatisticas aceitam filtro por agente regulado:

```bash
curl "http://localhost:5000/interrupcoes/estatisticas/tipo?agenteRegulado=ENERGISA%20ACRE"
```

## Experimentos do item 8

O script `scripts/run_experiments.sh` executa os experimentos exigidos no item 8
do enunciado de forma reproduzivel:

- Teste 1: mede o tempo de insercao para 1.000, 50.000 e 100.000 registros.
- Teste 2: mede consultas por tipo, periodo, localizacao, gravidade e
  estatisticas para os tres volumes.
- Teste 3: executa uma consulta, desliga um node MongoDB, executa a consulta
  novamente e compara os resultados.

Execute a partir da raiz do projeto usando Bash, por exemplo Git Bash, WSL ou
Linux:

```bash
bash scripts/run_experiments.sh
```

Os logs sao gravados em:

```text
documentacao/experimentos/
```

Para cada execucao sao gerados:

```text
experimentos-<RUN_ID>.log  log textual completo
experimentos-<RUN_ID>.csv  resumo tabular dos tempos
```

O Teste 1 documenta os tempos de insercao diretamente no log, em linhas como:

```text
Resultado insercao: volume=1k;collection=interrupcoes_exp_<RUN_ID>_1k;inserted=1000;batches=1;seconds=10.000000
```

Variaveis opcionais:

```bash
RUN_ID=teste01 bash scripts/run_experiments.sh
BATCH_SIZE=500 bash scripts/run_experiments.sh
SKIP_DOCKER_UP=1 bash scripts/run_experiments.sh
STOP_NODE=mongo2 bash scripts/run_experiments.sh
API_URL=http://localhost:5000 bash scripts/run_experiments.sh
```

## Inserir documento

```bash
curl -X POST http://localhost:5000/collections/usuarios/documents \
  -H "Content-Type: application/json" \
  -d "{\"nome\":\"Ana\",\"email\":\"ana@email.com\",\"idade\":25}"
```

No PowerShell:

```powershell
$body = @{ nome = "Ana"; email = "ana@email.com"; idade = 25 } | ConvertTo-Json -Compress
Invoke-RestMethod -Uri "http://localhost:5000/collections/usuarios/documents" -Method Post -ContentType "application/json" -Body $body
```

## Ver documentos

```bash
curl http://localhost:5000/collections/usuarios/documents
```

Com filtro:

```bash
curl "http://localhost:5000/collections/usuarios/documents?filter={\"idade\":25}"
```

## Conectar direto no MongoDB

Pela maquina host:

```bash
mongosh "mongodb://localhost:27017,localhost:27018,localhost:27019/bd2?replicaSet=rs0&readPreference=secondaryPreferred"
```

Dentro da rede Docker, use os nomes dos servicos:

```text
mongodb://mongo1:27017,mongo2:27017,mongo3:27017/bd2?replicaSet=rs0&readPreference=secondaryPreferred
```

Observacao: em replica set, escritas sempre vao para o no primario. O balanceamento
acontece nas leituras, conforme a preferencia configurada no driver.

---

10s - 1000
24s - 50_000
33.6s - 100_000
