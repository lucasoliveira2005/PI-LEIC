"""Shared cross-cutting utilities: env parsing, entity identity, freshness contract."""

import sys
from pathlib import Path

_SRC_DIR = Path(__file__).resolve().parent.parent  # src/shared/ → src/
if str(_SRC_DIR) not in sys.path:
    sys.path.insert(0, str(_SRC_DIR))
