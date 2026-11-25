#!/usr/bin/env python3
"""Read production capture status without exposing device or call details."""

import json
import sys
from urllib.request import ProxyHandler, build_opener


def read_json(client, path):
    with client.open("http://127.0.0.1:8000" + path, timeout=8) as response:
        data = json.load(response)
    if not isinstance(data, dict):
        raise ValueError(path)
    return data


def present_call(value):
    if value is None:
        return False
    if isinstance(value, dict) and value:
        return True
    raise ValueError("unrecognized bridge call")


def bridge_busy(status):
    clients = status["clients"]
    if not isinstance(clients, list):
        raise ValueError("unrecognized bridge clients")
    capacity = status["capacity"]["active_calls"]
    if type(capacity) is not int or capacity < 0:
        raise ValueError("unrecognized bridge capacity")
    active = sum(present_call(client["active_call"]) or client["device_status"] == "busy" for client in clients)
    return max(active, capacity, int(present_call(status["active_call"])), int(status["device_status"] == "busy"))


def stations_busy(status):
    stations = status["stations"]
    if status["enabled"] is not True or not isinstance(stations, list) or len(stations) < 4:
        raise ValueError("production station inventory incomplete")
    if any(row["kind"] != "production" or not row["station_id"] for row in stations):
        raise ValueError("unrecognized production station")
    if len({row["station_id"] for row in stations}) != len(stations):
        raise ValueError("duplicate production station")

    busy = 0
    for station in stations:
        phase = station["phase"]
        headset = station["headset_phase"]
        if phase not in (None, "active", "finalizing", "ended"):
            raise ValueError("unrecognized station phase")
        if headset not in ("idle", "active", "candidate", "quiet"):
            raise ValueError("unrecognized headset phase")
        logical = station["logical_active"] if station.get("dual_capture_enabled") else False
        if type(logical) is not bool:
            raise ValueError("unrecognized logical call status")
        busy += bool(phase or headset != "idle" or logical or station["call_id"])
    return busy, len(stations)


def main():
    client = build_opener(ProxyHandler({}))
    try:
        if read_json(client, "/api/health")["status"] != "ok":
            raise ValueError("backend health is not ok")
        counts = [bridge_busy(read_json(client, "/api/bridge/status?scheme=" + scheme))
                  for scheme in ("tangxin", "xinchuang")]
        web, stations = stations_busy(read_json(client, "/api/capture/stations?kind=production"))
    except (OSError, ValueError, TypeError, KeyError):
        print("Cannot verify production capture status; cutover is blocked.", file=sys.stderr)
        return 69
    print(f"Capture check: Tangxin={counts[0]}, Xinchuang={counts[1]}, active stations={web}, checked stations={stations}.",
          file=sys.stderr)
    return 75 if any([*counts, web]) else 0


if __name__ == "__main__":
    sys.exit(main())
