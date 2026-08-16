import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "apf-seat-meter.py"
SPEC = importlib.util.spec_from_file_location("apf_seat_meter", SCRIPT)
apf_seat_meter = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = apf_seat_meter
SPEC.loader.exec_module(apf_seat_meter)


METRICS = """
apiserver_flowcontrol_current_executing_requests{flow_schema="global-default",priority_level="global-default"} 25
apiserver_flowcontrol_current_executing_seats{flow_schema="global-default",priority_level="global-default"} 169
apiserver_flowcontrol_current_inqueue_requests{flow_schema="global-default",priority_level="global-default"} 1
apiserver_flowcontrol_current_inqueue_seats{flow_schema="global-default",priority_level="global-default"} 7
apiserver_flowcontrol_current_limit_seats{priority_level="global-default"} 180
apiserver_flowcontrol_nominal_limit_seats{priority_level="global-default"} 44
apiserver_flowcontrol_dispatched_requests_total{flow_schema="global-default",priority_level="global-default"} 5367
apiserver_flowcontrol_rejected_requests_total{flow_schema="global-default",priority_level="global-default",reason="queue-full"} 2
apiserver_flowcontrol_rejected_requests_total{flow_schema="global-default",priority_level="global-default",reason="time-out"} 1
apiserver_flowcontrol_work_estimated_seats_bucket{flow_schema="global-default",priority_level="global-default",le="4"} 4100
apiserver_flowcontrol_work_estimated_seats_sum{flow_schema="global-default",priority_level="global-default"} 12980
apiserver_flowcontrol_work_estimated_seats_count{flow_schema="global-default",priority_level="global-default"} 5000
"""


class ParseMetricsTests(unittest.TestCase):
    def test_extracts_flow_and_priority_level_metrics(self):
        sample = apf_seat_meter.parse_metrics(
            METRICS,
            flow_schema="global-default",
            priority_level="global-default",
        )

        self.assertEqual(sample.executing_requests, 25)
        self.assertEqual(sample.executing_seats, 169)
        self.assertEqual(sample.queued_requests, 1)
        self.assertEqual(sample.queued_seats, 7)
        self.assertEqual(sample.current_limit, 180)
        self.assertEqual(sample.nominal_limit, 44)
        self.assertEqual(sample.dispatched_total, 5367)
        self.assertEqual(sample.rejected_total, 3)
        self.assertEqual(sample.estimated_seats_le_four, 4100)
        self.assertEqual(sample.estimated_seats_sum, 12980)
        self.assertEqual(sample.estimated_seats_count, 5000)

    def test_reports_missing_required_metrics(self):
        with self.assertRaisesRegex(ValueError, "executing seats"):
            apf_seat_meter.parse_metrics(
                'apiserver_flowcontrol_current_executing_requests{flow_schema="global-default",priority_level="global-default"} 0',
                flow_schema="global-default",
                priority_level="global-default",
            )


class CalculationTests(unittest.TestCase):
    def test_calculates_seat_width_from_active_requests(self):
        sample = apf_seat_meter.parse_metrics(
            METRICS,
            flow_schema="global-default",
            priority_level="global-default",
        )

        self.assertAlmostEqual(apf_seat_meter.seat_width(sample), 6.76)

    def test_counter_delta_does_not_go_negative_after_server_restart(self):
        self.assertEqual(apf_seat_meter.counter_delta(12, 10), 2)
        self.assertEqual(apf_seat_meter.counter_delta(2, 10), 2)


class RenderingTests(unittest.TestCase):
    def test_renders_capacity_queue_deltas_and_history(self):
        sample = apf_seat_meter.parse_metrics(
            METRICS,
            flow_schema="global-default",
            priority_level="global-default",
        )
        baseline = apf_seat_meter.Baseline(
            dispatched_total=4632,
            rejected_total=1,
            estimated_seats_le_four=4000,
            estimated_seats_sum=12300,
            estimated_seats_count=4800,
        )
        peaks = apf_seat_meter.Peaks(executing_seats=169, seat_width=6.76)

        output = apf_seat_meter.render_snapshot(
            sample,
            baseline=baseline,
            peaks=peaks,
            history=[1, 8, 43, 169],
            flow_schema="global-default",
            width=52,
            color=False,
            timestamp="17:00:09",
        )

        self.assertIn(
            "169 seats / 25 active requests = 6.8 seats/active request", output
        )
        self.assertIn("nominal 44", output)
        self.assertIn("current limit 180", output)
        self.assertIn("1 request / 7 seats", output)
        self.assertIn("Dispatched: +735", output)
        self.assertIn("Rejected: +2", output)
        self.assertIn("Wide requests (>4 seats): +100", output)
        self.assertIn("Average estimated cost: 3.4 seats/request", output)
        self.assertIn("Peak seats: 169", output)
        self.assertIn("Peak active average: 6.8 seats/request", output)
        self.assertIn("SEAT HISTORY", output)
        self.assertRegex(output, r"[▁▂▃▄▅▆▇█]")


if __name__ == "__main__":
    unittest.main()
