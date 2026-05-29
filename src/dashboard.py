#!/usr/bin/env python3
"""Matplotlib live view for the local metrics PoC.

This is the browser-independent visualization surface used by the demo. It
reads the same JSONL/SQLite metrics store as the REST API.
"""
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from env_utils import parse_bool_env, parse_non_negative_int_env
from metrics_api import MetricsLogReader

SCRIPT_DIR = Path(__file__).resolve().parent

LOG_FILE: Path = Path(os.environ.get("METRICS_OUT", str(SCRIPT_DIR / "../metrics/gnb_metrics.jsonl")))
LOG_INCLUDE_ROTATED: bool = parse_bool_env("METRICS_LOG_INCLUDE_ROTATED", True)
LOG_MAX_ARCHIVES: int = parse_non_negative_int_env("METRICS_LOG_MAX_ARCHIVES", 5)
SQLITE_ENABLED: bool = parse_bool_env("METRICS_SQLITE_ENABLED", True)
SQLITE_PATH: Path = Path(os.environ.get("METRICS_SQLITE_PATH", "/tmp/pi-leic-metrics.sqlite"))

READER: Optional[MetricsLogReader] = None
fig: Optional[Any] = None
ax1: Optional[Any] = None
ax2: Optional[Any] = None
ani: Optional[Any] = None
_animation: Optional[Any] = None
_pyplot: Optional[Any] = None
_reader_error_reported: bool = False

history_by_entity: Dict[Tuple, Dict[str, List]] = {}
last_sample_signature_by_entity: Dict[Tuple, str] = {}
entity_colors: Dict[Tuple, str] = {}
palette: List[str] = [
    "tab:blue",
    "tab:orange",
    "tab:green",
    "tab:red",
    "tab:brown",
    "tab:pink",
]


def get_entity_color(entity_key):
    if entity_key not in entity_colors:
        entity_colors[entity_key] = palette[len(entity_colors) % len(palette)]
    return entity_colors[entity_key]


def entity_label(entity_key):
    source_id, cell_index, ue_identity = entity_key
    return f"{source_id} c{cell_index} {ue_identity}"


def parse_entity_key(source_id, entity):
    cell_index = entity.get("cell_index", 0)
    if not isinstance(cell_index, int):
        try:
            cell_index = int(cell_index)
        except (TypeError, ValueError):
            cell_index = 0

    ue_identity = entity.get("ue_identity")
    if not ue_identity:
        ue_index = entity.get("ue_index", 0)
        ue_identity = f"cell{cell_index}-ue{ue_index}"

    return source_id, cell_index, str(ue_identity)


def _dl_kbps(ue_metrics: Dict[str, Any]) -> float:
    # OAI: dl_goodput_mbps is canonical Mbps — prefer it to avoid unit ambiguity
    # in synthesized dl_brate values from older stored rows.
    if ue_metrics.get("dl_goodput_mbps") is not None:
        return ue_metrics["dl_goodput_mbps"] * 1000
    # srsRAN: dl_brate in bits/s  →  ÷1000 = kbps
    if ue_metrics.get("dl_brate") is not None:
        return ue_metrics["dl_brate"] / 1000
    return 0.0


def _ul_kbps(ue_metrics: Dict[str, Any]) -> float:
    if ue_metrics.get("ul_goodput_mbps") is not None:
        return ue_metrics["ul_goodput_mbps"] * 1000
    if ue_metrics.get("ul_brate") is not None:
        return ue_metrics["ul_brate"] / 1000
    return 0.0


def _snr_db(ue_metrics: Dict[str, Any]) -> float:
    # srsRAN uses pucch_snr_db / pusch_snr_db; OAI uses ul_snr_db / sinr_db
    for key in ("pucch_snr_db", "pusch_snr_db", "ul_snr_db", "sinr_db"):
        val = ue_metrics.get(key)
        if val is not None:
            return float(val)
    return 0.0


def append_entity_sample(entity_key, ue_metrics):
    history = history_by_entity.setdefault(
        entity_key,
        {
            "times": [],
            "dl_rates": [],
            "ul_rates": [],
            "signal_values": [],
        },
    )

    next_time = history["times"][-1] + 1 if history["times"] else 0
    history["times"].append(next_time)
    history["dl_rates"].append(_dl_kbps(ue_metrics))
    history["ul_rates"].append(_ul_kbps(ue_metrics))
    history["signal_values"].append(_snr_db(ue_metrics))

    if len(history["times"]) > 50:
        history["times"].pop(0)
        history["dl_rates"].pop(0)
        history["ul_rates"].pop(0)
        history["signal_values"].pop(0)


