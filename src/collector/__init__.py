"""Metrics collector package — data-ingestion layer for the PI-LEIC platform."""

from .config import (  # noqa: F401
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
)
from .enrichment import (  # noqa: F401
    classify_event_type,
    enrich_event,
    extract_contract_fields,
    extract_context,
    load_sources,
    metric_family,
    required_source_keys,
    source_endpoint,
    summarize_event,
)
from .storage import EventWriter, SQLiteEventSink  # noqa: F401
from .transport import (  # noqa: F401
    SourceTransportAdapter,
    WebSocketSourceAdapter,
    build_transport_adapter,
    websocket_keepalive_kwargs,
)
from .worker import MetricsSourceWorker, _watchdog_loop, main  # noqa: F401
