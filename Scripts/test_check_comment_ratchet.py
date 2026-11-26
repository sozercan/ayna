#!/usr/bin/env python3
"""Unit tests for Scripts/check-comment-ratchet.py."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("check-comment-ratchet.py")
SPEC = importlib.util.spec_from_file_location("check_comment_ratchet", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class CommentRatchetScannerTests(unittest.TestCase):
    def test_detects_block_comment_with_quote_and_paren_inside_interpolation(self) -> None:
        src = 'let value = "\\(1 /* " ) */)"\n// trailing comment\n'
        violations = MOD.scan_swift_text(src)
        self.assertEqual(
            violations,
            [
                (1, '/* " ) */'),
                (2, "// trailing comment"),
            ],
        )

    def test_detects_line_comment_with_paren_inside_multiline_interpolation(self) -> None:
        src = (
            'let s = """\n'
            '\\(1 // ) "\n'
            '+ 2)\n'
            '"""\n'
            '// after\n'
        )
        violations = MOD.scan_swift_text(src)
        self.assertEqual(
            violations,
            [
                (2, '// ) "'),
                (5, "// after"),
            ],
        )

    def test_skips_extended_regex_literals_with_comment_like_sequences(self) -> None:
        src = (
            "let pattern = #/https?://example[.]com/#\n"
            "let blockLike = ##/foo/*bar*/baz/##\n"
            "let multi = #/\n"
            "  https?://example.com\n"
            "  /* not a comment */\n"
            "/#\n"
        )
        self.assertEqual(MOD.scan_swift_text(src), [])

    def test_skips_bare_regex_literal_and_still_flags_following_comment(self) -> None:
        src = (
            "let regex = /foo[//]bar/\n"
            "let ratio = a / b // real comment\n"
        )
        violations = MOD.scan_swift_text(src)
        self.assertEqual(violations, [(2, "// real comment")])

    def test_skips_regex_inside_interpolation_and_flags_comment_after(self) -> None:
        src = 'let msg = "\\(#/https?://example.com/#)" // after\n'
        violations = MOD.scan_swift_text(src)
        self.assertEqual(violations, [(1, "// after")])

    def test_skips_returned_bare_regex_at_top_level_and_in_interpolation(self) -> None:
        src = (
            "func pattern() -> Regex<Substring> { return /foo[//]bar/ }\n"
            'let s = "\\({ return /foo[//]bar/ }())"\n'
            "let ratio = a/b // comment after division\n"
        )
        violations = MOD.scan_swift_text(src)
        self.assertEqual(violations, [(3, "// comment after division")])

    def test_preserves_directives(self) -> None:
        src = (
            "// swift-tools-version: 6.2\n"
            "// swiftformat:options --ifdef no-indent\n"
            "// swiftlint:disable:next nesting\n"
        )
        self.assertEqual(MOD.scan_swift_text(src), [])


if __name__ == "__main__":
    unittest.main()
