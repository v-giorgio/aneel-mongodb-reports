# Trabalho BD2

Ambiente com:

- API Python/Flask
- cluster MongoDB com 3 instancias em replica set
- leituras com `readPreference=secondaryPreferred`, permitindo distribuicao entre replicas pelo driver

## Estrutura

```text
scripts/       codigo da API Flask
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

## Verificar cluster

```bash
curl http://localhost:5000/health
curl http://localhost:5000/cluster
```

## Criar uma collection

```bash
curl -X POST http://localhost:5000/collections/usuarios
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
