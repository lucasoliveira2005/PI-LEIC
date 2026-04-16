import subprocess
import json
import os
import time
from pathlib import Path
from typing import Optional

MODEL_NAME = os.environ.get("OLLAMA_MODEL", "llama3.2:1b")
DEFAULT_TIMEOUT = 45
RETRY_TIMEOUT = 45
METRICS_LLM_TIMEOUT = int(os.environ.get("METRICS_LLM_TIMEOUT", "75"))
METRICS_FILE = Path(os.environ.get("METRICS_OUT", "metrics/gnb_metrics.jsonl"))

METRIC_CONTEXT = {
    "downlink_average_latency_us": "Tempo médio de processamento/entrega no downlink, em microssegundos. Menor é melhor.",
    "downlink_average_throughput_mbps": "Taxa média de débito no downlink, em Mbps. Maior é melhor.",
    "uplink_sinr_db": "Relação sinal-ruído no uplink, em dB. Valores baixos indicam sinal fraco.",
    "uplink_bler_ratio": "Block Error Rate no uplink, em proporção. Quanto maior, pior a qualidade.",
    "cell_pucch_usage_percent": "Ocupação média do PUCCH, em percentagem. Valores altos podem indicar carga no canal de controlo.",
    "cell_average_latency_unknown": "Métrica de latência da célula cuja unidade original não está explícita no snapshot; o valor é apresentado sem assumir unidade.",
}


def _looks_like_echo(user_prompt, llm_output):
    prompt_norm = " ".join(user_prompt.strip().lower().split())
    output_norm = " ".join(llm_output.strip().lower().split())
    return output_norm == prompt_norm or output_norm in {
        f"responde: {prompt_norm}",
        f"explica: {prompt_norm}",
    }


def analyze_state(state):
    congestion = state["prb_usage"] > 80
    handover = state["sinr"] == "low"
    return congestion, handover


