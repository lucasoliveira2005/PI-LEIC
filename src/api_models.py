#!/usr/bin/env python3
"""Pydantic request/response models for the PI-LEIC REST API."""

from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel, Field, model_validator


class QueryRequest(BaseModel):
    question: str = Field(..., min_length=1, description="Operator question in natural language.")


class ActionBounds(BaseModel):
    min_value: float = Field(..., description="Lower allowed bound for proposed value.")
    max_value: float = Field(..., description="Upper allowed bound for proposed value.")


class ActionIntent(BaseModel):
    target: str = Field(
        ...,
        description="Target entity identifier, e.g. 'cell:gnb1:0' or 'ue:rnti:1234'.",
    )
    parameter: str = Field(..., description="Parameter name to modify, e.g. 'tx_power_dbm'.")
    unit: str = Field(..., description="Physical unit for the parameter value, e.g. 'dBm'.")
    proposed_value: float = Field(..., description="Desired new value for the parameter.")
    current_value: float = Field(..., description="Observed current value of the parameter.")
    bounds: ActionBounds = Field(..., description="Safety bounds — proposed value must lie within.")
    reason: str = Field(
        ...,
        min_length=10,
        description="Human-readable justification for the proposed change.",
    )
    safety_checks: List[str] = Field(
        ...,
        min_length=1,
        description="Named safety checks to execute before applying the change.",
    )
    dry_run: bool = Field(
        ...,
        description="When True, validate intent without applying the change.",
    )

    @model_validator(mode="after")
    def _validate_proposed_in_bounds(self) -> "ActionIntent":
        if not (self.bounds.min_value <= self.proposed_value <= self.bounds.max_value):
            raise ValueError(
                f"proposed_value {self.proposed_value} is outside bounds "
                f"[{self.bounds.min_value}, {self.bounds.max_value}]"
            )
        return self


class ActionRequest(BaseModel):
    request: str = Field(..., min_length=1, description="Natural-language action description.")
    approve: bool = Field(..., description="Explicit operator approval flag.")
    intent: Optional[ActionIntent] = Field(
        None,
        description="Structured action intent. Required when approve=True.",
    )
