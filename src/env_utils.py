#!/usr/bin/env python3
"""Backward-compat shim — real implementation lives in src/shared/env_utils.py."""

from shared.env_utils import (  # noqa: F401, F403
    parse_bool_env,
    parse_float_env,
    parse_non_negative_float_env,
    parse_non_negative_int_env,
    parse_positive_int_env,
)
