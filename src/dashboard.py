#!/usr/bin/env python3
import os
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import matplotlib.animation as animation
import matplotlib.pyplot as plt

from metrics_api import MetricsLogReader

LOG_FILE = Path(os.environ.get("METRICS_OUT", SCRIPT_DIR / "../metrics/gnb_metrics.jsonl"))
LOG_INCLUDE_ROTATED = os.environ.get("METRICS_LOG_INCLUDE_ROTATED", "1") != "0"
LOG_MAX_ARCHIVES = int(os.environ.get("METRICS_LOG_MAX_ARCHIVES", "5"))
SQLITE_ENABLED = os.environ.get("METRICS_SQLITE_ENABLED", "1") != "0"
SQLITE_PATH = Path(os.environ.get("METRICS_SQLITE_PATH", "/tmp/pi-leic-metrics.sqlite"))
READER = MetricsLogReader(
    LOG_FILE,
    include_rotated=LOG_INCLUDE_ROTATED,
    max_archives=LOG_MAX_ARCHIVES,
    sqlite_path=SQLITE_PATH if SQLITE_ENABLED else None,
    prefer_sqlite=SQLITE_ENABLED,
)

fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 8))
plt.subplots_adjust(hspace=0.4)

history_by_entity = {}
last_timestamp_by_entity = {}
entity_colors = {}
palette = [
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
    history["dl_rates"].append(ue_metrics.get("dl_brate", 0) / 1000)
    history["ul_rates"].append(ue_metrics.get("ul_brate", 0) / 1000)
    history["signal_values"].append(
        ue_metrics.get("pucch_snr_db", ue_metrics.get("pusch_snr_db", 0))
    )

    if len(history["times"]) > 50:
        history["times"].pop(0)
        history["dl_rates"].pop(0)
        history["ul_rates"].pop(0)
        history["signal_values"].pop(0)


def animate(_):
    try:
        latest_by_source = READER.latest_cells_by_source()
    except Exception:
        return
    if not latest_by_source:
        return

    for source_id, source_metrics in latest_by_source.items():
        latest_timestamp = source_metrics.get("timestamp")
        entities = source_metrics.get("entities") or []

        for entity in entities:
            ue_metrics = entity.get("ue") or {}
            if not isinstance(ue_metrics, dict):
                continue

            entity_key = parse_entity_key(source_id, entity)
            if latest_timestamp and last_timestamp_by_entity.get(entity_key) == latest_timestamp:
                continue

            append_entity_sample(entity_key, ue_metrics)
            if latest_timestamp:
                last_timestamp_by_entity[entity_key] = latest_timestamp

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

# Atualização a cada 1000ms
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
