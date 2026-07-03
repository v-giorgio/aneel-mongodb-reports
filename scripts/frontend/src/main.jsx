import React, { useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import "bootstrap/dist/css/bootstrap.min.css";
import "./styles.css";

const DEFAULT_API_URL = import.meta.env.VITE_API_URL || "http://localhost:5000";

const SAMPLE_DOCUMENT = {
  idEvento: "EVT000001",
  descricao: "Interna;Nao Programada;Meio Ambiente;Descarga Atmosferica",
  dataHoraInicio: "2025-06-14T15:45:20",
  dataHoraFim: "2025-06-14T19:53:00",
  duracaoMinutos: 247.67,
  gravidade: 5,
  conjuntoConsumidor: "Caiaponia",
  alimentador: "32",
  subestacao: "30",
  tipoInterrupcao: "Nao Programada",
  agenteRegulado: "EQUATORIAL GOIAS DISTRIBUIDORA DE ENERGIA S/A",
  siglaAgente: "EQUATORIAL GO",
};

function buildUrl(baseUrl, path, params = {}) {
  const url = new URL(path, baseUrl);
  Object.entries(params).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== "") {
      url.searchParams.set(key, value);
    }
  });
  return url.toString();
}

function App() {
  const [apiUrl, setApiUrl] = useState(DEFAULT_API_URL);
  const [collection, setCollection] = useState("interrupcoes");
  const [documentJson, setDocumentJson] = useState(JSON.stringify(SAMPLE_DOCUMENT, null, 2));
  const [bulkJson, setBulkJson] = useState(JSON.stringify([SAMPLE_DOCUMENT], null, 2));
  const [tipo, setTipo] = useState("nao_programada");
  const [inicio, setInicio] = useState("2025-01-01");
  const [fim, setFim] = useState("2025-12-31");
  const [conjuntoConsumidor, setConjuntoConsumidor] = useState("Caiaponia");
  const [siglaAgente, setSiglaAgente] = useState("EQUATORIAL GO");
  const [gravidade, setGravidade] = useState("3");
  const [agenteRegulado, setAgenteRegulado] = useState("");
  const [limit, setLimit] = useState("50");
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState(null);

  const collectionParam = useMemo(() => ({ collection }), [collection]);

  async function request(path, { method = "GET", params = {}, body } = {}) {
    setLoading(true);
    try {
      const url = buildUrl(apiUrl, path, { ...collectionParam, ...params });
      const response = await fetch(url, {
        method,
        headers: body ? { "Content-Type": "application/json" } : undefined,
        body: body ? JSON.stringify(body) : undefined,
      });
      const text = await response.text();
      const data = text ? JSON.parse(text) : {};
      setResult({ ok: response.ok, status: response.status, url, data });
    } catch (error) {
      setResult({ ok: false, status: "erro", url: "", data: { error: error.message } });
    } finally {
      setLoading(false);
    }
  }

  function parseJson(value, expectedType) {
    const parsed = JSON.parse(value);
    if (expectedType === "object" && (Array.isArray(parsed) || typeof parsed !== "object" || parsed === null)) {
      throw new Error("Informe um objeto JSON.");
    }
    if (expectedType === "array" && !Array.isArray(parsed)) {
      throw new Error("Informe uma lista JSON.");
    }
    return parsed;
  }

  function submitDocument() {
    try {
      request("/interrupcoes", { method: "POST", body: parseJson(documentJson, "object") });
    } catch (error) {
      setResult({ ok: false, status: "erro", url: "", data: { error: error.message } });
    }
  }

  function submitBulk() {
    try {
      request("/interrupcoes/bulk", { method: "POST", body: parseJson(bulkJson, "array") });
    } catch (error) {
      setResult({ ok: false, status: "erro", url: "", data: { error: error.message } });
    }
  }

  return (
    <main className="min-vh-100 bg-body-tertiary">
      <nav className="navbar navbar-expand-lg bg-white border-bottom sticky-top">
        <div className="container-fluid px-4">
          <span className="navbar-brand fw-semibold">BD2 - Monitoramento de Interrupcoes</span>
          <div className="d-flex gap-2 align-items-center">
            <span className="text-secondary small">API</span>
            <input
              className="form-control form-control-sm api-input"
              value={apiUrl}
              onChange={(event) => setApiUrl(event.target.value)}
            />
          </div>
        </div>
      </nav>

      <div className="container-fluid px-4 py-4">
        <div className="row g-4">
          <section className="col-12 col-xl-7">
            <div className="mb-3 d-flex flex-wrap gap-2 align-items-end">
              <div>
                <label className="form-label">Collection</label>
                <input className="form-control" value={collection} onChange={(event) => setCollection(event.target.value)} />
              </div>
              <button className="btn btn-outline-secondary" onClick={() => request("/health")}>Health</button>
              <button className="btn btn-outline-secondary" onClick={() => request("/cluster")}>Cluster</button>
            </div>

            <div className="row g-4">
              <div className="col-12">
                <div className="card shadow-sm">
                  <div className="card-header bg-white fw-semibold">6.1 Insercao</div>
                  <div className="card-body">
                    <label className="form-label">Documento JSON</label>
                    <textarea
                      className="form-control font-monospace json-editor"
                      value={documentJson}
                      onChange={(event) => setDocumentJson(event.target.value)}
                    />
                    <div className="d-flex gap-2 mt-3">
                      <button className="btn btn-primary" onClick={submitDocument}>Inserir um</button>
                      <button className="btn btn-outline-primary" onClick={submitBulk}>Inserir lista</button>
                    </div>
                  </div>
                </div>
              </div>

              <div className="col-12">
                <div className="card shadow-sm">
                  <div className="card-header bg-white fw-semibold">InsertMany</div>
                  <div className="card-body">
                    <label className="form-label">Lista JSON</label>
                    <textarea
                      className="form-control font-monospace bulk-editor"
                      value={bulkJson}
                      onChange={(event) => setBulkJson(event.target.value)}
                    />
                    <button className="btn btn-primary mt-3" onClick={submitBulk}>Enviar lista</button>
                  </div>
                </div>
              </div>
            </div>
          </section>

          <section className="col-12 col-xl-5">
            <div className="card shadow-sm mb-4">
              <div className="card-header bg-white fw-semibold">Consultas obrigatorias</div>
              <div className="card-body">
                <div className="row g-3">
                  <div className="col-md-6">
                    <label className="form-label">Tipo</label>
                    <select className="form-select" value={tipo} onChange={(event) => setTipo(event.target.value)}>
                      <option value="nao_programada">Nao Programada</option>
                      <option value="programada">Programada</option>
                    </select>
                  </div>
                  <div className="col-md-6">
                    <label className="form-label">Limite</label>
                    <input className="form-control" value={limit} onChange={(event) => setLimit(event.target.value)} />
                  </div>
                  <div className="col-12">
                    <button className="btn btn-outline-primary w-100" onClick={() => request("/interrupcoes/tipo", { params: { tipo, limit } })}>
                      6.2 Consultar por tipo
                    </button>
                  </div>

                  <div className="col-md-6">
                    <label className="form-label">Inicio</label>
                    <input className="form-control" value={inicio} onChange={(event) => setInicio(event.target.value)} />
                  </div>
                  <div className="col-md-6">
                    <label className="form-label">Fim</label>
                    <input className="form-control" value={fim} onChange={(event) => setFim(event.target.value)} />
                  </div>
                  <div className="col-12">
                    <button className="btn btn-outline-primary w-100" onClick={() => request("/interrupcoes/periodo", { params: { inicio, fim, limit } })}>
                      6.3 Consultar por periodo
                    </button>
                  </div>

                  <div className="col-md-6">
                    <label className="form-label">Conjunto consumidor</label>
                    <input className="form-control" value={conjuntoConsumidor} onChange={(event) => setConjuntoConsumidor(event.target.value)} />
                  </div>
                  <div className="col-md-6">
                    <label className="form-label">Sigla agente</label>
                    <input className="form-control" value={siglaAgente} onChange={(event) => setSiglaAgente(event.target.value)} />
                  </div>
                  <div className="col-12">
                    <button className="btn btn-outline-primary w-100" onClick={() => request("/interrupcoes/localizacao", { params: { conjuntoConsumidor, siglaAgente, limit } })}>
                      6.4 Consultar por localizacao
                    </button>
                  </div>

                  <div className="col-12">
                    <label className="form-label">Gravidade maior que</label>
                    <input className="form-control" value={gravidade} onChange={(event) => setGravidade(event.target.value)} />
                  </div>
                  <div className="col-12">
                    <button className="btn btn-outline-primary w-100" onClick={() => request("/interrupcoes/gravidade", { params: { minimo: gravidade, limit } })}>
                      6.5 Consultar por gravidade
                    </button>
                  </div>
                </div>
              </div>
            </div>

            <div className="card shadow-sm">
              <div className="card-header bg-white fw-semibold">6.6 Estatisticas</div>
              <div className="card-body">
                <label className="form-label">Agente regulado</label>
                <input
                  className="form-control mb-3"
                  value={agenteRegulado}
                  onChange={(event) => setAgenteRegulado(event.target.value)}
                />
                <div className="d-grid gap-2">
                  <button className="btn btn-outline-dark" onClick={() => request("/interrupcoes/estatisticas/tipo", { params: { agenteRegulado } })}>
                    Quantidade por tipo
                  </button>
                  <button className="btn btn-outline-dark" onClick={() => request("/interrupcoes/estatisticas/agente-regulado", { params: { agenteRegulado } })}>
                    Quantidade por agente regulado
                  </button>
                  <button className="btn btn-outline-dark" onClick={() => request("/interrupcoes/estatisticas/bairro", { params: { agenteRegulado } })}>
                    Quantidade por bairro
                  </button>
                  <button className="btn btn-outline-dark" onClick={() => request("/interrupcoes/estatisticas/evolucao-temporal", { params: { agenteRegulado } })}>
                    Evolucao temporal
                  </button>
                </div>
              </div>
            </div>
          </section>

          <section className="col-12">
            <div className="card shadow-sm">
              <div className="card-header bg-white d-flex justify-content-between align-items-center">
                <span className="fw-semibold">Resposta</span>
                {loading && <span className="spinner-border spinner-border-sm" />}
              </div>
              <div className="card-body">
                {result ? (
                  <>
                    <div className={`alert ${result.ok ? "alert-success" : "alert-danger"} py-2`}>
                      Status: {result.status}
                      {result.url && <span className="ms-2 text-break">{result.url}</span>}
                    </div>
                    <pre className="response-box">{JSON.stringify(result.data, null, 2)}</pre>
                  </>
                ) : (
                  <div className="text-secondary">Execute uma chamada para ver o retorno da API.</div>
                )}
              </div>
            </div>
          </section>
        </div>
      </div>
    </main>
  );
}

createRoot(document.getElementById("root")).render(<App />);
