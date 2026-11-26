#!/usr/bin/env python3
"""Enforce a ratcheted budget on non-directive Swift code comments.

Exit 0 when every file's comment count is <= its baseline in `.comment-ratchet.json`
and no new unbaselined file contains non-directive comments.
Use `--update-baseline` to tighten (or initialize) `.comment-ratchet.json` after
removing comments. By default `--update-baseline` refuses to increase any file's
count unless `--allow-increase` is explicitly passed.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from pathlib import Path

DIRECTIVE_PREFIXES = (
    "// swiftlint:",
    "// swiftformat:",
    "// swift-tools-version:",
    "// sourceLocation",
)

SCAN_GLOBS = (
    "Sources/**/*.swift",
    "Tests/**/*.swift",
    "WatchComplication/**/*.swift",
    "Package.swift",
)


def is_directive(comment_text: str) -> bool:
    stripped = comment_text.strip()
    return any(stripped.startswith(prefix) for prefix in DIRECTIVE_PREFIXES)


def scan_swift_text(text: str) -> list[tuple[int, str]]:
    n = len(text)
    line_no = 1
    violations: list[tuple[int, str]] = []

    def is_raw_string_start(pos: int) -> bool:
        j = pos
        while j < n and text[j] == "#":
            j += 1
        return j > pos and j < n and text[j] == '"'

    def is_extended_regex_start(pos: int) -> bool:
        j = pos
        while j < n and text[j] == "#":
            j += 1
        return j > pos and j < n and text[j] == "/"

    REGEX_PREFIX_KEYWORDS = {
        "return",
        "throw",
        "try",
        "await",
        "yield",
        "case",
        "in",
        "where",
        "if",
        "else",
        "while",
        "guard",
        "switch",
        "is",
        "as",
    }

    def is_bare_regex_start(pos: int, prev_token: str) -> bool:
        # In Swift, bare /.../ cannot start with // or /*, cannot have leading space/tab
        # immediately after the opening / (SE-0354), and must close on the same line
        # without an unescaped newline. It only appears in prefix/expression position.
        if text[pos] != "/" or pos + 1 >= n:
            return False
        nxt = text[pos + 1]
        if nxt in ("/", "*", " ", "\t", "\n", "\r"):
            return False
        if prev_token:
            if prev_token in REGEX_PREFIX_KEYWORDS:
                pass
            elif prev_token[-1].isalnum() or prev_token[-1] in (")", "]", "}", "_", '"', "'", "?", "!"):
                return False
        # Verify a closing unescaped '/' exists on the same line (respecting [...] char classes).
        k = pos + 1
        in_class = False
        while k < n and text[k] != "\n":
            c = text[k]
            if c == "\\":
                k += 2
                continue
            if c == "[" and not in_class:
                in_class = True
            elif c == "]" and in_class:
                in_class = False
            elif c == "/" and not in_class:
                return True
            k += 1
        return False

    def skip_line_comment(pos: int) -> int:
        end = text.find("\n", pos)
        if end == -1:
            end = n
        comment_text = text[pos:end]
        if not is_directive(comment_text):
            violations.append((line_no, comment_text.strip()))
        return end

    def skip_block_comment(pos: int) -> int:
        nonlocal line_no
        start_line = line_no
        depth = 1
        k = pos + 2
        while k < n and depth > 0:
            if text[k] == "\n":
                line_no += 1
                k += 1
            elif text[k : k + 2] == "/*":
                depth += 1
                k += 2
            elif text[k : k + 2] == "*/":
                depth -= 1
                k += 2
            else:
                k += 1
        snippet = text[pos:k].splitlines()[0].strip()
        violations.append((start_line, snippet))
        return k

    def skip_extended_regex(pos: int) -> int:
        nonlocal line_no
        j = pos
        while j < n and text[j] == "#":
            j += 1
        hashes = j - pos
        close_seq = "/" + "#" * hashes
        k = j + 1
        while k < n:
            if text[k] == "\n":
                line_no += 1
                k += 1
            elif text[k] == "\\":
                if k + 1 < n and text[k + 1] == "\n":
                    line_no += 1
                k += 2
            elif text[k : k + len(close_seq)] == close_seq:
                return k + len(close_seq)
            else:
                k += 1
        return n

    def skip_bare_regex(pos: int) -> int:
        k = pos + 1
        in_class = False
        while k < n and text[k] != "\n":
            c = text[k]
            if c == "\\":
                k += 2
                continue
            if c == "[" and not in_class:
                in_class = True
            elif c == "]" and in_class:
                in_class = False
            elif c == "/" and not in_class:
                return k + 1
            k += 1
        return k

    def read_identifier(pos: int) -> tuple[str, int]:
        k = pos
        while k < n and (text[k].isalnum() or text[k] == "_"):
            k += 1
        return text[pos:k], k

    def skip_interpolation(pos: int) -> int:
        nonlocal line_no
        depth = 1
        k = pos
        prev_token = "("
        while k < n and depth > 0:
            ch = text[k]
            if ch == "\n":
                line_no += 1
                k += 1
                continue
            if ch == '"' or (ch == "#" and is_raw_string_start(k)):
                k = skip_string(k)
                prev_token = '"'
                continue
            if ch == "#" and is_extended_regex_start(k):
                k = skip_extended_regex(k)
                prev_token = "/"
                continue
            if text[k : k + 2] == "//":
                k = skip_line_comment(k)
                continue
            if text[k : k + 2] == "/*":
                k = skip_block_comment(k)
                continue
            if ch == "/" and is_bare_regex_start(k, prev_token):
                k = skip_bare_regex(k)
                prev_token = "/"
                continue
            if ch == "(":
                depth += 1
                prev_token = "("
                k += 1
            elif ch == ")":
                depth -= 1
                prev_token = ")"
                k += 1
            elif ch.isalpha() or ch == "_":
                prev_token, k = read_identifier(k)
            else:
                if not ch.isspace():
                    prev_token = ch
                k += 1
        return k

    def skip_string(pos: int) -> int:
        nonlocal line_no
        j = pos
        while j < n and text[j] == "#":
            j += 1
        hashes = j - pos
        if text[j : j + 3] == '"""':
            k = j + 3
            close_seq = '"""' + "#" * hashes
            esc_seq = "\\" + "#" * hashes
            while k < n:
                if text[k] == "\n":
                    line_no += 1
                    k += 1
                elif text[k : k + len(esc_seq)] == esc_seq:
                    k += len(esc_seq)
                    if k < n and text[k] == "(":
                        k = skip_interpolation(k + 1)
                    elif k < n:
                        if text[k] == "\n":
                            line_no += 1
                        k += 1
                elif text[k : k + len(close_seq)] == close_seq:
                    return k + len(close_seq)
                else:
                    k += 1
            return n

        k = j + 1
        close_seq = '"' + "#" * hashes
        esc_seq = "\\" + "#" * hashes
        while k < n:
            if text[k] == "\n":
                return k
            if text[k : k + len(esc_seq)] == esc_seq:
                k += len(esc_seq)
                if k < n and text[k] == "(":
                    k = skip_interpolation(k + 1)
                elif k < n:
                    k += 1
            elif text[k : k + len(close_seq)] == close_seq:
                return k + len(close_seq)
            else:
                k += 1
        return n

    i = 0
    prev_token = ""
    while i < n:
        ch = text[i]
        if ch == "\n":
            line_no += 1
            i += 1
            continue

        if ch == '"' or (ch == "#" and is_raw_string_start(i)):
            i = skip_string(i)
            prev_token = '"'
            continue

        if ch == "#" and is_extended_regex_start(i):
            i = skip_extended_regex(i)
            prev_token = "/"
            continue

        if text[i : i + 2] == "//":
            i = skip_line_comment(i)
            continue

        if text[i : i + 2] == "/*":
            i = skip_block_comment(i)
            continue

        if ch == "/" and is_bare_regex_start(i, prev_token):
            i = skip_bare_regex(i)
            prev_token = "/"
            continue

        if ch.isalpha() or ch == "_":
            prev_token, i = read_identifier(i)
            continue

        if not ch.isspace():
            prev_token = ch
        i += 1

    return violations


