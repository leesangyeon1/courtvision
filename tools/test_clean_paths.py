import unittest

import numpy as np

from clean_paths import clean_path


class CleanPathTests(unittest.TestCase):
    def test_teleport_removed_and_smoothed(self):
        # Straight walk at 1 ft/tick with one 30 ft teleport (wrong-ball id swap).
        xy = [[float(i), 10.0] for i in range(30)]
        xy[15] = [45.0, 40.0]
        out, bad = clean_path(xy)
        self.assertTrue(bad.any())
        self.assertLess(abs(out[15][0] - 15.0), 2.0)     # rebuilt near the true path
        self.assertLess(abs(out[15][1] - 10.0), 2.0)
        # Ends stay put.
        self.assertLess(abs(out[0][0] - 0.0), 1.0)
        self.assertLess(abs(out[-1][0] - 29.0), 1.0)

    def test_clean_walk_untouched(self):
        xy = [[float(i), 10.0 + 0.1 * i] for i in range(20)]
        out, bad = clean_path(xy)
        self.assertEqual(int(bad.sum()), 0)
        self.assertLess(np.abs(np.asarray(xy) - out).max(), 0.5)


if __name__ == "__main__":
    unittest.main()
