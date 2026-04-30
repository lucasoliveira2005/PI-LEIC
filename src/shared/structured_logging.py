#!/usr/bin/env python3
"""Small JSON logging helper for process stdout/stderr streams."""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, TextIO


def _json_safe(value: Any) -> Any:
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, dict):
        return {str(key): _json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_json_safe(item) for item in value]
    return str(value)


def emit_structured_log(
    event: str,
    message: str,
    *,
    level: str = "info",
    service: str | None = None,
    stream: TextIO | None = None,
    **fields: Any,
) -> None:
    """Emit one JSON log record.

    The helper intentionally writes directly to stdout/stderr instead of
    configuring global logging state; these scripts are launched under systemd
    and shell tests often import modules in-process.
    """

    payload: dict[str, Any] = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "level": level,
        "event": event,
        "message": message,
    }
    if service:
        payload["service"] = service

    for key, value in fields.items():
        if value is not None:
            payload[key] = _json_safe(value)

    output = stream if stream is not None else sys.stdout
    print(json.dumps(payload, sort_keys=True, ensure_ascii=False), file=output, flush=True)
