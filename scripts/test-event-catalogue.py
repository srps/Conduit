#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fixtures for check-event-catalogue.py: a copy of the repository's Sources/
and docs/events.md passes, then one mutation per failure the check exists to
catch, each with the failure it must report, and a few changes it must accept."""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

script = Path(__file__).with_name('check-event-catalogue.py')
repository = script.resolve().parent.parent
PRODUCT = 'Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift'
PM_SIM = 'Sources/pm-sim/VPNFlapScenarios.swift'
LOCATION = 'Sources/PlatformMac/LocationSettingsRecovery.swift'
MENU_BAR = 'Sources/Conduit/App/MenuBarPresentation.swift'
APP = 'Sources/Conduit/App/AppState.swift'
EVENTS = 'docs/events.md'
MUTATED = (PRODUCT, PM_SIM, LOCATION, MENU_BAR, APP, EVENTS)  # restored after each case


def append(path, text):
    return lambda root: (root / path).write_text((root / path).read_text() + '\n' + text + '\n')


def replace(path, old, new):
    def mutate(root):
        source = (root / path).read_text()
        assert old in source, (path, old)
        (root / path).write_text(source.replace(old, new, 1))
    return mutate


def drop_catalogue_row(name):
    def mutate(root):
        lines = (root / EVENTS).read_text().splitlines()
        kept = [line for line in lines if not line.startswith(f'| `{name}` |')]
        assert len(kept) == len(lines) - 1, name
        (root / EVENTS).write_text('\n'.join(kept) + '\n')
    return mutate


def add_catalogue_row(row):
    return replace(EVENTS, '| `vpn.connected` |', f'{row}\n| `vpn.connected` |')


def both(*mutations):
    def mutate(root):
        for mutation in mutations:
            mutation(root)
    return mutate


# (label, mutation, text the failure must contain)
rejected = [
    ('catalogue entry removed', drop_catalogue_row('auth.upstream_not_trusted'),
     '`auth.upstream_not_trusted` is emitted but not catalogued'),
    ('undocumented literal at an event label',
     append(PRODUCT, 'let probe = RuntimeEvent(kind: .auth, event: "auth.brand_new")'),
     '`auth.brand_new` is emitted but not catalogued'),
    ('undocumented literal passed through a helper', append(PRODUCT, 'emitEvent(.health, "upstream.brand_new")'),
     '`upstream.brand_new` is emitted'),
    ('undocumented rawValue in a known family', append(PRODUCT, 'enum Probe: String { case a = "vpn.brand_new" }'),
     '`vpn.brand_new` is emitted'),
    ('undocumented literal in a new family at an event label',
     append(PRODUCT, 'let probe = RuntimeEvent(kind: .health, event: "brandnew.thing")'),
     '`brandnew.thing` is emitted'),
    ('undocumented raw string', append(PRODUCT, 'let probe = #"pac.brand_new"#'), '`pac.brand_new` is emitted'),
    ('unlisted interpolated name', append(PRODUCT, 'let probe = "pac.\\(stage)_done"'), 'built at run time'),
    ('unlisted concatenated name', append(PRODUCT, 'let probe = "routing." + suffix'), 'built at run time'),
    ('catalogued name nothing emits', add_catalogue_row('| `pac.ghost` | Never emitted. |'),
     '`pac.ghost` is catalogued but no product source emits it'),
    ('shorthand catalogue token',
     replace(EVENTS, '`vpn.flap.start` / `vpn.flap.recovered`', '`vpn.flap.start` / `recovered`'),
     '`recovered` is not a full event name'),
    ('built name removed from its file', replace(LOCATION, '"platform.location_" + event', 'prefix + event'),
     'no longer appears in'),
    ('new location report suffix', append(LOCATION, 'report("brand_new", detail)'),
     '`platform.location_brand_new` is built by'),
    ('location suffix in a ternary with a call', append(LOCATION, 'report(check() ? "brand_new" : "failed", detail)'),
     '`platform.location_brand_new` is built by'),
    ('location report fed a variable', append(LOCATION, 'report(name, detail)'), 'is not given a string literal'),
    ('location suffix no longer reported',
     replace(LOCATION, 'report("legacy_retired",', 'report("legacy_cleanup",'),
     '`platform.location_legacy_retired` is listed'),
    ('helper operation renamed', replace(APP, 'changeHelper(\n            "install",', 'changeHelper(\n            "repair",'),
     '`helper.repair_failed` is built by'),
    ('multi-line literal', append(PRODUCT, 'let probe = """\n    auth.brand_new\n    """'),
     '`auth.brand_new` is emitted'),
    ('raw multi-line literal', append(PRODUCT, 'let probe = #"""\n    auth.brand_new\n    """#'),
     '`auth.brand_new` is emitted'),
    ('unicode escape', append(PRODUCT, 'let probe = RuntimeEvent(kind: .auth, event: "auth.\\u{62}rand_new")'),
     '`auth.brand_new` is emitted'),
    ('concatenation across spaces', append(PRODUCT, 'let probe = "auth."    + "brand_new"'), 'built at run time'),
    ('concatenation across a comment', append(PRODUCT, 'let probe = "auth." /* suffix */ + "brand_new"'),
     'built at run time'),
    ('event label with a space', append(PRODUCT, 'let probe = RuntimeEvent(kind: .health, event : "brandnew.thing")'),
     '`brandnew.thing` is emitted'),
    ('event label then a long comment',
     append(PRODUCT, 'RuntimeEvent(kind: .health, event: /* a comment longer than forty characters */ "brandnew.thing")'),
     '`brandnew.thing` is emitted'),
    ('line continuation after trailing spaces',
     append(PRODUCT, 'let probe = """\n    auth.\\  \n    brand_new\n    """'), '`auth.brand_new` is emitted'),
    ('helper name assembled differently',
     replace(APP, '"helper.\\(operation)_failed"', '"helper.\\(operation + "_extra")_failed"'),
     'is no longer built as'),
    ('location name assembled differently',
     replace(LOCATION, '"platform.location_" + event, detail', '"platform.location_" + event + "_extra", detail'),
     'is no longer built as'),
    ('multi-line line continuation',
     append(PRODUCT, 'let probe = """\n    auth.\\\n    brand_new\n    """'), '`auth.brand_new` is emitted'),
    ('feeding call inside an interpolation', append(LOCATION, 'let probe = "\\(report("brand_new", detail))"'),
     '`platform.location_brand_new` is built by'),
    ('concatenation inside an interpolation', append(PRODUCT, 'let probe = "\\("auth." + suffix)"'),
     'built at run time'),
    ('event label inside an interpolation',
     append(PRODUCT, 'let probe = "\\(RuntimeEvent(kind: .health, event: "brandnew.thing"))"'),
     '`brandnew.thing` is emitted'),
    ('comment opener inside a regex literal',
     append(PRODUCT, 'let r = #/a/*/#\nlet probe = RuntimeEvent(kind: .auth, event: "auth.brand_new")'),
     '`auth.brand_new` is emitted'),
    ('parenthesised concatenation', append(PRODUCT, 'RuntimeEvent(kind: .auth, event: ("auth.") + suffix)'),
     'built at run time'),
    ('parenthesised event argument', append(PRODUCT, 'RuntimeEvent(kind: .auth, event: ("brandnew.one"))'),
     '`brandnew.one` is emitted'),
    ('ternary event argument',
     append(PRODUCT, 'RuntimeEvent(kind: .auth, event: flag ? "brandnew.one" : "brandnew.two")'),
     '`brandnew.two` is emitted'),
    ('raw string with a long delimiter',
     append(PRODUCT, 'let probe = ########"auth.\\########u{62}rand_new"########'), '`auth.brand_new` is emitted'),
    ('indented catalogue row with no emitter', add_catalogue_row('  | `pac.ghost` | Never emitted. |'),
     '`pac.ghost` is catalogued but no product source emits it'),
    ('pm-sim asserts on an undocumented name',
     append(PM_SIM, 'let probe = events.filter { $0.event == "vpn.brand_new" }'),
     'pm-sim refers to `vpn.brand_new`'),
    ('NOT_EVENTS entry no longer used', replace(MENU_BAR, '"network.slash"', '"wifi.slash"'),
     '"network.slash" is listed'),
]

accepted = [
    ('literal inside a line comment', append(PRODUCT, '// emits "auth.in_comment" one day')),
    ('literal inside a nested block comment',
     append(PRODUCT, '/* outer /* "auth.in_block" */ still "auth.in_block" */')),
    ('planned entry with no emitter', add_catalogue_row('| `pac.future` *(planned)* | Reserved. |')),
    ('planned marker in the description', add_catalogue_row('| `pac.future` | Reserved. *(planned)* |')),
    ('literal in a comment inside an interpolation',
     append(PRODUCT, 'let probe = "count=\\( /* "auth.in_comment" */ count)"')),
    ('string inside a regex literal', append(PRODUCT, 'let r = #/"auth.brand_new"/#')),
    ('a declaration named event',
     append(PRODUCT, 'let event: String = "proxy.starting"\nlet host = "somewhere.example.test"')),
    ('unicode identifier', append(PRODUCT, 'let café = 1')),
    ('commented-out location report', append(LOCATION, '// report("brand_new", detail)')),
    ('newly emitted and catalogued', both(
        append(PRODUCT, 'let probe = RuntimeEvent(kind: .auth, event: "auth.brand_new")'),
        add_catalogue_row('| `auth.brand_new` | Documented. |'))),
    ('message text in an event family', append(PRODUCT, 'let probe = "pac.refreshed \\(count) times"')),
]


def run(root):
    return subprocess.run([sys.executable, str(script), str(root)], capture_output=True, text=True)


with tempfile.TemporaryDirectory(prefix='conduit-events-') as directory:
    base = Path(directory)
    shutil.copytree(repository / 'Sources', base / 'Sources')
    (base / 'docs').mkdir()
    shutil.copy(repository / EVENTS, base / EVENTS)
    result = run(base)
    assert result.returncode == 0, ('copy of the repository failed', result.stderr)
    originals = {path: (base / path).read_text() for path in MUTATED}
    cases = rejected + [(label, mutate, None) for label, mutate in accepted]
    for label, mutate, expected in cases:
        mutate(base)
        result = run(base)
        for path, text in originals.items():
            (base / path).write_text(text)
        if expected is None:
            assert result.returncode == 0, (label, 'was rejected', result.stderr)
        else:
            assert result.returncode != 0, (label, 'was accepted', result.stdout)
            assert expected in result.stderr, (label, 'failed for another reason', result.stderr)

result = run(repository)
assert result.returncode == 0, ('repository', result.stderr)
print(f'PASS: event catalogue check accepts the repository and {len(accepted)} benign changes, '
      f'rejects {len(rejected)} mutations')
