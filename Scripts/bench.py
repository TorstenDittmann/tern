#!/usr/bin/env python3
"""Benchmarks Tern through its agent API: cold launch, memory per tab, palette and tab-switch latency.

Run with `make bench`. Each launch starts the built app isolated (one window, no session, no
extensions) against a local test site, then talks JSON-RPC over the agent socket. Results go to
build/bench/results.json; when build/bench/baseline.json exists (`make bench SAVE=1` writes it),
the table shows the change against it.
"""

import argparse
import functools
import http.server
import json
import os
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "Tests", "Smoke", "site")
OUT = os.path.join(ROOT, "build", "bench")


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def serve_site():
    handler = functools.partial(Quiet, directory=SITE)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://localhost:{server.server_address[1]}"


class Tern:
    """One JSON-RPC connection to a running Tern."""

    def __init__(self, path, timeout=30):
        deadline = time.time() + timeout
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(path)
                break
            except OSError:
                self.sock.close()
                if time.time() > deadline:
                    raise RuntimeError(f"Tern didn't open its agent socket at {path}")
                time.sleep(0.02)
        self.buffer = b""
        self.next_id = 0

    def call(self, method, **params):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}
        self.sock.sendall(json.dumps(message).encode() + b"\n")
        while True:
            while b"\n" not in self.buffer:
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise RuntimeError("Tern closed the connection")
                self.buffer += chunk
            line, self.buffer = self.buffer.split(b"\n", 1)
            reply = json.loads(line)
            if reply.get("id") != self.next_id:
                continue  # an event, or a stale reply
            if "error" in reply:
                raise RuntimeError(f"{method}: {reply['error'].get('message')}")
            return reply["result"]

    def close(self):
        self.sock.close()


def launch(app, url, sock_path):
    env = dict(os.environ, TERN_SOCKET=sock_path, TERN_BENCH_URL=url)
    binary = os.path.join(app, "Contents", "MacOS", "Tern")
    return subprocess.Popen([binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def wait_for(fn, timeout=30, interval=0.05):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(interval)
    raise RuntimeError("timed out")


def summary(samples):
    ordered = sorted(samples)
    p95 = ordered[min(len(ordered) - 1, round(0.95 * (len(ordered) - 1)))]
    return {"median": round(statistics.median(ordered), 2), "p95": round(p95, 2), "n": len(ordered)}


def run(args):
    server, base = serve_site()
    sock_path = os.path.join(tempfile.gettempdir(), f"tern-bench-{os.getpid()}.sock")
    results = {"launch": {}, "memory": {}, "latency": {}}
    launches = []

    for i in range(args.launches):
        process = launch(args.app, f"{base}/one.html", sock_path)
        try:
            tern = Tern(sock_path)
            metrics = wait_for(lambda: (m := tern.call("tern.metrics"))["launch"]["firstPageMs"] is not None and m)
            launches.append(metrics["launch"])
            print(f"  launch {i + 1}/{args.launches}: first page after {metrics['launch']['firstPageMs']:.0f} ms", file=sys.stderr)
            if i == args.launches - 1:
                workload(tern, base, args, results)
            tern.close()
        finally:
            process.terminate()
            process.wait(timeout=10)
            if os.path.exists(sock_path):
                os.unlink(sock_path)

    for key in ["didFinishLaunchingMs", "firstWindowMs", "firstPageMs"]:
        results["launch"][key] = summary([l[key] for l in launches if l.get(key) is not None])
    server.shutdown()
    return results


def workload(tern, base, args, results):
    time.sleep(1)  # let the first page settle
    before = tern.call("tern.metrics")["memory"]
    for i in range(args.tabs):
        tern.call("tabs.open", url=f"{base}/form.html?tab={i}")
    time.sleep(2)
    after = tern.call("tern.metrics")["memory"]
    results["memory"] = {
        "oneTab": {"appMB": before["appMB"], "webContentMB": before["webContentMB"], "totalMB": before["totalMB"]},
        f"plus{args.tabs}Tabs": {"appMB": after["appMB"], "webContentMB": after["webContentMB"], "totalMB": after["totalMB"]},
        "perTabMB": round((after["totalMB"] - before["totalMB"]) / args.tabs, 1),
        "webProcesses": len(after["webProcesses"]),
    }

    ids = [t["id"] for t in tern.call("tabs.list")]
    switches = []
    for i in range(args.iterations):
        switches.append(tern.call("tabs.activate", tabId=ids[i % len(ids)])["durationMs"])
    results["latency"]["tabSwitchMs"] = summary(switches)

    opens = []
    for _ in range(args.iterations):
        opens.append(tern.call("commands.run", command="commandPalette")["durationMs"])
        tern.call("commands.run", command="commandPalette")  # toggle closed
    results["latency"]["paletteOpenMs"] = summary(opens)


def rows(results):
    yield "cold launch: first window", results["launch"]["firstWindowMs"]["median"], "ms"
    yield "cold launch: first page loaded", results["launch"]["firstPageMs"]["median"], "ms"
    yield "memory: one tab (Tern + WebContent)", results["memory"]["oneTab"]["totalMB"], "MB"
    yield "memory: per extra tab", results["memory"]["perTabMB"], "MB"
    yield "tab switch (median)", results["latency"]["tabSwitchMs"]["median"], "ms"
    yield "tab switch (p95)", results["latency"]["tabSwitchMs"]["p95"], "ms"
    yield "palette open (median)", results["latency"]["paletteOpenMs"]["median"], "ms"
    yield "palette open (p95)", results["latency"]["paletteOpenMs"]["p95"], "ms"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="path to Tern.app")
    parser.add_argument("--launches", type=int, default=5, help="cold launches to time (default 5)")
    parser.add_argument("--tabs", type=int, default=10, help="tabs to open for the memory figure (default 10)")
    parser.add_argument("--iterations", type=int, default=30, help="samples per latency figure (default 30)")
    parser.add_argument("--save-baseline", action="store_true", help="also save these results as the baseline")
    args = parser.parse_args()

    results = run(args)
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "results.json"), "w") as f:
        json.dump(results, f, indent=2)

    baseline_path = os.path.join(OUT, "baseline.json")
    baseline = None
    if os.path.exists(baseline_path) and not args.save_baseline:
        with open(baseline_path) as f:
            baseline = json.load(f)

    print()
    print(f"{'':38} {'now':>10}" + (f" {'baseline':>10} {'change':>8}" if baseline else ""))
    print("-" * (49 + (20 if baseline else 0)))
    old_rows = {name: value for name, value, _ in rows(baseline)} if baseline else {}
    for name, value, unit in rows(results):
        line = f"{name:38} {value:>7} {unit:<2}"
        if baseline and name in old_rows:
            old = old_rows[name]
            change = f"{(value - old) / old * 100:+.0f}%" if old else "n/a"
            line += f" {old:>7} {unit:<2} {change:>8}"
        print(line)
    print(f"\nresults: {os.path.relpath(os.path.join(OUT, 'results.json'), ROOT)}")

    if args.save_baseline:
        with open(baseline_path, "w") as f:
            json.dump(results, f, indent=2)
        print(f"saved as the baseline: {os.path.relpath(baseline_path, ROOT)}")


if __name__ == "__main__":
    main()
