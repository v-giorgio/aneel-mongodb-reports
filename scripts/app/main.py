import json
import os
import re
from datetime import date, datetime

from bson import ObjectId
from bson.errors import InvalidId
from flask import Flask, jsonify, request
from pymongo import MongoClient
from pymongo.errors import PyMongoError


MONGO_URI = os.getenv(
    "MONGO_URI",
    "mongodb://localhost:27017,localhost:27018,localhost:27019/bd2"
    "?replicaSet=rs0&readPreference=secondaryPreferred",
)

# readPreference=secondaryPreferred -> Para leituras, prefira usar os nós secundários.
# Se não houver secundário disponível, use o primário.
MONGO_DATABASE = os.getenv("MONGO_DATABASE", "bd2")
EVENTS_COLLECTION = os.getenv("EVENTS_COLLECTION", "interrupcoes")

client = MongoClient(MONGO_URI, serverSelectionTimeoutMS=5000)
db = client[MONGO_DATABASE]

app = Flask(__name__)


@app.after_request
def add_cors_headers(response):
    """
    Add CORS headers so the React frontend can call the API from the browser.
    """
    response.headers["Access-Control-Allow-Origin"] = os.getenv("CORS_ORIGIN", "*")
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    response.headers["Access-Control-Allow-Methods"] = "GET,POST,DELETE,OPTIONS"
    return response


def serialize(value):
    """
    Convert MongoDB and Python values into JSON-serializable values.
    """
    if isinstance(value, ObjectId):
        return str(value)
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, list):
        return [serialize(item) for item in value]
    if isinstance(value, dict):
        return {key: serialize(item) for key, item in value.items()}
    return value


def parse_filter():
    """
    Read the optional filter query parameter and convert it into a MongoDB query.
    """
    raw_filter = request.args.get("filter")
    if not raw_filter:
        return {}

    try:
        parsed = json.loads(raw_filter)
    except json.JSONDecodeError as exc:
        raise ValueError("O parametro filter deve ser um JSON valido.") from exc

    if not isinstance(parsed, dict):
        raise ValueError("O parametro filter deve ser um objeto JSON.")

    if "_id" in parsed and isinstance(parsed["_id"], str):
        parsed["_id"] = ObjectId(parsed["_id"])

    return parsed


def get_limit(default=50, maximum=1000):
    """
    Read and validate the limit query parameter, applying an upper bound.
    """
    limit = int(request.args.get("limit", default))
    if limit < 1:
        raise ValueError("O parametro limit deve ser maior que zero.")
    return min(limit, maximum)


def get_events_collection():
    """
    Return the events collection selected by query parameter or the default name.
    """
    collection_name = request.args.get("collection", EVENTS_COLLECTION)
    return db[collection_name]


def list_query_results(collection, query):
    """
    Execute a MongoDB find query and return the serialized documents response.
    """
    documents = collection.find(query).limit(get_limit())
    return jsonify({"documents": [serialize(document) for document in documents]})


def date_range_query(field_name, start, end):
    """
    Build a MongoDB range query for a date-like string field.
    """
    query = {}
    if start:
        query["$gte"] = start
    if end:
        query["$lte"] = end
    return {field_name: query}


def agent_filter():
    """
    Build an optional aggregation match filter for agenteRegulado.
    """
    agent = request.args.get("agenteRegulado")
    if not agent:
        return {}
    return {"agenteRegulado": agent}


@app.errorhandler(PyMongoError)
def handle_mongo_error(error):
    """
    Convert PyMongo errors into a JSON HTTP 500 response.
    """
    return jsonify({"error": "Erro ao acessar o MongoDB.", "detail": str(error)}), 500


@app.errorhandler(ValueError)
def handle_value_error(error):
    """
    Convert validation errors into a JSON HTTP 400 response.
    """
    return jsonify({"error": str(error)}), 400


@app.errorhandler(InvalidId)
def handle_invalid_id(error):
    """
    Convert invalid ObjectId errors into a JSON HTTP 400 response.
    """
    return jsonify({"error": "ObjectId invalido.", "detail": str(error)}), 400


@app.get("/health")
def health():
    """
    Check whether the API can reach MongoDB.
    """
    client.admin.command("ping")
    return jsonify({"status": "ok", "database": MONGO_DATABASE})


@app.get("/cluster")
def cluster():
    """
    Return replica set status, primary node, read preference, and member health.
    """
    hello = client.admin.command("hello")
    status = client.admin.command("replSetGetStatus")
    members = [
        {
            "name": member["name"],
            "state": member["stateStr"],
            "health": member["health"],
        }
        for member in status["members"]
    ]

    return jsonify(
        {
            "set": status["set"],
            "primary": hello.get("primary"),
            "readPreference": "secondaryPreferred",
            "members": members,
        }
    )


@app.get("/collections")
def list_collections():
    """
    List all collections in the configured MongoDB database.
    """
    return jsonify({"collections": db.list_collection_names()})


@app.post("/interrupcoes")
def insert_interruption():
    """
    Insert one interruption event into the configured events collection.
    """
    document = request.get_json(silent=True)
    if not isinstance(document, dict):
        return jsonify({"error": "Envie um objeto JSON no corpo da requisicao."}), 400

    result = get_events_collection().insert_one(document)
    document["_id"] = result.inserted_id

    return jsonify({"inserted": serialize(document)}), 201


