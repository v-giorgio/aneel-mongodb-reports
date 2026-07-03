# Trabalho BD2

- conectar: 

```
docker compose up
```

```
mongosh "mongodb://root:example@localhost:27017/admin"
```

- teste:

```
use minha_base
db.usuarios.insertOne({
  nome: "Ana",
  email: "ana@email.com",
  idade: 25
})

db.usuarios.find().pretty()
```