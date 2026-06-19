# RANPilot — local-LLM agent (setup)

RANPilot answers questions about the 5G network in natural language (PT-PT). It calls the
REST API (`/health`, `/metrics`, `/alerts`), builds a **deterministic** technical summary in
Python, then asks a **local Ollama model** to phrase/interpret it. The LLM never fetches the
numbers itself (anti-hallucination), and never sees backend/transport details.

## 1) Install Ollama (Linux)

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama --version
```

If the service doesn't start automatically: `ollama serve` (leave that terminal open).

## 2) Create the RANPilot model

The agent uses a **custom model named `RANPilot`**, built from [`Modelfile`](Modelfile)
(`FROM llama3` + a PT-PT 5G/O-RAN system prompt).

```bash
ollama pull llama3                      # base model
ollama create RANPilot -f agent/Modelfile
ollama run RANPilot                     # optional: test it in the terminal
```

## 3) (Optional) activate the project venv

```bash
source src/.venv/bin/activate
```

The agent needs `flask` and `requests` (declared in the project `requirements.txt`).

## 4) Run the agent

```bash
python agent/agent.py
```

This starts the Flask server and opens the **RANPilot web UI** at `http://localhost:5000`:

- **Chat** tab — type a question in natural language, e.g. *"Como está a rede?"* or
  *"Há anomalias?"*. There are **no slash commands** — just ask in plain language.
- **Dashboard** tab — live Chart.js graphs (DL/UL throughput, SINR, BLER) polling the REST
  API every 2 s.

The same terminal also runs an interactive CLI loop (type a question, or `exit` to quit).

## Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `RAN_BACKEND` | `oai` | Selects the metric parser (`oai` / `srsran`) |
| `METRICS_API_BASE` | `http://localhost:8000` | REST API base URL the agent consumes |
| `AGENT_UI_PORT` | `5000` | Web UI port |

> Prerequisite: the REST API must be up (`bash src/launch_stack.sh`) and reachable at
> `METRICS_API_BASE`. If the API is down, the agent falls back to the most recent local
> observation files under `metrics/`.

## Common error

`command 'ollama' not found` → reopen the terminal, confirm with `ollama --version`, and add
the binary to `PATH` if needed.