def build_entity_sample_signature(latest_timestamp, ue_metrics):
    if latest_timestamp not in (None, ""):
        return f"ts:{latest_timestamp}"

    # Some payloads can omit event timestamps. In that case, dedupe by metrics
    # content so repeated refreshes do not append the same sample indefinitely.
    return "payload:" + json.dumps(ue_metrics, sort_keys=True, ensure_ascii=False)


def animate(_):
    global _reader_error_reported

    if READER is None or ax1 is None or ax2 is None:
        return

    try:
        latest_by_source = READER.latest_cells_by_source()
    except Exception as exc:  # noqa: BLE001
        if not _reader_error_reported:
            print(f"Failed to read latest metrics snapshot: {exc}", file=sys.stderr)
            _reader_error_reported = True
        latest_by_source = {}

    _reader_error_reported = False
    if not latest_by_source:
        ax1.clear()
        ax2.clear()
        ax1.set_title("Performance de Dados em Tempo Real (5G NR)")
        ax1.set_ylabel("kbps")
        ax1.text(
            0.5, 0.5, "Waiting for metrics...",
            transform=ax1.transAxes,
            ha="center", va="center", fontsize=12, color="gray",
        )
        ax2.set_title("Qualidade do Sinal")
        ax2.set_ylabel("dB")
        ax2.set_xlabel("Amostras (segundos)")
        return

    for source_id, source_metrics in latest_by_source.items():
        latest_timestamp = source_metrics.get("timestamp")
        entities = source_metrics.get("entities") or []

        for entity in entities:
            ue_metrics = entity.get("ue") or {}
            if not isinstance(ue_metrics, dict):
                continue

            entity_key = parse_entity_key(source_id, entity)
            sample_signature = build_entity_sample_signature(latest_timestamp, ue_metrics)
            if last_sample_signature_by_entity.get(entity_key) == sample_signature:
                continue

            append_entity_sample(entity_key, ue_metrics)
            last_sample_signature_by_entity[entity_key] = sample_signature

    # Gráfico de Bitrate
    ax1.clear()
    for entity_key in sorted(history_by_entity):
        history = history_by_entity[entity_key]
        color = get_entity_color(entity_key)
        label = entity_label(entity_key)
        ax1.plot(
            history["times"],
            history["dl_rates"],
            label=f"{label} DL",
            color=color,
            linewidth=2,
        )
        ax1.plot(
            history["times"],
            history["ul_rates"],
            label=f"{label} UL",
            color=color,
            linestyle="--",
            linewidth=2,
        )
    ax1.set_title("Performance de Dados em Tempo Real (5G NR)")
    ax1.set_ylabel("kbps")
    if history_by_entity:
        ax1.legend(loc='upper left')
    ax1.grid(True, alpha=0.3)

    # Gráfico de sinal
    ax2.clear()
    for entity_key in sorted(history_by_entity):
        history = history_by_entity[entity_key]
        color = get_entity_color(entity_key)
        label = entity_label(entity_key)
        ax2.fill_between(history["times"], history["signal_values"], color=color, alpha=0.15)
        ax2.plot(
            history["times"],
            history["signal_values"],
            label=f"{label} PUCCH/PUSCH SNR",
            color=color,
            linewidth=2,
        )
    ax2.set_title("Qualidade do Sinal")
    ax2.set_ylabel("dB")
    ax2.set_xlabel("Amostras (segundos)")
    if history_by_entity:
        ax2.legend(loc='upper left')
    ax2.grid(True, alpha=0.3)


def main():
    global READER, fig, ax1, ax2, ani, _animation, _pyplot

    import matplotlib.animation as animation
    import matplotlib.pyplot as plt

    _animation = animation
    _pyplot = plt
    READER = MetricsLogReader(
        LOG_FILE,
        include_rotated=LOG_INCLUDE_ROTATED,
        max_archives=LOG_MAX_ARCHIVES,
        sqlite_path=SQLITE_PATH if SQLITE_ENABLED else None,
        prefer_sqlite=SQLITE_ENABLED,
    )

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 8))
    plt.subplots_adjust(hspace=0.4)

    # Keep a module reference so the animation object is not garbage-collected.
    ani = animation.FuncAnimation(fig, animate, interval=1000)

    print(f"Monitorizando {LOG_FILE.resolve()}...")
    if LOG_INCLUDE_ROTATED:
        print(
            "Leitura de métricas inclui ficheiros rotacionados "
            f"(até {LOG_MAX_ARCHIVES} arquivos)."
        )
    if SQLITE_ENABLED:
        print(f"Leitura preferencial via SQLite: {SQLITE_PATH}")
    else:
        print("Leitura por SQLite desativada; uso de JSONL direto.")
    print("Visualização multi-origem/multi-UE ativa.")
    plt.show()


if __name__ == "__main__":
    main()
