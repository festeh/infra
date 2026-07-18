#!/usr/bin/env python3
"""Fail when an unexpected process listens beyond the loopback interface."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


PROCESS_PATTERN = re.compile(r'\("([^"]+)"')


def parse_endpoint(endpoint: str) -> tuple[str, int]:
    if endpoint.startswith("["):
        closing_bracket = endpoint.rfind("]:")
        if closing_bracket == -1:
            raise ValueError(f"unsupported socket endpoint: {endpoint}")
        address = endpoint[1:closing_bracket]
        port_text = endpoint[closing_bracket + 2 :]
    else:
        address, separator, port_text = endpoint.rpartition(":")
        if not separator:
            raise ValueError(f"unsupported socket endpoint: {endpoint}")

    address = address.split("%", maxsplit=1)[0]
    try:
        port = int(port_text)
    except ValueError as error:
        raise ValueError(f"non-numeric socket port in: {endpoint}") from error
    return address, port


def is_loopback(address: str) -> bool:
    if address in {"*", "0.0.0.0", "::"}:
        return False
    try:
        return ipaddress.ip_address(address).is_loopback
    except ValueError:
        return False


def collect_listeners(protocol: str) -> tuple[list[dict[str, Any]], int]:
    flags = "-lntp" if protocol == "tcp" else "-lnup"
    result = subprocess.run(
        ["ss", "-H", flags],
        check=True,
        capture_output=True,
        text=True,
    )

    exposed: list[dict[str, Any]] = []
    loopback_count = 0
    for line in result.stdout.splitlines():
        fields = line.split(maxsplit=5)
        if len(fields) < 5:
            raise ValueError(f"could not parse ss output: {line}")
        address, port = parse_endpoint(fields[3])
        processes = sorted(set(PROCESS_PATTERN.findall(fields[5] if len(fields) > 5 else "")))
        listener = {
            "protocol": protocol,
            "address": address,
            "port": port,
            "processes": processes,
        }
        if is_loopback(address):
            loopback_count += 1
        else:
            exposed.append(listener)
    return exposed, loopback_count


def validate_rules(rules: Any) -> list[dict[str, Any]]:
    if not isinstance(rules, list):
        raise ValueError("listener allowlist must be a JSON array")
    for rule in rules:
        if not isinstance(rule, dict):
            raise ValueError("each listener rule must be an object")
        if rule.get("protocol") not in {"tcp", "udp"}:
            raise ValueError(f"invalid listener protocol: {rule.get('protocol')}")
        if not isinstance(rule.get("port"), int):
            raise ValueError(f"listener rule port must be an integer: {rule}")
        if "process" in rule and not isinstance(rule["process"], str):
            raise ValueError(f"listener rule process must be a string: {rule}")
    return rules


def load_rules(path: Path) -> list[dict[str, Any]]:
    return validate_rules(json.loads(path.read_text(encoding="utf-8")))


def is_allowed(listener: dict[str, Any], rules: list[dict[str, Any]]) -> bool:
    for rule in rules:
        if rule["protocol"] != listener["protocol"] or rule["port"] != listener["port"]:
            continue
        if "address" in rule and rule["address"] != listener["address"]:
            continue
        if "process" in rule and rule["process"] not in listener["processes"]:
            continue
        return True
    return False


def format_listener(listener: dict[str, Any]) -> str:
    processes = ",".join(listener["processes"]) if listener["processes"] else "unknown"
    address = listener["address"]
    if ":" in address:
        address = f"[{address}]"
    return f"{listener['protocol']} {address}:{listener['port']} processes={processes}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("/etc/infra/allowed-public-listeners.json"),
    )
    args = parser.parse_args()

    try:
        rules_json = os.environ.get("INFRA_ALLOWED_PUBLIC_LISTENERS_JSON")
        rules = validate_rules(json.loads(rules_json)) if rules_json else load_rules(args.config)
        tcp_listeners, tcp_loopback = collect_listeners("tcp")
        udp_listeners, udp_loopback = collect_listeners("udp")
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"listener audit could not run: {error}", file=sys.stderr)
        return 2

    exposed = tcp_listeners + udp_listeners
    unexpected = [listener for listener in exposed if not is_allowed(listener, rules)]
    if unexpected:
        print("Unexpected non-loopback listeners:", file=sys.stderr)
        for listener in unexpected:
            print(f"  - {format_listener(listener)}", file=sys.stderr)
        return 1

    print(
        "Listener audit passed: "
        f"{len(exposed)} reviewed non-loopback sockets; "
        f"{tcp_loopback + udp_loopback} loopback sockets ignored."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