def _read_latest_metrics_snapshot() -> Optional[dict]:
    if not METRICS_FILE.exists():
        return None

    try:
        with METRICS_FILE.open("r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return None

    snapshot = {}

    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue

        if not isinstance(obj, dict):
            continue

        if "timestamp" not in snapshot and obj.get("timestamp") is not None:
            snapshot["timestamp"] = obj["timestamp"]

        for key in ("du_low", "cells", "du", "du_high"):
            if key in obj and key not in snapshot:
                snapshot[key] = obj[key]

        if "du_low" in snapshot and ("cells" in snapshot or "du" in snapshot):
            # We have the core sections needed for a meaningful analysis.
            break

    return snapshot or None


def _read_latest_metrics_object() -> Optional[dict]:
    return _read_latest_metrics_snapshot()


def _prune_none(value):
    if isinstance(value, dict):
        cleaned = {key: _prune_none(item) for key, item in value.items()}
        return {key: item for key, item in cleaned.items() if item not in (None, {}, [], ())}

    if isinstance(value, list):
        cleaned_list = [_prune_none(item) for item in value]
        return [item for item in cleaned_list if item not in (None, {}, [], ())]

    return value


def _metric(value, unit: str, precision: Optional[int] = None):
    if value is None:
        return None

    if isinstance(value, (int, float)) and precision is not None:
        value = round(float(value), precision)

    return {"value": value, "unit": unit}


def _normalize_du_low(du_low: dict) -> dict:
    dl = du_low.get("dl", {}) if isinstance(du_low.get("dl"), dict) else {}
    ul = du_low.get("ul", {}) if isinstance(du_low.get("ul"), dict) else {}
    ul_efficiency = ul.get("algo_efficiency", {}) if isinstance(ul.get("algo_efficiency"), dict) else {}

    return _prune_none(
        {
            "downlink": {
                "average_latency_us": _metric(dl.get("average_latency_us"), "us", 3),
                "average_throughput_mbps": _metric(dl.get("average_throughput_mbps"), "Mbps", 3),
                "cpu_usage_percent": _metric(dl.get("cpu_usage_percent"), "percent", 6),
                "max_latency_us": _metric(dl.get("max_latency_us"), "us", 3),
                "fec_average_throughput_mbps": _metric(
                    (dl.get("fec", {}) if isinstance(dl.get("fec"), dict) else {}).get("average_throughput_mbps"),
                    "Mbps",
                    3,
                ),
            },
            "uplink": {
                "sinr_db": _metric(ul_efficiency.get("sinr_db"), "dB", 3),
                "bler_ratio": _metric(ul_efficiency.get("bler"), "ratio", 4),
                "evm_ratio": _metric(ul_efficiency.get("evm"), "ratio", 4),
                "average_latency_us": _metric(ul.get("average_latency_us"), "us", 3),
                "average_throughput_mbps": _metric(ul.get("average_throughput_mbps"), "Mbps", 3),
            },
        }
    )


def _normalize_cells(cells: list) -> list:
    normalized_cells = []
    for cell in cells:
        if not isinstance(cell, dict):
            continue

        cell_metrics = cell.get("cell_metrics", {}) if isinstance(cell.get("cell_metrics"), dict) else {}
        normalized_cells.append(
            _prune_none(
                {
                    "pci": _metric(cell_metrics.get("pci"), "pci", 0),
                    "average_latency": _metric(cell_metrics.get("average_latency"), "unidade desconhecida", 3),
                    "max_latency": _metric(cell_metrics.get("max_latency"), "unidade desconhecida", 3),
                    "pucch_tot_rb_usage_avg": _metric(cell_metrics.get("pucch_tot_rb_usage_avg"), "percent", 3),
                    "avg_prach_delay": _metric(cell_metrics.get("avg_prach_delay"), "unidade desconhecida", 3),
                    "late_dl_harqs": _metric(cell_metrics.get("late_dl_harqs"), "count", 0),
                    "late_ul_harqs": _metric(cell_metrics.get("late_ul_harqs"), "count", 0),
                    "error_indication_count": _metric(cell_metrics.get("error_indication_count"), "count", 0),
                    "latency_histogram": _metric(cell_metrics.get("latency_histogram"), "count"),
                }
            )
        )

    return normalized_cells


def _normalize_du(du: dict) -> dict:
    du_high = du.get("du_high", {}) if isinstance(du.get("du_high"), dict) else {}
    mac = du_high.get("mac", {}) if isinstance(du_high.get("mac"), dict) else {}
    dl_entries = mac.get("dl", []) if isinstance(mac.get("dl"), list) else []

    normalized_dl = []
    for entry in dl_entries:
        if not isinstance(entry, dict):
            continue
        normalized_dl.append(
            _prune_none(
                {
                    "pci": _metric(entry.get("pci"), "pci", 0),
                    "average_latency_us": _metric(entry.get("average_latency_us"), "us", 3),
                    "max_latency_us": _metric(entry.get("max_latency_us"), "us", 3),
                    "min_latency_us": _metric(entry.get("min_latency_us"), "us", 3),
                    "cpu_usage_percent": _metric(entry.get("cpu_usage_percent"), "percent", 6),
                }
            )
        )

    return _prune_none({"high": {"mac_dl": normalized_dl}})


def normalize_metrics(metrics_obj: dict) -> dict:
    normalized = {"timestamp": metrics_obj.get("timestamp")}

    du_low = metrics_obj.get("du_low")
    if isinstance(du_low, dict):
        normalized["du_low"] = _normalize_du_low(du_low)

    cells = metrics_obj.get("cells")
    if isinstance(cells, list):
        normalized["cells"] = _normalize_cells(cells)

    du = metrics_obj.get("du")
    if isinstance(du, dict):
        normalized["du"] = _normalize_du(du)

    du_high = metrics_obj.get("du_high")
    if isinstance(du_high, dict):
        normalized["du_high"] = _normalize_du({"du_high": du_high})

    return _prune_none(normalized)


def _interpret_status(value, good_threshold=None, moderate_threshold=None, higher_is_better=False):
    if value is None:
        return None

    if higher_is_better:
        if good_threshold is not None and value > good_threshold:
            return "good"
        if moderate_threshold is not None and value > moderate_threshold:
            return "moderate"
        return "bad"

    if good_threshold is not None and value < good_threshold:
        return "good"
    if moderate_threshold is not None and value <= moderate_threshold:
        return "moderate"
    return "high"


def interpret_metrics(summary: dict) -> dict:
    interpreted = {}

    du_low = summary.get("du_low", {}) if isinstance(summary.get("du_low"), dict) else {}
    downlink = du_low.get("downlink", {}) if isinstance(du_low.get("downlink"), dict) else {}
    uplink = du_low.get("uplink", {}) if isinstance(du_low.get("uplink"), dict) else {}

    dl_latency = downlink.get("average_latency_us")
    if isinstance(dl_latency, dict) and isinstance(dl_latency.get("value"), (int, float)):
        value = float(dl_latency["value"])
        interpreted["downlink_latency_us"] = {
            "value": _metric(value, "us", 3)["value"],
            "unit": "us",
            "status": "baixo" if value < 1000 else "moderado" if value <= 10000 else "alto",
        }

    dl_throughput = downlink.get("average_throughput_mbps")
    if isinstance(dl_throughput, dict) and isinstance(dl_throughput.get("value"), (int, float)):
        value = float(dl_throughput["value"])
        interpreted["downlink_throughput_mbps"] = {
            "value": _metric(value, "Mbps", 3)["value"],
            "unit": "Mbps",
            "status": "não classificado",
        }

    sinr = uplink.get("sinr_db")
    if isinstance(sinr, dict) and isinstance(sinr.get("value"), (int, float)):
        value = float(sinr["value"])
        interpreted["uplink_sinr_db"] = {
            "value": _metric(value, "dB", 3)["value"],
            "unit": "dB",
            "status": "baixo" if value < 8 else "médio" if value <= 18 else "alto",
        }

    bler = uplink.get("bler_ratio")
    if isinstance(bler, dict) and isinstance(bler.get("value"), (int, float)):
        value = float(bler["value"])
        interpreted["uplink_bler_ratio"] = {
            "value": _metric(value, "ratio", 4)["value"],
            "unit": "ratio",
            "status": "alto" if value > 0.1 else "moderado" if value > 0 else "bom",
        }

    cpu = downlink.get("cpu_usage_percent")
    if isinstance(cpu, dict) and isinstance(cpu.get("value"), (int, float)):
        value = float(cpu["value"])
        interpreted["downlink_cpu_usage_percent"] = {
            "value": _metric(value, "percent", 6)["value"],
            "unit": "%",
            "status": "alto" if value > 80 else "médio" if value > 50 else "baixo",
        }

    cells = summary.get("cells", []) if isinstance(summary.get("cells"), list) else []
    if cells:
        first_cell = cells[0] if isinstance(cells[0], dict) else {}
        cell_latency = first_cell.get("average_latency")
        if isinstance(cell_latency, dict) and isinstance(cell_latency.get("value"), (int, float)):
            interpreted["cell_average_latency"] = {
                "value": cell_latency["value"],
                "unit": cell_latency.get("unit", "unidade desconhecida"),
                "status": "não classificado",
            }

        pucch_usage = first_cell.get("pucch_tot_rb_usage_avg")
        if isinstance(pucch_usage, dict) and isinstance(pucch_usage.get("value"), (int, float)):
            value = float(pucch_usage["value"])
            interpreted["cell_pucch_usage_percent"] = {
                "value": _metric(value, "percent", 3)["value"],
                "unit": "%",
                "status": "baixo" if value < 30 else "médio" if value <= 70 else "alto",
            }

    interpreted["summary"] = {
        "timestamp": summary.get("timestamp"),
        "has_cells": bool(cells),
        "has_du_low": bool(du_low),
        "has_signal_metric": "uplink_sinr_db" in interpreted,
        "has_latency_metric": "downlink_latency_us" in interpreted,
    }

    return _prune_none(interpreted)


def metrics_are_sufficient(normalized: dict, interpreted: dict) -> tuple[bool, str]:
    signal_metric = interpreted.get("uplink_sinr_db")
    latency_metric = interpreted.get("downlink_latency_us")
    bler_metric = interpreted.get("uplink_bler_ratio")
    cell_metric = interpreted.get("cell_pucch_usage_percent")

    present_metrics = [metric for metric in (signal_metric, latency_metric, bler_metric, cell_metric) if metric is not None]
    if len(present_metrics) < 2:
        return False, "poucas métricas úteis para uma análise fiável"

    if signal_metric is None and latency_metric is None:
        return False, "falta pelo menos um indicador de sinal ou latência"

    return True, "ok"


def build_metrics_llm_prompt(metrics_text: str) -> str:
    return f"""
Recebes um estado de rede já interpretado.

REGRAS OBRIGATÓRIAS:

* NÃO alteres classificações (baixo, moderado, bom, etc.)
* NÃO inventes métricas
* NÃO tires conclusões que contradigam "Anomalia crítica"
* Se existir "Anomalia crítica", a conclusão NÃO pode dizer que está tudo normal
* NÃO mistures métricas (latência ≠ sinal)

Estado da rede:
{metrics_text}

Tarefa:
Escreve um resumo MUITO curto (2-3 linhas) que:

* respeite exatamente os dados
* mencione a principal anomalia (se existir)
* não invente nada

Se não conseguires garantir consistência, responde apenas:
"Resumo indisponível por inconsistência de dados"
"""


def _extract_json_payload(text: str):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start == -1 or end == -1 or end <= start:
            return None
        try:
            return json.loads(text[start : end + 1])
        except json.JSONDecodeError:
            return None


def _format_metrics_fallback_report(interpreted: dict) -> str:
    signal = interpreted.get("uplink_sinr_db")
    latency = interpreted.get("downlink_latency_us")
    throughput = interpreted.get("downlink_throughput_mbps")
    bler = interpreted.get("uplink_bler_ratio")
    cell_usage = interpreted.get("cell_pucch_usage_percent")

    signal_status = signal.get("status") if isinstance(signal, dict) else "não disponível"
    signal_value = signal.get("value") if isinstance(signal, dict) else None
    latency_status = latency.get("status") if isinstance(latency, dict) else "não disponível"
    latency_value = latency.get("value") if isinstance(latency, dict) else None
    throughput_value = throughput.get("value") if isinstance(throughput, dict) else None
    bler_status = bler.get("status") if isinstance(bler, dict) else "não disponível"
    bler_value = bler.get("value") if isinstance(bler, dict) else None
    pucch_status = cell_usage.get("status") if isinstance(cell_usage, dict) else "não disponível"
    pucch_value = cell_usage.get("value") if isinstance(cell_usage, dict) else None

    anomalies = []
    if signal_status == "low":
        anomalies.append("SINR baixo")
    if latency_status == "high":
        anomalies.append("latência DL elevada")
    if bler_status == "bad":
        anomalies.append("BLER elevado")
    if pucch_status == "high":
        anomalies.append("ocupação do PUCCH elevada")
    if not anomalies:
        anomalies.append("sem anomalias fortes visíveis")

    return (
        f"Sinal: {signal_status} (SINR: {_format_float(signal_value)} dB). "
        f"Latência DL: {latency_status} (média: {_format_float(latency_value)} us). "
        f"Throughput DL: {_format_float(throughput_value)} Mbps. "
        f"BLER UL: {bler_status} (valor: {_format_float(bler_value)}). "
        f"PUCCH: {pucch_status} (uso médio: {_format_float(pucch_value)}%). "
        f"Anomalias: {', '.join(anomalies)}."
    )


def _format_metrics_deterministic_report(interpreted: dict) -> str:
    def _metric_parts(metric: Optional[dict], default_unit: str, default_status: str = "não classificado"):
        if not isinstance(metric, dict):
            return None, default_unit, "não disponível"
        value = metric.get("value")
        unit = metric.get("unit") or default_unit
        status = metric.get("status") or default_status
        return value, unit, status

    def _format_line(name: str, status: str, label: str, value, unit: str) -> str:
        if value is None:
            return f"{name}: {status} | {label}: não disponível {unit}".strip()
        return f"{name}: {status} | {label}: {_format_float(value)} {unit}"

    signal = interpreted.get("uplink_sinr_db")
    latency = interpreted.get("downlink_latency_us")
    throughput = interpreted.get("downlink_throughput_mbps")
    bler = interpreted.get("uplink_bler_ratio")
    cpu = interpreted.get("downlink_cpu_usage_percent")
    cell_latency = interpreted.get("cell_average_latency")
    cell_usage = interpreted.get("cell_pucch_usage_percent")

    signal_value, signal_unit, signal_status = _metric_parts(signal, "dB")
    latency_value, latency_unit, latency_status = _metric_parts(latency, "us")
    throughput_value, throughput_unit, throughput_status = _metric_parts(throughput, "Mbps")
    bler_value, bler_unit, bler_status = _metric_parts(bler, "ratio")
    cpu_value, cpu_unit, cpu_status = _metric_parts(cpu, "%")
    cell_latency_value, cell_latency_unit, cell_latency_status = _metric_parts(cell_latency, "unidade desconhecida")
    cell_usage_value, cell_usage_unit, cell_usage_status = _metric_parts(cell_usage, "%")

    anomaly_lines = []
    if signal_status == "baixo":
        anomaly_lines.append("Anomalia crítica: SINR baixo (impacto na qualidade uplink)")
    if latency_status == "alto":
        anomaly_lines.append("Aviso: latência DL elevada (possível impacto no tempo de resposta)")
    if bler_status == "alto":
        anomaly_lines.append("Anomalia crítica: BLER UL elevado (erros frequentes no uplink)")
    if cell_usage_status == "alto":
        anomaly_lines.append("Aviso: utilização PUCCH elevada (canal de controlo com carga)")
    if cpu_status == "alto":
        anomaly_lines.append("Aviso: uso de CPU (DL) elevado (pode degradar desempenho)")
    if not anomaly_lines:
        anomaly_lines.append("Sem anomalias")

    insight_lines = generate_insights(interpreted)

    lines = [
        _format_line("Sinal UL", signal_status, "SINR", signal_value, signal_unit),
        _format_line("Latência DL", latency_status, "média", latency_value, latency_unit),
        _format_line("Throughput DL", throughput_status, "média", throughput_value, throughput_unit),
        _format_line("BLER UL", bler_status, "valor", bler_value, bler_unit),
        _format_line("Uso de CPU (DL)", cpu_status, "valor", cpu_value, cpu_unit),
        _format_line("Latência da célula", cell_latency_status, "média", cell_latency_value, cell_latency_unit),
        _format_line("Utilização PUCCH", cell_usage_status, "valor", cell_usage_value, cell_usage_unit),
    ]

    lines.extend(["", *anomaly_lines])
    lines.extend(insight_lines)

    return "\n".join(lines)


def generate_insights(metrics: dict) -> list[str]:
    insights = []

    sinr = metrics.get("uplink_sinr_db") if isinstance(metrics.get("uplink_sinr_db"), dict) else {}
    bler = metrics.get("uplink_bler_ratio") if isinstance(metrics.get("uplink_bler_ratio"), dict) else {}
    latency = metrics.get("downlink_latency_us") if isinstance(metrics.get("downlink_latency_us"), dict) else {}
    cpu = metrics.get("downlink_cpu_usage_percent") if isinstance(metrics.get("downlink_cpu_usage_percent"), dict) else {}

    sinr_status = sinr.get("status")
    bler_value = bler.get("value")
    latency_status = latency.get("status")
    cpu_status = cpu.get("status")

    if sinr_status == "baixo" and isinstance(bler_value, (int, float)) and float(bler_value) == 0.0:
        insights.append("Nota: Apesar do SINR baixo, não há erros UL (BLER=0), situação estável")

    if latency_status == "alto" and cpu_status == "baixo":
        insights.append("Nota: Latência DL alta com CPU baixa sugere limitação fora do processamento local")

    if not insights:
        insights.append("Nota: Sem correlações relevantes detetadas entre as métricas disponíveis")

    return insights


def _json_field_has_useful_text(value) -> bool:
    if not isinstance(value, str):
        return False

    text = " ".join(value.strip().split()).lower()
    if not text or text in {"não disponível", "nao disponivel", "n/a", "null", "none"}:
        return False

    generic_markers = {
        "payload não contém informações",
        "payload nao contem informacoes",
        "sem dados suficientes",
        "não foi possível",
        "nao foi possivel",
    }
    return not any(marker in text for marker in generic_markers)


def _is_llm_summary_consistent(summary: str, metrics_text: str) -> bool:
    if not summary:
        return False

    stripped = summary.strip()
    if stripped == "Resumo indisponível por inconsistência de dados":
        return True

    non_empty_lines = [line for line in (line.strip() for line in stripped.splitlines()) if line]
    if len(non_empty_lines) < 2 or len(non_empty_lines) > 3:
        return False

    summary_lower = stripped.lower()
    has_critical = "anomalia crítica" in metrics_text.lower()
    if has_critical and (
        "está tudo normal" in summary_lower
        or "tudo normal" in summary_lower
        or "sem anomalias" in summary_lower
    ):
        return False

    if has_critical and "anomalia" not in summary_lower:
        return False

    return True


def analyze_metrics_with_llm(metrics_obj: dict) -> Optional[str]:
    normalized = normalize_metrics(metrics_obj)
    interpreted = interpret_metrics(normalized)
    sufficient, reason = metrics_are_sufficient(normalized, interpreted)
    if not sufficient:
        return f"Sem métricas suficientes para análise fiável: {reason}."

    # The deterministic report is the primary answer because it preserves the
    # exact values and avoids the model rewriting the technical meaning.
    deterministic_report = _format_metrics_deterministic_report(interpreted)

    prompt = build_metrics_llm_prompt(deterministic_report)
    raw_response = run_ollama(prompt, timeout=METRICS_LLM_TIMEOUT)
    if raw_response.startswith("Erro") or raw_response.startswith("Timeout"):
        return deterministic_report

    llm_summary = raw_response.strip()
    if not _is_llm_summary_consistent(llm_summary, deterministic_report):
        return deterministic_report

    if llm_summary == "Resumo indisponível por inconsistência de dados":
        return deterministic_report

    return f"{deterministic_report}\n\nResumo curto:\n{llm_summary}"


def _extract_state_from_legacy_metrics(metrics_obj) -> Optional[dict]:
    cells = metrics_obj.get("cells")
    if not isinstance(cells, list) or not cells:
        return None

    ues_total = 0
    prb_values = []
    sinr_values = []

    for cell in cells:
        ue_list = cell.get("ue_list", [])
        if not isinstance(ue_list, list):
            continue

        ues_total += len(ue_list)
        for ue in ue_list:
            dl_nof_prb = ue.get("dl_nof_nprb")
            dl_total_prb = ue.get("dl_total_nprb")
            if isinstance(dl_nof_prb, (int, float)) and isinstance(dl_total_prb, (int, float)) and dl_total_prb > 0:
                prb_values.append((dl_nof_prb / dl_total_prb) * 100.0)

            snr_db = ue.get("pusch_snr_db")
            if isinstance(snr_db, (int, float)):
                sinr_values.append(float(snr_db))

    if ues_total == 0:
        return None

    prb_usage = sum(prb_values) / len(prb_values) if prb_values else 0.0
    avg_sinr_db = sum(sinr_values) / len(sinr_values) if sinr_values else 0.0

    if avg_sinr_db < 8:
        sinr_label = "low"
    elif avg_sinr_db < 18:
        sinr_label = "medium"
    else:
        sinr_label = "high"

    return {
        "ues": ues_total,
        "prb_usage": round(prb_usage, 2),
        "sinr": sinr_label,
        "avg_sinr_db": round(avg_sinr_db, 2),
    }


def _summarize_current_metrics(metrics_obj: dict) -> dict:
    summary = {
        "source_keys": sorted(metrics_obj.keys()),
        "cells": [],
        "du": [],
        "du_low": {},
        "raw_timestamp": metrics_obj.get("timestamp"),
    }

    cells = metrics_obj.get("cells")
    if isinstance(cells, list):
        for cell in cells:
            cell_info = {}
            if isinstance(cell, dict):
                cell_metrics = cell.get("cell_metrics")
                if isinstance(cell_metrics, dict):
                    cell_info = {
                        "pci": cell_metrics.get("pci"),
                        "average_latency": cell_metrics.get("average_latency"),
                        "max_latency": cell_metrics.get("max_latency"),
                        "pucch_tot_rb_usage_avg": cell_metrics.get("pucch_tot_rb_usage_avg"),
                        "late_dl_harqs": cell_metrics.get("late_dl_harqs"),
                        "late_ul_harqs": cell_metrics.get("late_ul_harqs"),
                        "error_indication_count": cell_metrics.get("error_indication_count"),
                    }
                else:
                    cell_info = {k: cell.get(k) for k in ("pci", "ue_list") if k in cell}
            summary["cells"].append(cell_info)

    du = metrics_obj.get("du")
    if isinstance(du, dict):
        summary["du"] = du

    du_low = metrics_obj.get("du_low")
    if isinstance(du_low, dict):
        summary["du_low"] = {
            "dl_average_latency_us": du_low.get("dl", {}).get("average_latency_us") if isinstance(du_low.get("dl"), dict) else None,
            "dl_average_throughput_mbps": du_low.get("dl", {}).get("average_throughput_mbps") if isinstance(du_low.get("dl"), dict) else None,
            "ul_sinr_db": du_low.get("ul", {}).get("algo_efficiency", {}).get("sinr_db") if isinstance(du_low.get("ul"), dict) and isinstance(du_low.get("ul", {}).get("algo_efficiency"), dict) else None,
            "ul_bler": du_low.get("ul", {}).get("algo_efficiency", {}).get("bler") if isinstance(du_low.get("ul"), dict) and isinstance(du_low.get("ul", {}).get("algo_efficiency"), dict) else None,
            "ul_average_latency_us": du_low.get("ul", {}).get("average_latency_us") if isinstance(du_low.get("ul"), dict) else None,
        }

    return summary


def _format_float(value, precision: int = 2):
    if value is None:
        return "não disponível"
    try:
        return f"{float(value):.{precision}f}"
    except (TypeError, ValueError):
        return "não disponível"


def build_metrics_report(metrics_obj: dict) -> str:
    legacy_state = _extract_state_from_legacy_metrics(metrics_obj)
    if legacy_state is not None:
        congestion, handover = analyze_state(legacy_state)
        quality = "baixa" if legacy_state["sinr"] == "low" else "média" if legacy_state["sinr"] == "medium" else "boa"
        return (
            f"Qualidade do sinal: {quality} (SINR médio {_format_float(legacy_state.get('avg_sinr_db'))} dB).\n"
            f"Latência/uso: PRB {_format_float(legacy_state.get('prb_usage'))}%, congestão {'sim' if congestion else 'não'}.\n"
            f"Anomalias: {'handover provável' if handover else 'sem indicação forte de handover'}.\n"
            f"Conclusão: análise baseada em UEs/SINR antigos do exporter."
        )

    summary = _summarize_current_metrics(metrics_obj)
    du_low = summary.get("du_low", {}) if isinstance(summary.get("du_low"), dict) else {}
    cells = summary.get("cells", []) if isinstance(summary.get("cells"), list) else []

    sinr_db = du_low.get("ul_sinr_db")
    dl_latency = du_low.get("dl_average_latency_us")
    dl_throughput = du_low.get("dl_average_throughput_mbps")
    pci = None
    if cells:
        first_cell = cells[0] if isinstance(cells[0], dict) else {}
        pci = first_cell.get("pci")

    if isinstance(sinr_db, (int, float)):
        if sinr_db < 8:
            signal_quality = "baixa"
        elif sinr_db < 15:
            signal_quality = "média"
        else:
            signal_quality = "boa"
    else:
        signal_quality = "não disponível"

    if isinstance(dl_latency, (int, float)) and dl_latency > 1000:
        latency_comment = f"latência DL elevada ({_format_float(dl_latency)} us)"
    elif isinstance(dl_latency, (int, float)):
        latency_comment = f"latência DL moderada ({_format_float(dl_latency)} us)"
    else:
        latency_comment = "latência DL não disponível"

    if isinstance(dl_throughput, (int, float)):
        throughput_comment = f"throughput DL {_format_float(dl_throughput)} Mbps"
    else:
        throughput_comment = "throughput DL não disponível"

    anomaly_parts = []
    if signal_quality == "baixa":
        anomaly_parts.append("SINR baixo")
    if isinstance(dl_latency, (int, float)) and dl_latency > 1000:
        anomaly_parts.append("latência DL elevada")
    if dl_throughput is None:
        anomaly_parts.append("throughput DL indisponível")
    if not anomaly_parts:
        anomaly_parts.append("sem anomalias fortes visíveis")

    return (
        f"Qualidade do sinal: {signal_quality} (SINR {_format_float(sinr_db)} dB).\n"
        f"Latências e throughput: {latency_comment}; {throughput_comment}.\n"
        f"Anomalias/valores suspeitos: {', '.join(anomaly_parts)}.\n"
        f"PCI: {_format_float(pci, 0)}. Conclusão: leitura direta das métricas atuais, sem inferências do LLM."
    )


def run_ollama(prompt: str, timeout: int) -> str:
    try:
        result = subprocess.run(
            ["ollama", "run", MODEL_NAME],
            input=prompt,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

        if result.returncode != 0:
            error_msg = result.stderr.strip() or "Erro desconhecido do Ollama"
            return f"Erro do LLM (exit {result.returncode}): {error_msg}"

        return result.stdout.strip() or "Sem resposta do LLM"
    except subprocess.TimeoutExpired:
        return "Timeout: LLM demorou demasiado"
    except FileNotFoundError:
        return "Erro: comando 'ollama' não encontrado. Instala o Ollama ou adiciona-o ao PATH."


def ask_llm(prompt: str) -> str:
    base_prompt = f"""
Responde sempre em português de Portugal, de forma clara e técnica quando fizer sentido.
Se o utilizador pedir para explicar um conceito, inclui:
- definição simples
- 2 a 4 pontos principais
- um exemplo prático curto

Pergunta do utilizador:
{prompt}
"""

    first_reply = run_ollama(base_prompt, timeout=DEFAULT_TIMEOUT)
    if first_reply.startswith("Erro") or first_reply.startswith("Timeout"):
        return first_reply

    if prompt.startswith("Analisa rapidamente as métricas atuais da rede 5G abaixo.") or prompt.startswith("Analisa as métricas atuais da rede 5G abaixo."):
        return first_reply or "Sem resposta do LLM"

    if not first_reply or _looks_like_echo(prompt, first_reply):
        retry_prompt = f"""
Responde em português de Portugal e não repitas a pergunta.
Explica de forma objetiva em 6 a 10 linhas.

Pergunta:
{prompt}
"""
        retry_reply = run_ollama(retry_prompt, timeout=RETRY_TIMEOUT)
        return retry_reply or "Sem resposta do LLM"

    return first_reply


def build_network_prompt(state: dict, source: str) -> str:
    congestion, handover = analyze_state(state)

    sinr_detail = ""
    if "avg_sinr_db" in state:
        sinr_detail = f" ({state['avg_sinr_db']} dB médio)"

    return f"""
Estado da rede ({source}):
UEs: {state['ues']}
PRB usage: {state['prb_usage']}%
SINR: {state['sinr']}{sinr_detail}

Decisão lógica base:
- Congestionamento: {congestion}
- Handover necessário: {handover}

Explica tecnicamente esta situação, confirma se a decisão parece correta,
e sugere melhorias práticas em 3-5 pontos curtos.
"""


def build_network_prompt_from_user() -> Optional[str]:
    print("\nInsere os valores para análise da rede:")
    try:
        ues = int(input("UEs: ").strip())
        prb_usage = float(input("PRB usage (%): ").strip())
    except ValueError:
        print("Entrada inválida para UEs/PRB. Usa números.")
        return None
    except (EOFError, KeyboardInterrupt):
        print("\nEntrada interrompida.")
        return None

    sinr = input("SINR (low/medium/high): ").strip().lower()
    if sinr not in {"low", "medium", "high"}:
        print("SINR inválido. Usa: low, medium ou high.")
        return None

    state = {
        "ues": ues,
        "prb_usage": prb_usage,
        "sinr": sinr,
    }
    return build_network_prompt(state, source="input manual")


def print_help():
    print("\nComandos disponíveis:")
    print("/ajuda  -> mostra esta ajuda")
    print("/rede   -> lê métricas atuais do ficheiro e faz análise técnica")
    print("/rede_live [seg] -> análise contínua em tempo real (Ctrl+C para parar)")
    print("/sair   -> termina o programa\n")


def run_live_analysis(interval_seconds: float = 5.0):
    if interval_seconds <= 0:
        interval_seconds = 5.0

    print(f"Modo /rede_live ativo (intervalo: {interval_seconds}s). Ctrl+C para parar.")
    while True:
        metrics_obj = _read_latest_metrics_object()
        if metrics_obj is None:
            print("Sem métricas válidas no ficheiro neste momento.")
            time.sleep(interval_seconds)
            continue

        print("\nMétricas (live):")
        print(analyze_metrics_with_llm(metrics_obj))
        print()
        time.sleep(interval_seconds)

# --- main loop ---
def main():
    print("Modo interativo iniciado.")
    print("Escreve uma pergunta para o LLM.")
    print("Comandos: /ajuda, /rede, /rede_live [seg], /sair (terminar)\n")

    while True:
        try:
            user_input = input("Tu: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nA terminar.")
            break

        if not user_input:
            continue

        if user_input.lower() in {"/sair", "sair", "exit", "quit"}:
            print("A terminar.")
            break

        if user_input.lower() in {"/ajuda", "help", "/help"}:
            print_help()
            continue

        if user_input.lower().startswith("/rede_live"):
            parts = user_input.split()
            interval = 5.0
            if len(parts) >= 2:
                try:
                    interval = float(parts[1])
                except ValueError:
                    print("Intervalo inválido. Usa um número em segundos, ex: /rede_live 3")
                    continue

            try:
                run_live_analysis(interval)
            except KeyboardInterrupt:
                print("\n/rede_live terminado. Voltaste ao modo interativo.")
            continue

        if user_input.lower() == "/rede":
            metrics_obj = _read_latest_metrics_object()
            if metrics_obj is not None:
                print(f"A usar métricas atuais de: {METRICS_FILE}")
                print("\nMétricas:")
                print(analyze_metrics_with_llm(metrics_obj))
                print()
                continue
            else:
                print("Sem métricas válidas no ficheiro neste momento. Mantém o exporter/gNB/UE a correr e tenta novamente.")
                continue
        else:
            prompt = user_input

        print("\nLLM:")
        print(ask_llm(prompt))
        print()

if __name__ == "__main__":
    main()