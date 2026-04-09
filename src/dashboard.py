#!/usr/bin/env python3
import json
import os
from pathlib import Path

import matplotlib.animation as animation
import matplotlib.pyplot as plt

SCRIPT_DIR = Path(__file__).resolve().parent
LOG_FILE = Path(os.environ.get("METRICS_OUT", SCRIPT_DIR / "../metrics/gnb_metrics.jsonl"))

fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 8))
plt.subplots_adjust(hspace=0.4)

history_by_source = {}
last_timestamp_by_source = {}
source_colors = {}
palette = [
    "tab:blue",
    "tab:orange",
    "tab:green",
    "tab:red",
    "tab:brown",
    "tab:pink",
]


def get_source_color(source_id):
    if source_id not in source_colors:
        source_colors[source_id] = palette[len(source_colors) % len(palette)]
    return source_colors[source_id]


def extract_payload(entry):
    return entry.get("raw_payload") or entry.get("payload") or entry


def get_latest_cell_metrics(lines):
    latest_by_source = {}

    for line in lines:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        source_id = entry.get("source_id", "single")
        payload = extract_payload(entry)

        cells = payload.get("cells")
        if not cells:
            continue

        ue_list = cells[0].get("ue_list") or []
        if not ue_list:
            continue

        latest_by_source[source_id] = {
            "timestamp": entry.get("timestamp") or payload.get("timestamp"),
            "ue": ue_list[0],
        }

    return latest_by_source


def append_source_sample(source_id, ue_metrics):
    history = history_by_source.setdefault(
        source_id,
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
    if not LOG_FILE.exists():
        return

    try:
        with LOG_FILE.open("r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception:
        return

    if not lines:
        return

    latest_by_source = get_latest_cell_metrics(lines)
    if not latest_by_source:
        return

    for source_id, source_metrics in latest_by_source.items():
        latest_timestamp = source_metrics["timestamp"]
        if latest_timestamp and last_timestamp_by_source.get(source_id) == latest_timestamp:
            continue

        append_source_sample(source_id, source_metrics["ue"])
        if latest_timestamp:
            last_timestamp_by_source[source_id] = latest_timestamp

    # Gráfico de Bitrate
    ax1.clear()
    for source_id in sorted(history_by_source):
        history = history_by_source[source_id]
        color = get_source_color(source_id)
        ax1.plot(
            history["times"],
            history["dl_rates"],
            label=f"{source_id} DL",
            color=color,
            linewidth=2,
        )
        ax1.plot(
            history["times"],
            history["ul_rates"],
            label=f"{source_id} UL",
            color=color,
            linestyle="--",
            linewidth=2,
        )
    ax1.set_title("Performance de Dados em Tempo Real (5G NR)")
    ax1.set_ylabel("kbps")
    ax1.legend(loc='upper left')
    ax1.grid(True, alpha=0.3)

    # Gráfico de sinal
    ax2.clear()
    for source_id in sorted(history_by_source):
        history = history_by_source[source_id]
        color = get_source_color(source_id)
        ax2.fill_between(history["times"], history["signal_values"], color=color, alpha=0.15)
        ax2.plot(
            history["times"],
            history["signal_values"],
            label=f"{source_id} PUCCH/PUSCH SNR",
            color=color,
            linewidth=2,
        )
    ax2.set_title("Qualidade do Sinal")
    ax2.set_ylabel("dB")
    ax2.set_xlabel("Amostras (segundos)")
    ax2.legend(loc='upper left')
    ax2.grid(True, alpha=0.3)

# Atualização a cada 1000ms
ani = animation.FuncAnimation(fig, animate, interval=1000)

print(f"Monitorizando {LOG_FILE.resolve()}...")
plt.show()
