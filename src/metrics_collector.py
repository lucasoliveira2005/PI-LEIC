#!/usr/bin/env python3
"""Entry-point shim — delegates to src/collector/ package.

The real implementation lives in:
  src/collector/config.py      — environment-variable configuration
  src/collector/enrichment.py  — event enrichment and D1 contract field derivation
  src/collector/transport.py   — WebSocket source adapter (E2SM-KPM sibling lands in Phase 1)
  src/collector/storage.py     — JSONL rotation (EventWriter) and SQLite sink
  src/collector/worker.py      — source worker threads, watchdog, main()
"""

import sys
from pathlib import Path

_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

from collector import (  # noqa: E402, F401
    METRICS_SCHEMA_VERSION,
    METRICS_SILENCE_THRESHOLD_SECONDS,
    METRICS_SQLITE_ENABLED,
    METRICS_SQLITE_PATH,
    METRICS_SQLITE_RETENTION_INTERVAL_EVENTS,
    METRICS_SQLITE_RETENTION_MAX_AGE_DAYS,
    METRICS_SQLITE_RETENTION_MAX_ROWS,
    METRICS_SQLITE_RETENTION_VACUUM,
    METRICS_SQLITE_RETRY_COOLDOWN_SECONDS,
    METRICS_SQLITE_RETRY_MAX_FAILURES,
    METRICS_SQLITE_TIMEOUT_SECONDS,
    METRICS_WS_PING_INTERVAL_SECONDS,
    METRICS_WS_PING_TIMEOUT_SECONDS,
    OUT,
    RECONNECT_SECONDS,
    ROTATE_MAX_BYTES,
    ROTATE_MAX_FILES,
    SOURCES_CONFIG,
    EventWriter,
    MetricsSourceWorker,
    SourceTransportAdapter,
    SQLiteEventSink,
    WebSocketSourceAdapter,
    _watchdog_loop,
    build_transport_adapter,
    classify_event_type,
    enrich_event,
    extract_contract_fields,
    extract_context,
    load_sources,
    main,
    metric_family,
    required_source_keys,
    source_endpoint,
    summarize_event,
    websocket_keepalive_kwargs,
)

if __name__ == "__main__":
    main()
