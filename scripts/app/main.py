import json
import os
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
MONGO_DATABASE = os.getenv("MONGO_DATABASE", "bd2")

client = MongoClient(MONGO_URI, serverSelectionTimeoutMS=5000)
db = client[MONGO_DATABASE]

app = Flask(__name__)


def serialize(value):
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


@app.errorhandler(PyMongoError)
def handle_mongo_error(error):
    return jsonify({"error": "Erro ao acessar o MongoDB.", "detail": str(error)}), 500


@app.errorhandler(ValueError)
def handle_value_error(error):
    return jsonify({"error": str(error)}), 400


@app.errorhandler(InvalidId)
def handle_invalid_id(error):
    return jsonify({"error": "ObjectId invalido.", "detail": str(error)}), 400


@app.get("/health")
def health():
    client.admin.command("ping")
    return jsonify({"status": "ok", "database": MONGO_DATABASE})


@app.get("/cluster")
def cluster():
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
    return jsonify({"collections": db.list_collection_names()})


@app.post("/collections/<collection_name>")
def create_collection(collection_name):
    if collection_name in db.list_collection_names():
        return jsonify({"message": "Collection ja existe.", "collection": collection_name})

    db.create_collection(collection_name)
    return jsonify({"message": "Collection criada.", "collection": collection_name}), 201


@app.post("/collections/<collection_name>/documents")
def insert_document(collection_name):
    document = request.get_json(silent=True)
    if not isinstance(document, dict):
        return jsonify({"error": "Envie um objeto JSON no corpo da requisicao."}), 400

    result = db[collection_name].insert_one(document)
    document["_id"] = result.inserted_id

    return jsonify({"inserted": serialize(document)}), 201


@app.get("/collections/<collection_name>/documents")
def list_documents(collection_name):
    query = parse_filter()
    limit = int(request.args.get("limit", 50))
    if limit < 1:
        raise ValueError("O parametro limit deve ser maior que zero.")
    limit = min(limit, 200)
    documents = db[collection_name].find(query).limit(limit)

    return jsonify({"documents": [serialize(document) for document in documents]})


@app.get("/collections/<collection_name>/documents/<document_id>")
def get_document(collection_name, document_id):
    document = db[collection_name].find_one({"_id": ObjectId(document_id)})
    if document is None:
        return jsonify({"error": "Documento nao encontrado."}), 404

    return jsonify({"document": serialize(document)})


@app.delete("/collections/<collection_name>/documents/<document_id>")
def delete_document(collection_name, document_id):
    result = db[collection_name].delete_one({"_id": ObjectId(document_id)})
    if result.deleted_count == 0:
        return jsonify({"error": "Documento nao encontrado."}), 404

    return jsonify({"deleted": document_id})
