#!/usr/bin/env python3
"""Backward-compat shim — real implementation lives in src/shared/liveness.py."""

from shared.liveness import (  # noqa: F401
    FreshnessSettings,
    build_baseline_payload,
    coerce_float,
    coerce_int,
    evaluate_source_freshness,
    load_baseline_payload,
    settings_from_env,
    source_signature,
)
