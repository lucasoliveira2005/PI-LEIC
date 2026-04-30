#!/usr/bin/env python3
"""Upsert Open5GS subscribers from config/subscribers.json.

This helper keeps subscriber provisioning versioned alongside the lab topology.
It uses `mongosh` so it works with the standard Open5GS MongoDB setup without
adding extra Python dependencies.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import os
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
DEFAULT_CONFIG = REPO_ROOT / "config" / "subscribers.json"
DEFAULT_DATABASE = "open5gs"
DEFAULT_MONGOSH = "mongosh"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Provision Open5GS subscribers from config/subscribers.json."
    )
    parser.add_argument(
        "--config",
        default=str(DEFAULT_CONFIG),
        help="Path to the subscribers.json file.",
    )
    parser.add_argument(
        "--database",
        default=DEFAULT_DATABASE,
        help="MongoDB database name used by Open5GS.",
    )
    parser.add_argument(
        "--mongosh",
        default=DEFAULT_MONGOSH,
        help="Path to the mongosh executable.",
    )
    parser.add_argument(
        "--uri",
        help="Optional MongoDB connection URI. Defaults to mongosh local settings.",
    )
    parser.add_argument(
        "--only",
        action="append",
        default=[],
        metavar="SUBSCRIBER",
        help="Limit provisioning to a subscriber_id or IMSI. Repeatable.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply changes to MongoDB. Without this flag, the script runs in dry-run mode.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print the full subscriber document returned by the provisioning plan.",
    )
    return parser.parse_args()


def clean_hex(value: Any, field_name: str, expected_length: int | None = None) -> str | None:
    if value in (None, ""):
        return None
    cleaned = re.sub(r"[^0-9a-fA-F]", "", str(value)).upper()
    if not cleaned:
        return None
    if expected_length is not None and len(cleaned) != expected_length:
        raise ValueError(
            f"Subscriber field '{field_name}' must contain {expected_length} hex digits "
            f"after normalization; got {len(cleaned)}."
        )
    return cleaned


def validate_ambr(value: Any, field_name: str) -> dict[str, dict[str, int]] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError(f"Subscriber field '{field_name}' must be an object.")
    try:
        downlink = value["downlink"]
        uplink = value["uplink"]
        normalized = {
            "downlink": {"value": int(downlink["value"]), "unit": int(downlink["unit"])},
            "uplink": {"value": int(uplink["value"]), "unit": int(uplink["unit"])},
        }
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(
            f"Subscriber field '{field_name}' must follow the Open5GS AMBR shape."
        ) from exc
    return normalized


def normalize_subscriber(raw: dict[str, Any]) -> dict[str, Any]:
    required_fields = ("subscriber_id", "imsi", "k", "opc")
    missing = [field for field in required_fields if not raw.get(field)]
    if missing:
        raise ValueError(f"Subscriber entry is missing required fields: {', '.join(missing)}")

    imsi = str(raw["imsi"]).strip()
    if not imsi.isdigit():
        raise ValueError(f"Subscriber IMSI must be numeric: {imsi}")

    if not raw.get("apn"):
        raise ValueError(f"Subscriber '{raw['subscriber_id']}' is missing 'apn'.")
    if raw.get("sst") is None:
        raise ValueError(f"Subscriber '{raw['subscriber_id']}' is missing 'sst'.")

    normalized = {
        "subscriber_id": str(raw["subscriber_id"]).strip(),
        "source_id": str(raw.get("source_id", "")).strip() or None,
        "imsi": imsi,
        "imei": str(raw["imei"]).strip() if raw.get("imei") else None,
        "imeisv": str(raw["imeisv"]).strip() if raw.get("imeisv") else None,
        "netns": str(raw["netns"]).strip() if raw.get("netns") else None,
        "ue_config": str(raw["ue_config"]).strip() if raw.get("ue_config") else None,
        "apn": str(raw["apn"]).strip(),
        "sst": int(raw["sst"]),
        "sd": clean_hex(raw.get("sd"), "sd", expected_length=6),
        "amf": clean_hex(raw.get("amf") or "8000", "amf", expected_length=4),
        "k": clean_hex(raw["k"], "k", expected_length=32),
        "op": clean_hex(raw.get("op"), "op", expected_length=32),
        "opc": clean_hex(raw["opc"], "opc", expected_length=32),
        "session_type": int(raw.get("session_type", 3)),
        "qos_index": int(raw.get("qos_index", 9)),
        "arp_priority_level": int(raw.get("arp_priority_level", 8)),
        "pre_emption_capability": int(raw.get("pre_emption_capability", 1)),
        "pre_emption_vulnerability": int(raw.get("pre_emption_vulnerability", 1)),
        "ambr": validate_ambr(raw.get("ambr"), "ambr"),
        "session_ambr": validate_ambr(raw.get("session_ambr"), "session_ambr"),
        "sqn": int(raw.get("sqn", 0)),
        "msisdn": [str(value).strip() for value in raw.get("msisdn", []) if str(value).strip()],
    }
    return normalized


def load_subscribers(config_path: Path, only_filters: list[str]) -> list[dict[str, Any]]:
    try:
        raw_data = json.loads(config_path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SystemExit(f"Subscribers config not found: {config_path}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Subscribers config is not valid JSON: {exc}") from exc

    if not isinstance(raw_data, list):
        raise SystemExit("Subscribers config must contain a JSON array.")

    subscribers = [normalize_subscriber(item) for item in raw_data]

    if only_filters:
        selected = set(only_filters)
        subscribers = [
            item
            for item in subscribers
            if item["subscriber_id"] in selected or item["imsi"] in selected
        ]
        if not subscribers:
            raise SystemExit(
                "No subscribers matched --only filters: " + ", ".join(sorted(selected))
            )

    return subscribers


def build_mongosh_script(
    subscribers: list[dict[str, Any]],
    *,
    database: str,
    dry_run: bool,
    verbose: bool,
) -> str:
    subscribers_json = json.dumps(subscribers, indent=2)
    database_json = json.dumps(database)
    dry_run_json = "true" if dry_run else "false"
    verbose_json = "true" if verbose else "false"
    return textwrap.dedent(
        f"""
        const subscribers = {subscribers_json};
        const databaseName = {database_json};
        const dryRun = {dry_run_json};
        const verbose = {verbose_json};
        const collection = db.getSiblingDB(databaseName).subscribers;

        function spacedHex(value) {{
          if (!value) {{
            return null;
          }}
          return value.match(/.{{1,8}}/g).join(' ');
        }}

        function clone(value) {{
          return JSON.parse(JSON.stringify(value));
        }}

        function defaultAmbr() {{
          return {{
            downlink: {{ value: 1, unit: 3 }},
            uplink: {{ value: 1, unit: 3 }}
          }};
        }}

        function normalizeAmbr(value) {{
          return value ? clone(value) : defaultAmbr();
        }}

        function buildSlice(subscriber) {{
          const slice = {{
            sst: subscriber.sst,
            default_indicator: true,
            session: [{{
              name: subscriber.apn,
              type: subscriber.session_type,
              qos: {{
                index: subscriber.qos_index,
                arp: {{
                  priority_level: subscriber.arp_priority_level,
                  pre_emption_capability: subscriber.pre_emption_capability,
                  pre_emption_vulnerability: subscriber.pre_emption_vulnerability
                }}
              }},
              ambr: normalizeAmbr(subscriber.session_ambr || subscriber.ambr),
              pcc_rule: []
            }}]
          }};

          if (subscriber.sd) {{
            slice.sd = subscriber.sd;
          }}

          return slice;
        }}

        function buildDocument(subscriber, existing) {{
          const document = {{
            schema_version: existing?.schema_version ?? 1,
            imsi: subscriber.imsi,
            msisdn: subscriber.msisdn.length ? clone(subscriber.msisdn) : (existing?.msisdn || []),
            mme_host: existing?.mme_host || [],
            mme_realm: existing?.mme_realm || [],
            purge_flag: existing?.purge_flag || [],
            access_restriction_data: existing?.access_restriction_data ?? 32,
            subscriber_status: existing?.subscriber_status ?? 0,
            operator_determined_barring: existing?.operator_determined_barring ?? 0,
            network_access_mode: existing?.network_access_mode ?? 0,
            subscribed_rau_tau_timer: existing?.subscribed_rau_tau_timer ?? 12,
            ambr: normalizeAmbr(subscriber.ambr),
            security: {{
              k: spacedHex(subscriber.k),
              amf: subscriber.amf,
              op: subscriber.op ? spacedHex(subscriber.op) : null,
              opc: spacedHex(subscriber.opc),
              sqn: existing?.security?.sqn ?? NumberLong(String(subscriber.sqn))
            }},
            slice: [buildSlice(subscriber)]
          }};

          const imeisv = subscriber.imeisv || subscriber.imei || existing?.imeisv;
          if (imeisv) {{
            document.imeisv = imeisv;
          }}

          if (existing?._id) {{
            document._id = existing._id;
          }}

          if (existing?.__v !== undefined) {{
            document.__v = existing.__v;
          }} else {{
            document.__v = 0;
          }}

          return document;
        }}

        function summarize(subscriber, action, document, result) {{
          const sliceSummary = document.slice.map((slice) => ({{
            sst: slice.sst,
            sd: slice.sd || null,
            sessions: slice.session.map((session) => session.name)
          }}));

          const summary = {{
            subscriber_id: subscriber.subscriber_id,
            source_id: subscriber.source_id,
            imsi: subscriber.imsi,
            action: action,
            dry_run: dryRun,
            slices: sliceSummary
          }};

          if (result) {{
            summary.matched_count = result.matchedCount;
            summary.modified_count = result.modifiedCount;
            summary.upserted_count = result.upsertedCount;
          }}

          if (verbose) {{
            summary.document = document;
          }}

          return summary;
        }}

        for (const subscriber of subscribers) {{
          const existing = collection.findOne({{ imsi: subscriber.imsi }});
          const document = buildDocument(subscriber, existing);
          const action = existing ? 'update' : 'insert';

          if (dryRun) {{
            print(JSON.stringify(summarize(subscriber, action, document, null)));
            continue;
          }}

          const result = collection.replaceOne(
            {{ imsi: subscriber.imsi }},
            document,
            {{ upsert: true }}
          );
          print(JSON.stringify(summarize(subscriber, action, document, result)));
        }}
        """
    ).strip()


def run_mongosh(script: str, mongosh_bin: str, uri: str | None) -> subprocess.CompletedProcess[str]:
    if not shutil.which(mongosh_bin):
        raise SystemExit(f"Could not find mongosh executable: {mongosh_bin}")

    with tempfile.TemporaryDirectory(prefix="pi-leic-mongosh-") as temp_home:
        temp_home_path = Path(temp_home)
        xdg_config_home = temp_home_path / "xdg"
        xdg_config_home.mkdir(parents=True, exist_ok=True)

        with tempfile.NamedTemporaryFile("w", suffix=".js", encoding="utf-8", delete=False) as handle:
            handle.write(script)
            script_path = handle.name

        cmd = [mongosh_bin]
        if uri:
            cmd.append(uri)
        cmd.extend(["--quiet", "--file", script_path])

        env = os.environ.copy()
        env["HOME"] = temp_home
        env["XDG_CONFIG_HOME"] = str(xdg_config_home)

        try:
            return subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
        finally:
            Path(script_path).unlink(missing_ok=True)


def parse_mongosh_output(stdout: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            records.append({"raw_output": line})
    return records


def print_summary(records: list[dict[str, Any]], dry_run: bool) -> None:
    if not records:
        print("No output received from mongosh.", file=sys.stderr)
        return

    applied = 0
    for record in records:
        if "raw_output" in record:
            print(record["raw_output"])
            continue

        action = record["action"]
        subscriber_id = record.get("subscriber_id") or "unknown"
        source_id = record.get("source_id") or "n/a"
        imsi = record["imsi"]
        slices = []
        for slice_info in record.get("slices", []):
            sessions = ",".join(slice_info.get("sessions", [])) or "-"
            sd = slice_info.get("sd") or "-"
            slices.append(f"sst={slice_info['sst']} sd={sd} dnn={sessions}")
        slice_text = " | ".join(slices) if slices else "no slices"

        status = "Would upsert" if dry_run else "Upserted"
        print(
            f"{status} {subscriber_id} ({imsi}) via {source_id}: {action}, {slice_text}"
        )

        if not dry_run:
            applied += 1

        document = record.get("document")
        if document is not None:
            print(json.dumps(document, indent=2, sort_keys=True))

    if dry_run:
        print("Dry run complete. Re-run with --apply to write these subscribers to MongoDB.")
    else:
        print(f"Provisioning complete. Updated {applied} subscriber(s).")


def main() -> int:
    args = parse_args()
    config_path = Path(args.config).resolve()
    subscribers = load_subscribers(config_path, args.only)

    script = build_mongosh_script(
        subscribers,
        database=args.database,
        dry_run=not args.apply,
        verbose=args.verbose,
    )
    result = run_mongosh(script, args.mongosh, args.uri)

    if result.returncode != 0:
        if result.stdout.strip():
            print(result.stdout.strip(), file=sys.stderr)
        if result.stderr.strip():
            print(result.stderr.strip(), file=sys.stderr)
        print(
            "Provisioning failed. Check that MongoDB and Open5GS are running and that mongosh "
            "can access the local database.",
            file=sys.stderr,
        )
        return result.returncode

    records = parse_mongosh_output(result.stdout)
    print_summary(records, dry_run=not args.apply)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
