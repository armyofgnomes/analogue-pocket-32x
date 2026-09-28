#!/usr/bin/env python3
"""Tests for reverse_bits.py. Run: python3 tools/test_reverse_bits.py"""

import unittest

from reverse_bits import reverse_bits


class ReverseBitsTest(unittest.TestCase):
    def test_known_values(self):
        self.assertEqual(reverse_bits(bytes([0x01, 0x80, 0xF0, 0xA5, 0x00, 0xFF])),
                         bytes([0x80, 0x01, 0x0F, 0xA5, 0x00, 0xFF]))
        self.assertEqual(reverse_bits(b"\x12"), b"\x48")

    def test_involution(self):
        data = bytes(range(256))
        self.assertEqual(reverse_bits(reverse_bits(data)), data)


if __name__ == "__main__":
    unittest.main()
