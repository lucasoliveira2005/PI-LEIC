#!/usr/bin/env python3
"""Shared environment variable parsing helpers."""

from __future__ import annotations

import os


def parse_non_negative_int_env(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None:
        return default

    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer, got: {raw}") from exc

    if value < 0:
        raise ValueError(f"{name} must be >= 0, got: {value}")

    return value


def parse_positive_int_env(name: str, default: int) -> int:
    value = parse_non_negative_int_env(name, default)
    if value <= 0:
        raise ValueError(f"{name} must be > 0, got: {value}")
    return value


def parse_non_negative_float_env(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None:
        return default

    try:
        value = float(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be a float, got: {raw}") from exc

    if value < 0:
        raise ValueError(f"{name} must be >= 0, got: {value}")

    return value


def parse_float_env(name: str, default: float) -> float:
    """Parse a float env var; allows negative values (e.g. sentinel -1 for disabled)."""
    raw = os.environ.get(name)
    if raw is None:
        return default

    try:
        return float(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be a float, got: {raw}") from exc


def parse_bool_env(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default

    return raw.strip().lower() not in {"0", "false", "no", "off"}
