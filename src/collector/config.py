"""Environment-variable configuration for the metrics collector."""

from __future__ import annotations

import os
import sys
from pathlib import Path

_COLLECTOR_DIR = Path(__file__).resolve().parent  # src/collector/
_SRC_DIR = _COLLECTOR_DIR.parent                  # src/
if str(_SRC_DIR) not in sys.path:
    sys.path.insert(0, str(_SRC_DIR))

from env_utils import (  # noqa: E402
    parse_bool_env,
    parse_non_negative_float_env,
    parse_non_negative_int_env,
    parse_positive_int_env,
)

SOURCES_CONFIG: Path = Path(
    os.environ.get("METRICS_SOURCES_CONFIG", str(_SRC_DIR / "../config/metrics_sources.json"))
)
OUT: Path = Path(
    os.environ.get("METRICS_OUT", str(_SRC_DIR / "../metrics/gnb_metrics.jsonl"))
)

ROTATE_MAX_BYTES: int = parse_non_negative_int_env("METRICS_ROTATE_MAX_BYTES", 50 * 1024 * 1024)
ROTATE_MAX_FILES: int = parse_non_negative_int_env("METRICS_ROTATE_MAX_FILES", 5)
METRICS_SQLITE_ENABLED: bool = parse_bool_env("METRICS_SQLITE_ENABLED", True)
METRICS_SQLITE_PATH: Path = Path(
    os.environ.get("METRICS_SQLITE_PATH", "/tmp/pi-leic-metrics.sqlite")
)
RECONNECT_SECONDS: float = parse_non_negative_float_env("METRICS_RECONNECT_SECONDS", 3.0)
METRICS_SQLITE_TIMEOUT_SECONDS: float = parse_non_negative_float_env(
    "METRICS_SQLITE_TIMEOUT_SECONDS", 5.0
)
METRICS_SQLITE_RETRY_MAX_FAILURES: int = parse_positive_int_env(
    "METRICS_SQLITE_RETRY_MAX_FAILURES", 5
)
METRICS_SQLITE_RETRY_COOLDOWN_SECONDS: float = parse_non_negative_float_env(
    "METRICS_SQLITE_RETRY_COOLDOWN_SECONDS", 10.0
)
METRICS_SQLITE_RETENTION_MAX_AGE_DAYS: float = parse_non_negative_float_env(
    "METRICS_SQLITE_RETENTION_MAX_AGE_DAYS", 0.0
)
METRICS_SQLITE_RETENTION_MAX_ROWS: int = parse_non_negative_int_env(
    "METRICS_SQLITE_RETENTION_MAX_ROWS", 200000
)
METRICS_SQLITE_RETENTION_INTERVAL_EVENTS: int = parse_positive_int_env(
    "METRICS_SQLITE_RETENTION_INTERVAL_EVENTS", 500
)
METRICS_SQLITE_RETENTION_VACUUM: bool = parse_bool_env("METRICS_SQLITE_RETENTION_VACUUM", False)
METRICS_SCHEMA_VERSION: str = (
    os.environ.get("METRICS_SCHEMA_VERSION", "1.0") or "1.0"
).strip() or "1.0"
METRICS_WS_PING_INTERVAL_SECONDS: float = parse_non_negative_float_env(
    "METRICS_WS_PING_INTERVAL_SECONDS", 15.0
)
METRICS_WS_PING_TIMEOUT_SECONDS: float = parse_non_negative_float_env(
    "METRICS_WS_PING_TIMEOUT_SECONDS", 5.0
)
METRICS_SILENCE_THRESHOLD_SECONDS: float = parse_non_negative_float_env(
    "METRICS_SILENCE_THRESHOLD_SECONDS", 30.0
)
# Internal watchdog poll interval — not user-configurable.
_WATCHDOG_POLL_SECONDS: float = 10.0

# Clamp ping timeout so it never exceeds the ping interval.
if (
    METRICS_WS_PING_INTERVAL_SECONDS > 0
    and METRICS_WS_PING_TIMEOUT_SECONDS > METRICS_WS_PING_INTERVAL_SECONDS
):
    METRICS_WS_PING_TIMEOUT_SECONDS = METRICS_WS_PING_INTERVAL_SECONDS
