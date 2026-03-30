#!/usr/bin/env python3
import matplotlib.pyplot as plt
import matplotlib.animation as animation
import json
import os
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
LOG_FILE = Path(os.environ.get("METRICS_OUT", SCRIPT_DIR / "../metrics/gnb_metrics.jsonl"))

fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 8))
plt.subplots_adjust(hspace=0.4)

times = []
dl_rates = []
ul_rates = []
snr_values = []

def animate(i):
    if not LOG_FILE.exists():
        return

    current_dl = 0
    current_ul = 0
    current_snr = 0

    try:
        with LOG_FILE.open("r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception:
        return

    if not lines:
        return

    # Última métrica válida
    for line in reversed(lines):
        try:
            data = json.loads(line)
            if 'cells' in data:
                ue = data['cells'][0]['ue_list'][0]
                current_dl = ue.get('dl_brate', 0) / 1000  # kbps
                current_ul = ue.get('ul_brate', 0) / 1000
                current_snr = ue.get('pusch_snr_db', 0)
                break
        except (json.JSONDecodeError, IndexError, KeyError):
            continue

    # Atualizar listas (máx 50 pontos)
    times.append(len(times))
    dl_rates.append(current_dl)
    ul_rates.append(current_ul)
    snr_values.append(current_snr)

    if len(times) > 50:
        times.pop(0)
        dl_rates.pop(0)
        ul_rates.pop(0)
        snr_values.pop(0)

    # Gráfico de Bitrate
    ax1.clear()
    ax1.plot(times, dl_rates, label='DL Bitrate (kbps)', color='blue', linewidth=2)
    ax1.plot(times, ul_rates, label='UL Bitrate (kbps)', color='green', linewidth=2)
    ax1.set_title("Performance de Dados em Tempo Real (5G NR)")
    ax1.set_ylabel("kbps")
    ax1.legend(loc='upper left')
    ax1.grid(True, alpha=0.3)

    # Gráfico de SNR
    ax2.clear()
    ax2.fill_between(times, snr_values, color='orange', alpha=0.3)
    ax2.plot(times, snr_values, label='PUSCH SNR (dB)', color='darkorange')
    ax2.set_title("Qualidade do Sinal (SNR)")
    ax2.set_ylabel("dB")
    ax2.set_xlabel("Amostras (segundos)")
    ax2.legend(loc='upper left')
    ax2.grid(True, alpha=0.3)

# Atualização a cada 1000ms
ani = animation.FuncAnimation(fig, animate, interval=1000)

print(f"Monitorizando {LOG_FILE.resolve()}...")
plt.show()