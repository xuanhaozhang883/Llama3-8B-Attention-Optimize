"""Executable v3 planning arithmetic, not measured FPGA utilization."""
import unittest


def capacity(clusters):
    if clusters not in (1, 2, 4):
        raise ValueError("supported cluster count: 1, 2, 4")
    old_per_cluster = 152960
    weight = 3 * 128 * 4
    metadata = 3 * (32 + 32) // 8
    return clusters * (old_per_cluster + weight + metadata)


class V3Planning(unittest.TestCase):
    def test_capacity(self):
        for clusters in (1, 2, 4):
            self.assertEqual(capacity(clusters), clusters * 154520)
            self.assertEqual(capacity(clusters) - clusters * 152960, clusters * 1560)

    def test_bank_mapping_bijective(self):
        addresses = {(key & 31, key >> 5) for key in range(128)}
        self.assertEqual(addresses, {(bank, addr) for bank in range(32) for addr in range(4)})

    def test_workload(self):
        rows = 32 * 128
        valid_weights = 32 * sum(range(1, 129))
        self.assertEqual(rows, 4096)
        self.assertEqual(rows * 128, 524288)
        self.assertEqual(valid_weights, 264192)
        self.assertEqual(valid_weights * 128, 33816576)
        self.assertEqual((32 + 8 + 8) * 128 * 128 * 2 // 8, 196608)
        self.assertEqual(rows * 128 * 2 // 8, 131072)

    def test_unsupported_cluster(self):
        with self.assertRaises(ValueError):
            capacity(3)


if __name__ == "__main__":
    unittest.main()
