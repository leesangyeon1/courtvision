import unittest

from eval_events import match


class MatchTests(unittest.TestCase):
    def test_precision_recall_accuracy_and_location(self):
        gt = [{"t": 2.4, "made": True, "x": 25.0, "y": 19.0},
              {"t": 7.1, "made": False, "x": 25.0, "y": 19.0},
              {"t": 20.0, "made": True, "x": 5.0, "y": 8.0}]          # missed by the app
        ev = [{"t": 2.9, "made": True, "x": 26.0, "y": 19.0},         # TP, 1 ft off
              {"t": 7.0, "made": True, "x": 25.0, "y": 22.0},         # TP, wrong outcome, 3 ft off
              {"t": 12.0, "made": False, "x": None, "y": None}]       # FP
        r = match(gt, ev, tolerance=1.5)
        self.assertEqual((r["tp"], r["fp"], r["fn"]), (2, 1, 1))
        self.assertAlmostEqual(r["precision"], 2 / 3)
        self.assertAlmostEqual(r["recall"], 2 / 3)
        self.assertAlmostEqual(r["outcome_acc"], 0.5)
        self.assertAlmostEqual(r["loc_median_ft"], 2.0)               # median of [1, 3]
        self.assertAlmostEqual(r["loc_p90_ft"], 3.0)

    def test_each_gt_matches_at_most_one_event(self):
        gt = [{"t": 5.0, "made": True, "x": 25.0, "y": 19.0}]
        ev = [{"t": 5.2, "made": True, "x": 25.0, "y": 19.0},
              {"t": 5.9, "made": True, "x": 25.0, "y": 19.0}]
        r = match(gt, ev, tolerance=1.5)
        self.assertEqual((r["tp"], r["fp"], r["fn"]), (1, 1, 0))


if __name__ == "__main__":
    unittest.main()
