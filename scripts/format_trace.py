#!/usr/bin/env python3
"""Parse nginx error log TRACE lines and display them well-formatted.

Usage:
  docker logs llm-intra-gw 2>&1 | grep 'TRACE' | python3 scripts/format_trace.py
"""

import sys
import re
import json


def strip_nginx_suffix(text):
    """Remove nginx's log-line suffix from the TRACE message."""
    # ", client: <IP>, server: _, ..."
    text = re.sub(r",\s*client:.*$", "", text)
    # " while reading|sending ..." (response-phase only)
    text = re.sub(r"\s+while\s+(?:reading|sending)[^,]*$", "", text)
    return text


def extract_trace(line):
    """Pull the trace payload out of a raw nginx error-log line."""
    m = re.search(r"\[TRACE\]\s*(.*)", line)
    if not m:
        return None
    return strip_nginx_suffix(m.group(1)).lstrip()


def format_trace(raw_text):
    """Parse TRACE lines and return a formatted string."""
    sections = []
    current = None
    in_headers = False

    for raw_line in raw_text.strip().split("\n"):
        content = extract_trace(raw_line)
        if not content:
            continue

        # ── Section header ──
        if content.startswith("\u2550"):
            name = content.strip(" \u2550")
            current = {"name": name, "fields": [], "headers": [], "body": None}
            sections.append(current)
            in_headers = False
            continue

        if current is None:
            continue

        # ── Body line ──
        if content.startswith("body:"):
            raw = content[len("body:"):].strip()
            if raw == "(empty)":
                continue
            if raw and raw[0] in "{[":  # noqa: SIM102
                try:
                    current["body"] = json.loads(raw)
                except (json.JSONDecodeError, ValueError):
                    current["body"] = raw
            in_headers = False
            continue

        # ── "headers:" sub-section boundary ──
        if content == "headers:":
            in_headers = True
            continue

        # ── Key: value line ──
        kv = re.match(r"(\S+):\s*(.*)", content)
        if kv:
            key, val = kv.group(1), kv.group(2)
            if in_headers:
                current["headers"].append((key, val))
            else:
                current["fields"].append((key, val))
            continue

    # ── Render ──
    out = []
    for sec in sections:
        out.append(f"\n── {sec['name']} ──")

        for k, v in sec["fields"]:
            out.append(f"  {k}: {v}")

        if sec["headers"]:
            out.append("  headers:")
            for k, v in sec["headers"]:
                out.append(f"    {k}: {v}")

        if sec["body"] is not None:
            out.append("  Body:")
            if isinstance(sec["body"], (dict, list)):
                for line in json.dumps(sec["body"], indent=2, ensure_ascii=False).split("\n"):
                    out.append(f"    {line}")
            else:
                out.append(f"    {sec['body']}")

    return "\n".join(out)


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        print("(no TRACE logs)", file=sys.stderr)
        sys.exit(1)
    print(format_trace(raw))


if __name__ == "__main__":
    main()
