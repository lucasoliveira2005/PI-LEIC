from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import threading
import webbrowser
import uvicorn
import os
from pathlib import Path

APP = FastAPI()

APP.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

SCRIPT_DIR = Path(__file__).resolve().parent
STATIC_DIR = SCRIPT_DIR / "static"


@APP.get("/", response_class=HTMLResponse)
async def index():
    html_path = STATIC_DIR / "index.html"
    return HTMLResponse(content=html_path.read_text(encoding="utf-8"))


@APP.get("/summary")
def get_summary():
    # lazy import to avoid cycle with agent module
    try:
        # import the CLI module directly
        from agent.agent import build_network_summary

        summary = build_network_summary()
        return JSONResponse({"summary": summary})
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)


@APP.post("/ask")
async def ask(request: Request):
    data = await request.json()
    question = data.get("question", "")
    try:
        from agent.agent import build_network_summary, ask_llm_with_summary

        summary = build_network_summary()
        answer = ask_llm_with_summary(summary, question)
        return JSONResponse({"answer": answer})
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)


def _run_uvicorn(app, host: str = "127.0.0.1", port: int = 51723):
    uvicorn.run(app, host=host, port=port, log_level="info")


def start_ui(open_browser: bool = True, port: int = 51723):
    thread = threading.Thread(target=_run_uvicorn, args=(APP, "127.0.0.1", port), daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{port}/"
    if open_browser:
        try:
            webbrowser.open(url)
        except Exception:
            pass
    return url