def scan_swift_comments(path: str) -> list[tuple[int, str]]:
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return scan_swift_text(fh.read())


def collect_swift_files(root: Path) -> list[str]:
    files: set[str] = set()
    for pattern in SCAN_GLOBS:
        for match in glob.glob(str(root / pattern), recursive=True):
            if os.path.isfile(match):
                files.add(os.path.relpath(match, root))
    return sorted(files)


def load_baseline(baseline_path: Path) -> dict[str, int]:
    if not baseline_path.exists():
        return {}
    with open(baseline_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    files = data.get("files", {})
    return {str(k): int(v) for k, v in files.items()}


def write_baseline(baseline_path: Path, counts: dict[str, int]) -> None:
    payload = {
        "schema_version": 1,
        "total_comments": sum(counts.values()),
        "files": {k: counts[k] for k in sorted(counts) if counts[k] > 0},
    }
    with open(baseline_path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=False)
        fh.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Ratcheted Swift comment-ban linter.")
    parser.add_argument(
        "--baseline",
        default=".comment-ratchet.json",
        help="Path to the ratchet baseline JSON (default: .comment-ratchet.json).",
    )
    parser.add_argument(
        "--update-baseline",
        action="store_true",
        help="Write current per-file comment counts to the baseline file (ratchet down).",
    )
    parser.add_argument(
        "--allow-increase",
        action="store_true",
        help="Permit baseline counts to increase when used with --update-baseline.",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="Print every remaining non-directive comment with file:line.",
    )
    args = parser.parse_args()

    root = Path.cwd()
    baseline_path = root / args.baseline
    baseline = load_baseline(baseline_path)

    swift_files = collect_swift_files(root)
    current_counts: dict[str, int] = {}
    all_violations: dict[str, list[tuple[int, str]]] = {}

    for rel_path in swift_files:
        violations = scan_swift_comments(str(root / rel_path))
        if violations:
            current_counts[rel_path] = len(violations)
            all_violations[rel_path] = violations

    if args.list:
        for rel_path, items in all_violations.items():
            for line_no, snippet in items:
                print(f"{rel_path}:{line_no}: {snippet}")
        return 0

    if args.update_baseline:
        if not args.allow_increase:
            increases = []
            for rel_path, count in current_counts.items():
                allowed = baseline.get(rel_path, 0)
                if count > allowed:
                    increases.append((rel_path, allowed, count))
            if increases:
                print("Refusing to raise comment ratchet baseline (pass --allow-increase to override):", file=sys.stderr)
                for rel_path, allowed, count in increases:
                    print(f"  {rel_path}: {allowed} -> {count}", file=sys.stderr)
                return 1
        write_baseline(baseline_path, current_counts)
        print(
            f"Updated {args.baseline}: {sum(current_counts.values())} remaining comments across {len(current_counts)} files."
        )
        return 0

    failures: list[str] = []
    stale_entries: list[str] = []

    for rel_path, count in current_counts.items():
        allowed = baseline.get(rel_path, 0)
        if count > allowed:
            failures.append(f"{rel_path}: found {count} comment(s), ratchet budget is {allowed}")
            for line_no, snippet in all_violations[rel_path]:
                failures.append(f"  {rel_path}:{line_no}: {snippet}")

    for rel_path, allowed in sorted(baseline.items()):
        actual = current_counts.get(rel_path, 0)
        if actual < allowed:
            stale_entries.append(f"{rel_path}: {allowed} -> {actual}")

    if failures:
        print("Comment ratchet check failed:", file=sys.stderr)
        for line in failures:
            print(line, file=sys.stderr)
        print(
            "\nDelete tautologies/stale comments, file an issue for excuses, or move decisions to docs/adr/.",
            file=sys.stderr,
        )
        return 1

    if stale_entries:
        print(
            "Comment count dropped below baseline! Tighten the ratchet by running:\n"
            "  python3 Scripts/check-comment-ratchet.py --update-baseline",
            file=sys.stderr,
        )
        for line in stale_entries:
            print(f"  {line}", file=sys.stderr)
        return 1

    print(
        f"Comment ratchet OK: {sum(current_counts.values())} comment(s) across {len(current_counts)} files (budget {sum(baseline.values())})."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
