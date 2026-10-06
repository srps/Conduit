#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Release notes for the update feed: one version's CHANGELOG section as HTML.

Sparkle shows this HTML in its update window. Headings, paragraphs, bullet
lists, fenced code, and inline code, bold and links are rendered (relative
links point at the tagged tree); everything else is escaped text.

    python3 scripts/appcast-notes.py VERSION [CHANGELOG.md]
"""
import html
import re
import sys


def section(changelog, version):
    """The body of `## VERSION`, or a one-line fallback."""
    match = re.search(rf"^## {re.escape(version)}\n(.*?)(?=^## |\Z)", changelog, re.S | re.M)
    return match.group(1).strip() if match else f"Conduit {version}."


def render(markdown, version):
    tree = f"https://github.com/srps/Conduit/blob/v{version}/"

    def link(m):
        target = html.unescape(m.group(2))
        if not re.match(r"[a-z]+:", target):
            target = tree + target
        return f'<a href="{html.escape(target, quote=True)}">{m.group(1)}</a>'

    def inline(s):
        out = []
        for part in re.split(r"(`[^`]+`)", s):
            if len(part) > 1 and part.startswith("`") and part.endswith("`"):
                out.append(f"<code>{html.escape(part[1:-1])}</code>")
                continue
            part = html.escape(part)
            part = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", part)
            part = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, part)
            out.append(part)
        return "".join(out)

    blocks, items, para, code = [], [], [], None

    def flush():
        if para:
            blocks.append("<p>" + inline(" ".join(para)) + "</p>")
            para.clear()
        if items:
            blocks.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
            items.clear()

    def close_code():
        blocks.append("<pre><code>" + html.escape("\n".join(code)) + "</code></pre>")

    for line in markdown.splitlines():
        if code is not None:
            if line.startswith("```"):
                close_code()
                code = None
            else:
                code.append(line)
        elif line.startswith("```"):
            flush()
            code = []
        elif line.startswith("### "):
            flush()
            blocks.append(f"<h3>{inline(line[4:])}</h3>")
        elif line.startswith("- "):
            if para:
                flush()
            items.append(line[2:].strip())
        elif line.startswith("  ") and items:
            items[-1] += " " + line.strip()
        elif not line.strip():
            flush()
        else:
            if items:
                flush()
            para.append(line.strip())
    if code is not None:
        close_code()
    flush()
    # The notes go inside CDATA.
    return "\n".join(blocks).replace("]]>", "]]&gt;")


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit("usage: appcast-notes.py VERSION [CHANGELOG.md]")
    version = sys.argv[1]
    path = sys.argv[2] if len(sys.argv) == 3 else "CHANGELOG.md"
    with open(path, encoding="utf-8") as changelog:
        print(render(section(changelog.read(), version), version))
