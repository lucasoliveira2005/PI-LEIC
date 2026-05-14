#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VENV_PY="$REPO_ROOT/.venv/bin/python"
DASHBOARD_SCRIPT="$SCRIPT_DIR/dashboard.py"

if [[ ! -x "$VENV_PY" ]]; then
  echo "Python da venv não encontrado em: $VENV_PY" >&2
  exit 1
fi

if [[ ! -f "$DASHBOARD_SCRIPT" ]]; then
  echo "Dashboard script não encontrado: $DASHBOARD_SCRIPT" >&2
  exit 1
fi

if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
  echo "Sem DISPLAY/WAYLAND_DISPLAY neste terminal. Abre isto numa sessão gráfica." >&2
  exit 1
fi

echo "A parar dashboard service para evitar conflito de janela..."
systemctl --user stop pi-leic-dashboard.service >/dev/null 2>&1 || true

echo "A abrir Figure (dashboard.py) com métricas live..."
cd "$SCRIPT_DIR"
exec "$VENV_PY" "$DASHBOARD_SCRIPT"