@app.post("/interrupcoes/bulk")
def insert_many_interruptions():
    """
    Insert many interruption events into the configured events collection.
    """
    documents = request.get_json(silent=True)
    if not isinstance(documents, list) or not documents:
        return jsonify({"error": "Envie uma lista JSON nao vazia no corpo da requisicao."}), 400
    if not all(isinstance(document, dict) for document in documents):
        return jsonify({"error": "Todos os itens da lista devem ser objetos JSON."}), 400

    result = get_events_collection().insert_many(documents)

    return (
        jsonify(
            {
                "insertedCount": len(result.inserted_ids),
                "insertedIds": [str(inserted_id) for inserted_id in result.inserted_ids],
            }
        ),
        201,
    )


@app.get("/interrupcoes/tipo")
def find_interruptions_by_type():
    """
    Query interruption events by tipoInterrupcao: programada or nao_programada.
    """
    interruption_type = request.args.get("tipo")
    if not interruption_type:
        raise ValueError("Informe o parametro tipo: programada ou nao_programada.")

    normalized_type = interruption_type.strip().lower().replace("-", "_")
    if normalized_type in ("programada", "interrupcao_programada"):
        query = {"tipoInterrupcao": {"$regex": "^Programada$", "$options": "i"}}
    elif normalized_type in ("nao_programada", "nao programada", "interrupcao_nao_programada"):
        query = {"tipoInterrupcao": {"$regex": "N.*o Programada$", "$options": "i"}}
    else:
        raise ValueError("Tipo invalido. Use programada ou nao_programada.")

    return list_query_results(get_events_collection(), query)


@app.get("/interrupcoes/periodo")
def find_interruptions_by_period():
    """
    Query interruption events by dataHoraInicio range.
    """
    start = request.args.get("inicio")
    end = request.args.get("fim")
    if not start and not end:
        raise ValueError("Informe pelo menos um parametro: inicio ou fim.")

    query = date_range_query("dataHoraInicio", start, end)

    return list_query_results(get_events_collection(), query)


@app.get("/interrupcoes/localizacao")
def find_interruptions_by_location():
    """
    Query interruption events by conjuntoConsumidor and/or siglaAgente.
    """
    consumer_group = request.args.get("conjuntoConsumidor", request.args.get("municipio"))
    agent_code = request.args.get("siglaAgente")
    if not consumer_group and not agent_code:
        raise ValueError("Informe pelo menos um parametro: conjuntoConsumidor ou siglaAgente.")

    query = {}
    if consumer_group:
        query["conjuntoConsumidor"] = {"$regex": f"^{re.escape(consumer_group)}$", "$options": "i"}
    if agent_code:
        query["siglaAgente"] = {"$regex": f"^{re.escape(agent_code)}$", "$options": "i"}

    return list_query_results(get_events_collection(), query)


@app.get("/interrupcoes/gravidade")
def find_interruptions_by_gravity():
    """
    Query interruption events whose gravidade is greater than a threshold.
    """
    minimum = request.args.get("minimo", request.args.get("maiorQue"))
    if minimum is None:
        raise ValueError("Informe o parametro minimo ou maiorQue.")

    try:
        minimum_value = float(minimum)
    except ValueError as exc:
        raise ValueError("O parametro minimo deve ser numerico.") from exc

    query = {"gravidade": {"$gt": minimum_value}}

    return list_query_results(get_events_collection(), query)


@app.get("/interrupcoes/estatisticas/tipo")
def statistics_by_type():
    """
    Aggregate interruption totals grouped by interruption type.
    """
    pipeline = [
        {"$match": agent_filter()},
        {"$group": {"_id": "$tipoInterrupcao", "total": {"$sum": 1}}},
        {"$project": {"_id": 0, "tipo": "$_id", "total": 1}},
        {"$sort": {"total": -1, "tipo": 1}},
    ]

    results = list(get_events_collection().aggregate(pipeline))
    return jsonify({"results": serialize(results)})


@app.get("/interrupcoes/estatisticas/agente-regulado")
def statistics_by_regulated_agent():
    """
    Aggregate interruption totals grouped by agenteRegulado.
    """
    pipeline = [
        {"$match": agent_filter()},
        {"$group": {"_id": "$agenteRegulado", "total": {"$sum": 1}}},
        {"$project": {"_id": 0, "agenteRegulado": "$_id", "total": 1}},
        {"$sort": {"total": -1, "agenteRegulado": 1}},
    ]

    results = list(get_events_collection().aggregate(pipeline))
    return jsonify({"results": serialize(results)})


@app.get("/interrupcoes/estatisticas/bairro")
def statistics_by_neighborhood_alias():
    """
    Return the agent aggregation used as the bairro requirement alias for this dataset.
    """
    return statistics_by_regulated_agent()


@app.get("/interrupcoes/estatisticas/evolucao-temporal")
def temporal_evolution_statistics():
    """
    Aggregate interruption totals per day using dataHoraInicio.
    """
    pipeline = [
        {"$match": agent_filter()},
        {
            "$project": {
                "dia": {
                    "$substr": ["$dataHoraInicio", 0, 10]
                }
            }
        },
        {"$match": {"dia": {"$ne": ""}}},
        {"$group": {"_id": "$dia", "total": {"$sum": 1}}},
        {"$project": {"_id": 0, "dia": "$_id", "total": 1}},
        {"$sort": {"dia": 1}},
    ]

    results = list(get_events_collection().aggregate(pipeline))
    return jsonify({"results": serialize(results)})
