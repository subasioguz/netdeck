#!/usr/bin/env python3
"""Checks the Turkish string table against the keys the code uses.

Extracts every key passed to `t("...")` (and to small wrappers that hand their first argument
to `t()`, such as `fill("...", ...)` in HistoryScreen) from Sources/Netdeck and
Sources/NetdeckCore, parses tr.lproj/Localizable.strings and prints:

  - missing keys (used in code, not in the table)       -> exit code 1
  - unused keys (in the table, not found in code)
  - duplicate keys in the table
  - placeholder mismatches (number of %@ in key vs value)
  - suspicious calls: string interpolation inside a key, non-literal keys, other format specifiers

Standard library only. Run from the repository root:  python3 -I scripts/check-l10n.py
Options: --quiet (summary and problems only), --strings PATH (another table).
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIRS = [os.path.join(ROOT, "Sources", "Netdeck"), os.path.join(ROOT, "Sources", "NetdeckCore")]
DEFAULT_TABLE = os.path.join(ROOT, "Sources", "NetdeckCore", "Resources", "tr.lproj", "Localizable.strings")
PLACEHOLDER = re.compile(r"%(?:\d+\$)?@")
OTHER_SPEC = re.compile(r"%(?!@|%|\d+\$@)[-+ #0]*\d*(?:\.\d+)?[a-zA-Z]")


# ---------------------------------------------------------------------------------------------
# Swift sources

def strip_comments(src):
    """Blanks out // and /* */ comments while keeping string literals and line numbers intact."""
    out = []
    i, n = 0, len(src)
    in_str = False
    multiline = False
    while i < n:
        c = src[i]
        if in_str:
            if multiline and src.startswith('"""', i):
                out.append('"""'); i += 3; in_str = False; continue
            if c == "\\" and i + 1 < n:
                out.append(src[i:i + 2]); i += 2; continue
            if c == '"' and not multiline:
                in_str = False
            out.append(c); i += 1; continue
        if src.startswith('"""', i):
            in_str = True; multiline = True; out.append('"""'); i += 3; continue
        if c == '"':
            in_str = True; multiline = False; out.append(c); i += 1; continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i)); i = j; continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(ch if ch == "\n" else " " for ch in src[i:j])); i = j; continue
        out.append(c); i += 1
    return "".join(out)


