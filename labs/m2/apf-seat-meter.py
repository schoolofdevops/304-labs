#!/usr/bin/env python3
"""Live terminal visualizer for Kubernetes API Priority and Fairness seats."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime


METRIC_RE = re.compile(
    r"^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)"
    r"(?:\{(?P<labels>[^}]*)\})?\s+"
    r"(?P<value>[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)$"
)
LABEL_RE = re.compile(r'(\w+)="((?:\\.|[^"])*)"')
SPARKS = "▁▂▃▄▅▆▇█"


@dataclass(frozen=True)
class Sample:
    executing_requests: int
    executing_seats: int
    queued_requests: int
    queued_seats: int
    current_limit: int
    nominal_limit: int
    dispatched_total: int
    rejected_total: int
    estimated_seats_le_four: int
    estimated_seats_sum: float
    estimated_seats_count: int


@dataclass(frozen=True)
class Baseline:
    dispatched_total: int
    rejected_total: int
    estimated_seats_le_four: int
    estimated_seats_sum: float
    estimated_seats_count: int


@dataclass(frozen=True)
class Peaks:
    executing_seats: int = 0
    seat_width: float = 0.0


class Paint:
    def __init__(self, enabled: bool):
        self.enabled = enabled

    def apply(self, code: str, text: str) -> str:
        if not self.enabled:
            return text
        return f"\033[{code}m{text}\033[0m"

    def title(self, text: str) -> str:
        return self.apply("1;36", text)

    def normal_seats(self, text: str) -> str:
        return self.apply("1;32", text)

    def borrowed_seats(self, text: str) -> str:
        return self.apply("1;33", text)

    def queue(self, text: str) -> str:
        return self.apply("1;31", text)

    def dim(self, text: str) -> str:
        return self.apply("2", text)


def _parse_labels(raw: str | None) -> dict[str, str]:
    return {key: value for key, value in LABEL_RE.findall(raw or "")}


def _matching_values(
    metrics_text: str,
    metric_name: str,
    required_labels: dict[str, str],
) -> list[float]:
    values: list[float] = []
    for line in metrics_text.splitlines():
        match = METRIC_RE.match(line.strip())
        if not match or match.group("name") != metric_name:
            continue
        labels = _parse_labels(match.group("labels"))
        if all(labels.get(key) == value for key, value in required_labels.items()):
            values.append(float(match.group("value")))
    return values


def _one_value(
    metrics_text: str,
    metric_name: str,
    required_labels: dict[str, str],
    friendly_name: str,
) -> int:
    values = _matching_values(metrics_text, metric_name, required_labels)
    if not values:
        raise ValueError(f"metrics response did not contain {friendly_name}")
    return round(values[0])


def _one_float(
    metrics_text: str,
    metric_name: str,
    required_labels: dict[str, str],
    friendly_name: str,
) -> float:
    values = _matching_values(metrics_text, metric_name, required_labels)
    if not values:
        raise ValueError(f"metrics response did not contain {friendly_name}")
    return values[0]


def parse_metrics(
    metrics_text: str,
    flow_schema: str,
    priority_level: str,
) -> Sample:
    """Extract one FlowSchema/PriorityLevel APF snapshot from Prometheus text."""
    flow_labels = {
        "flow_schema": flow_schema,
        "priority_level": priority_level,
    }
    level_labels = {"priority_level": priority_level}

    rejected = _matching_values(
        metrics_text,
        "apiserver_flowcontrol_rejected_requests_total",
        flow_labels,
    )

    return Sample(
        executing_requests=_one_value(
            metrics_text,
            "apiserver_flowcontrol_current_executing_requests",
            flow_labels,
            "executing requests",
        ),
        executing_seats=_one_value(
            metrics_text,
            "apiserver_flowcontrol_current_executing_seats",
            flow_labels,
            "executing seats",
        ),
        queued_requests=_one_value(
            metrics_text,
            "apiserver_flowcontrol_current_inqueue_requests",
            flow_labels,
            "queued requests",
        ),
        queued_seats=_one_value(
            metrics_text,
            "apiserver_flowcontrol_current_inqueue_seats",
            flow_labels,
            "queued seats",
        ),
        current_limit=_one_value(
            metrics_text,
            "apiserver_flowcontrol_current_limit_seats",
            level_labels,
            "current seat limit",
        ),
        nominal_limit=_one_value(
            metrics_text,
            "apiserver_flowcontrol_nominal_limit_seats",
            level_labels,
            "nominal seat limit",
        ),
        dispatched_total=_one_value(
            metrics_text,
            "apiserver_flowcontrol_dispatched_requests_total",
            flow_labels,
            "dispatched request counter",
        ),
        rejected_total=round(sum(rejected)),
        estimated_seats_le_four=_one_value(
            metrics_text,
            "apiserver_flowcontrol_work_estimated_seats_bucket",
            {**flow_labels, "le": "4"},
            "estimated seat bucket le=4",
        ),
        estimated_seats_sum=_one_float(
            metrics_text,
            "apiserver_flowcontrol_work_estimated_seats_sum",
            flow_labels,
            "estimated seat sum",
        ),
        estimated_seats_count=_one_value(
            metrics_text,
            "apiserver_flowcontrol_work_estimated_seats_count",
            flow_labels,
            "estimated seat count",
        ),
    )


def seat_width(sample: Sample) -> float:
    if sample.executing_requests <= 0:
        return 0.0
    return sample.executing_seats / sample.executing_requests


def counter_delta(current: float, baseline: float) -> float:
    """Return a useful delta even if the API server counter restarted."""
    return current - baseline if current >= baseline else current


def _plural(value: int, singular: str) -> str:
    suffix = "" if value == 1 else "s"
    return f"{value} {singular}{suffix}"


def _sparkline(history: list[int]) -> str:
    if not history:
        return ""
    high = max(history)
    if high <= 0:
        return SPARKS[0] * len(history)
    return "".join(SPARKS[round((value / high) * (len(SPARKS) - 1))] for value in history)


def _capacity_bar(sample: Sample, width: int, paint: Paint) -> tuple[str, str]:
    capacity = max(sample.current_limit, sample.nominal_limit, sample.executing_seats, 1)
    bar_width = max(20, min(60, width - 2))
    used_cells = min(bar_width, round(sample.executing_seats / capacity * bar_width))
    nominal_cell = min(bar_width - 1, round(sample.nominal_limit / capacity * bar_width))

    normal_cells = min(used_cells, nominal_cell)
    borrowed_cells = max(0, used_cells - normal_cells)
    empty_cells = max(0, bar_width - used_cells)
    bar = (
        paint.normal_seats("█" * normal_cells)
        + paint.borrowed_seats("█" * borrowed_cells)
        + paint.dim("░" * empty_cells)
    )

    marker = [" "] * bar_width
    marker[nominal_cell] = "▲"
    limit_cell = min(bar_width - 1, round(sample.current_limit / capacity * bar_width))
    marker[limit_cell] = "▼" if marker[limit_cell] == " " else "◆"
    return f"[{bar}]", " " + "".join(marker)


def render_snapshot(
    sample: Sample,
    baseline: Baseline,
    peaks: Peaks,
    history: list[int],
    flow_schema: str,
    width: int,
    color: bool,
    timestamp: str,
) -> str:
    paint = Paint(color)
    bar, markers = _capacity_bar(sample, width, paint)
    width_now = seat_width(sample)
    dispatched = counter_delta(sample.dispatched_total, baseline.dispatched_total)
    rejected = counter_delta(sample.rejected_total, baseline.rejected_total)
    estimated_count = counter_delta(
        sample.estimated_seats_count, baseline.estimated_seats_count
    )
    estimated_sum = counter_delta(sample.estimated_seats_sum, baseline.estimated_seats_sum)
    narrow_count = counter_delta(
        sample.estimated_seats_le_four, baseline.estimated_seats_le_four
    )
    wide_count = max(0, estimated_count - narrow_count)
    average_estimated = estimated_sum / estimated_count if estimated_count else 0.0

    queue_text = f"{_plural(sample.queued_requests, 'request')} / {_plural(sample.queued_seats, 'seat')}"
    queue_line = paint.queue(queue_text) if sample.queued_requests else paint.dim(queue_text)

    lines = [
        paint.title(f"APF SEAT METER · {flow_schema} · {timestamp}"),
        "",
        "EXECUTING",
        f"{sample.executing_seats} seats / {sample.executing_requests} active requests = "
        f"{width_now:.1f} seats/active request",
        f"nominal {sample.nominal_limit} · current limit {sample.current_limit}",
        markers,
        bar,
        "",
        "QUEUE",
        queue_line,
        "",
        "THIS OBSERVATION WINDOW",
        f"Dispatched: +{dispatched:.0f}    Rejected: +{rejected:.0f}",
        f"Wide requests (>4 seats): +{wide_count:.0f}",
        f"Average estimated cost: {average_estimated:.1f} seats/request",
        f"Peak seats: {peaks.executing_seats}    "
        f"Peak active average: {peaks.seat_width:.1f} seats/request",
        "",
        "SEAT HISTORY",
        _sparkline(history),
        "",
        paint.dim("Green = within nominal share · yellow = borrowed seats · red = queued"),
        paint.dim("Ctrl-C to stop and print the final summary"),
    ]
    return "\n".join(lines)


def _fetch_metrics(kubectl: str, context: str) -> str:
    command = [kubectl, "--context", context, "get", "--raw", "/metrics"]
    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    if completed.returncode != 0:
        message = completed.stderr.strip() or "kubectl returned a non-zero exit code"
        raise RuntimeError(message)
    return completed.stdout


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Visualize Kubernetes API Priority and Fairness seats in real time."
    )
    parser.add_argument("--context", default="kind-kubeadv-core")
    parser.add_argument("--flow-schema", default="global-default")
    parser.add_argument("--priority-level", default="global-default")
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--history", type=int, default=30)
    parser.add_argument("--once", action="store_true", help="print one snapshot and exit")
    parser.add_argument("--no-color", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = _arguments()
    kubectl = shutil.which("kubectl")
    if not kubectl:
        print("error: kubectl was not found on PATH", file=sys.stderr)
        return 2
    if args.interval <= 0:
        print("error: --interval must be greater than zero", file=sys.stderr)
        return 2

    baseline: Baseline | None = None
    peaks = Peaks()
    history: list[int] = []
    last_output = ""
    interactive = sys.stdout.isatty() and not args.once
    color = interactive and not args.no_color and os.environ.get("NO_COLOR") is None

    try:
        while True:
            metrics = _fetch_metrics(kubectl, args.context)
            sample = parse_metrics(metrics, args.flow_schema, args.priority_level)
            if baseline is None:
                baseline = Baseline(
                    dispatched_total=sample.dispatched_total,
                    rejected_total=sample.rejected_total,
                    estimated_seats_le_four=sample.estimated_seats_le_four,
                    estimated_seats_sum=sample.estimated_seats_sum,
                    estimated_seats_count=sample.estimated_seats_count,
                )

            width_now = seat_width(sample)
            peaks = Peaks(
                executing_seats=max(peaks.executing_seats, sample.executing_seats),
                seat_width=max(peaks.seat_width, width_now),
            )
            history.append(sample.executing_seats)
            history = history[-max(1, args.history) :]

            terminal_width = shutil.get_terminal_size((80, 24)).columns
            last_output = render_snapshot(
                sample,
                baseline=baseline,
                peaks=peaks,
                history=history,
                flow_schema=args.flow_schema,
                width=terminal_width,
                color=color,
                timestamp=datetime.now().strftime("%H:%M:%S"),
            )
            if interactive:
                print("\033[2J\033[H", end="")
            elif history and len(history) > 1:
                print("---")
            print(last_output, flush=True)

            if args.once:
                return 0
            time.sleep(args.interval)
    except KeyboardInterrupt:
        if interactive and last_output:
            print("\n")
            print(last_output)
        return 0
    except (RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
