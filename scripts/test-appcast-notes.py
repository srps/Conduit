#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check the HTML that scripts/appcast-notes.py puts in the update feed.

    python3 scripts/test-appcast-notes.py

Renders a fixed CHANGELOG fixture and the real CHANGELOG.md, and requires
that no Markdown syntax is left visible and that links point where intended.
"""
import importlib.util
from pathlib import Path
import re
import sys
import xml.dom.minidom

# Importing the renderer must not leave scripts/__pycache__ behind.
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("appcast_notes", ROOT / "scripts" / "appcast-notes.py")
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)

FIXTURE = """# Changelog

## Unreleased

- Not this one.

## 9.9.0

Intro with **bold**, `code <tag>` and [a doc](docs/x.md).
Second line of the same paragraph, and [a site](https://example.com/a?b=1&c=2).

**Upgrading:** run this once:

```sh
sudo install --flag "a & b" <x>
```

### Added

- An item with `a **literal** inside code`
  continued on the next line.
- A second item ]]> with a CDATA terminator.

### Fixed

- Fixed.

## 9.8.0

- Older.
"""

failures = []


def check(name, condition):
    if not condition:
        failures.append(name)


def well_formed(html_text):
    try:
        xml.dom.minidom.parseString(f"<root><![CDATA[{html_text}]]></root>")
        xml.dom.minidom.parseString(f"<root>{html_text}</root>")
        return True
    except Exception as error:  # Reported as a failed check below.
        print(f"not well formed: {error}")
        return False


section = notes.section(FIXTURE, "9.9.0")
html = notes.render(section, "9.9.0")
print(html)

check("only the requested section", "Not this one" not in html and "Older" not in html)
check("bold becomes <strong>", "<strong>bold</strong>" in html and "<strong>Upgrading:</strong>" in html)
check("inline code is escaped and kept literal",
      "<code>code &lt;tag&gt;</code>" in html and "<code>a **literal** inside code</code>" in html)
check("relative links point at the tagged tree",
      '<a href="https://github.com/srps/Conduit/blob/v9.9.0/docs/x.md">a doc</a>' in html)
check("absolute links are kept and escaped",
      '<a href="https://example.com/a?b=1&amp;c=2">a site</a>' in html)
check("paragraph lines are joined", "<p>Intro with" in html and "same paragraph, and" in html)
check("fenced code becomes an escaped block",
      '<pre><code>sudo install --flag &quot;a &amp; b&quot; &lt;x&gt;</code></pre>' in html)
check("headings and lists", "<h3>Added</h3>" in html and "<h3>Fixed</h3>" in html
      and "<li>An item with <code>a **literal** inside code</code> continued on the next line.</li>" in html)
check("the CDATA terminator is neutralised", "]]>" not in html)
outside_code = re.sub(r"<code>.*?</code>", "", html, flags=re.S)
check("no Markdown syntax left visible", not re.search(r"\*\*|```|`|\]\(|^#", outside_code, re.M))
check("fixture notes are well formed", well_formed(html.replace("]]&gt;", "")))

check("a missing version falls back to one line", notes.render(notes.section(FIXTURE, "1.0.0"), "1.0.0") == "<p>Conduit 1.0.0.</p>")

changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
if re.search(rf"^## {re.escape(version)}$", changelog, re.M):
    real = notes.render(notes.section(changelog, version), version)
    real_outside_code = re.sub(r"<code>.*?</code>", "", real, flags=re.S)
    check(f"CHANGELOG {version} leaves no Markdown visible",
          not re.search(r"\*\*|```|`|\]\(", real_outside_code))
    check(f"CHANGELOG {version} notes are well formed", well_formed(real))

if failures:
    for name in failures:
        print(f"FAIL: {name}")
    raise SystemExit(1)
print("appcast notes: all checks passed")