def read_literal(src, i):
    """Reads a Swift string literal starting at src[i] == '"'. Returns (value, end, problems)."""
    assert src[i] == '"'
    if src.startswith('"""', i):
        return None, i + 3, ["multi-line string literal used as a key"]
    j = i + 1
    value = []
    problems = []
    while j < len(src):
        c = src[j]
        if c == "\\":
            nxt = src[j + 1] if j + 1 < len(src) else ""
            if nxt == "(":
                problems.append("string interpolation \\( inside a key")
                depth, j = 1, j + 2
                while j < len(src) and depth:
                    if src[j] == "(":
                        depth += 1
                    elif src[j] == ")":
                        depth -= 1
                    j += 1
                value.append("\\(…)")
                continue
            if nxt == "u" and j + 2 < len(src) and src[j + 2] == "{":
                end = src.index("}", j)
                value.append(chr(int(src[j + 3:end], 16)))
                j = end + 1
                continue
            value.append({"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}.get(nxt, nxt))
            j += 2
            continue
        if c == '"':
            return "".join(value), j + 1, problems
        if c == "\n":
            return None, j, ["unterminated string literal"]
        value.append(c)
        j += 1
    return None, j, ["unterminated string literal"]


def find_wrappers(src):
    """Functions like `func fill(_ key: String, ...)` whose body passes that parameter to t()."""
    names = set()
    for m in re.finditer(r"func\s+(\w+)\s*\(\s*_\s+(\w+)\s*:\s*String\b", src):
        name, param = m.group(1), m.group(2)
        brace = src.find("{", m.end())
        if brace < 0:
            continue
        depth, j = 0, brace
        while j < len(src):
            if src[j] == "{":
                depth += 1
            elif src[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        body = src[brace:j]
        if re.search(r"(?<![\w.])t\(\s*" + re.escape(param) + r"\b", body):
            names.add(name)
    return names


def line_of(src, pos):
    return src.count("\n", 0, pos) + 1


def first_argument_end(src, i):
    """Index of the `,` or `)` that ends the call's first argument (string literals skipped)."""
    depth = 0
    while i < len(src):
        c = src[i]
        if c == '"':
            _, i, _ = read_literal(src, i)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return i
            depth -= 1
        elif c == "," and depth == 0:
            return i
        i += 1
    return i


def scan_sources():
    files = []
    for d in SOURCE_DIRS:
        for base, _, names in os.walk(d):
            files += [os.path.join(base, n) for n in names if n.endswith(".swift")]
    files.sort()
    sources = {}
    wrappers = set()
    for f in files:
        with open(f, encoding="utf-8") as fh:
            sources[f] = strip_comments(fh.read())
        wrappers |= find_wrappers(sources[f])
    callers = ["t"] + sorted(wrappers)
    call = re.compile(r"(?<![\w.])(" + "|".join(map(re.escape, callers)) + r")\(\s*")
    keys = {}            # key -> [(file, line)]
    problems = []        # (file, line, message)
    dynamic = []         # (file, line, text)
    for f, src in sources.items():
        rel = os.path.relpath(f, ROOT)
        for m in call.finditer(src):
            # Skip the declarations themselves (`func t(_ key: String, ...)`).
            if re.search(r"func\s+$", src[max(0, m.start() - 12):m.start()]):
                continue
            i = m.end()
            ln = line_of(src, m.start())
            if i < len(src) and src[i] == '"':
                value, end, probs = read_literal(src, i)
                for p in probs:
                    problems.append((rel, ln, p))
                if value is None:
                    continue
                # A key glued together with `+` is not a key the table can hold.
                rest = src[end:end + 3].lstrip()
                if rest.startswith("+"):
                    problems.append((rel, ln, "key built with + concatenation: " + repr(value)))
                keys.setdefault(value, []).append((rel, ln))
            elif src.startswith("#\"", i):
                problems.append((rel, ln, "raw string literal used as a key"))
            else:
                # `t(flag ? "A" : "B")`: both branches are keys.
                arg_end = first_argument_end(src, i)
                branch = re.match(r'[^"(),]*\?\s*(?=")', src[i:arg_end])
                if branch:
                    j = i + branch.end()
                    a, j, probs_a = read_literal(src, j)
                    colon = re.match(r'\s*:\s*(?=")', src[j:arg_end])
                    if a is not None and colon:
                        b, _, probs_b = read_literal(src, j + colon.end())
                        for p in probs_a + probs_b:
                            problems.append((rel, ln, p))
                        for v in (a, b):
                            if v is not None:
                                keys.setdefault(v, []).append((rel, ln))
                        continue
                arg = src[i:src.find("\n", i)].strip()
                dynamic.append((rel, ln, m.group(1) + "(" + arg[:60]))
    return keys, problems, dynamic, sorted(wrappers)


# ---------------------------------------------------------------------------------------------
# .strings table

def parse_strings(path):
    """Returns ([(key, value, line)], errors). Understands comments and the usual escapes."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    entries, errors = [], []
    i, n = 0, len(text)

    def skip_ws(i):
        while i < n:
            if text[i].isspace():
                i += 1
            elif text.startswith("/*", i):
                j = text.find("*/", i + 2)
                if j < 0:
                    errors.append((line_of(text, i), "unterminated comment"))
                    return n
                i = j + 2
            elif text.startswith("//", i):
                j = text.find("\n", i)
                i = n if j < 0 else j + 1
            else:
                break
        return i

    def read_quoted(i):
        assert text[i] == '"'
        j, out = i + 1, []
        while j < n:
            c = text[j]
            if c == "\\":
                nxt = text[j + 1] if j + 1 < n else ""
                if nxt in "uU":
                    out.append(chr(int(text[j + 2:j + 6], 16)))
                    j += 6
                    continue
                out.append({"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}.get(nxt, nxt))
                j += 2
                continue
            if c == '"':
                return "".join(out), j + 1
            out.append(c)
            j += 1
        raise ValueError("unterminated string")

    while True:
        i = skip_ws(i)
        if i >= n:
            break
        ln = line_of(text, i)
        try:
            if text[i] != '"':
                raise ValueError("expected a quoted key")
            key, i = read_quoted(i)
            i = skip_ws(i)
            if i >= n or text[i] != "=":
                raise ValueError("expected =")
            i = skip_ws(i + 1)
            if i >= n or text[i] != '"':
                raise ValueError("expected a quoted value")
            value, i = read_quoted(i)
            i = skip_ws(i)
            if i >= n or text[i] != ";":
                raise ValueError("expected ;")
            i += 1
            entries.append((key, value, ln))
        except ValueError as e:
            errors.append((ln, str(e)))
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
    return entries, errors


# ---------------------------------------------------------------------------------------------

def main():
    quiet = "--quiet" in sys.argv
    table = DEFAULT_TABLE
    if "--strings" in sys.argv:
        table = sys.argv[sys.argv.index("--strings") + 1]
    keys, problems, dynamic, wrappers = scan_sources()
    entries, parse_errors = parse_strings(table)

    seen, duplicates = {}, []
    for key, value, ln in entries:
        if key in seen:
            duplicates.append((key, seen[key][1], ln, seen[key][0] == value))
        else:
            seen[key] = (value, ln)

    missing = sorted(k for k in keys if k not in seen)
    unused = sorted(k for k in seen if k not in keys)
    mismatched = []
    for key in sorted(keys):
        if key not in seen:
            continue
        value, ln = seen[key]
        a, b = len(PLACEHOLDER.findall(key)), len(PLACEHOLDER.findall(value))
        if a != b:
            mismatched.append((key, value, ln, a, b))
    specs = [(k, keys[k][0]) for k in sorted(keys) if OTHER_SPEC.search(k.replace("%%", ""))]

    def show(title, rows):
        print("\n%s (%d)" % (title, len(rows)))
        for r in rows:
            print("  " + r)

    rel_table = os.path.relpath(table, ROOT)
    print("Localization check: %s" % rel_table)
    print("Key helpers: %s" % ", ".join(["t"] + wrappers))
    if parse_errors:
        show("Table parse errors", ["line %d: %s" % e for e in parse_errors])
    show("Missing keys", ["%r  (%s:%d)" % (k, *keys[k][0]) for k in missing])
    if not quiet or problems:
        show("Problems in code", ["%s:%d: %s" % p for p in problems])
    show("Placeholder count mismatches", ["line %d: %r -> %r (%d vs %d)" % (ln, k, v, a, b) for k, v, ln, a, b in mismatched])
    show("Duplicate keys", ["%r  (lines %d and %d%s)" % (k, a, b, ", same value" if same else ", different values")
                            for k, a, b, same in duplicates])
    if specs:
        show("Keys with non-%@ format specifiers", ["%r  (%s:%d)" % (k, *loc) for k, loc in specs])
    if not quiet:
        show("Unused keys (in the table, not found in code)", ["%r  (line %d)" % (k, seen[k][1]) for k in unused])
        show("Non-literal keys (not checked)", ["%s:%d: %s" % d for d in dynamic])

    translated = sum(1 for k in keys if k in seen)
    print("\nSummary: %d keys in code, %d translated, %d missing, %d unused, %d duplicates, "
          "%d placeholder mismatches, %d problems in code, %d table entries"
          % (len(keys), translated, len(missing), len(unused), len(duplicates), len(mismatched), len(problems), len(entries)))
    return 1 if missing or parse_errors else 0


if __name__ == "__main__":
    sys.exit(main())
