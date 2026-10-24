#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check that docs/events.md catalogues every RuntimeEvent name in Sources/ (#179).

An interim gate until typed events (#180) generate the catalogue; retire it
then. Event names are free strings today, so this reads them out of the Swift
source text:

1. A small Swift tokenizer turns each file into string literals, words and
   punctuation, dropping comments and `#/…/#` regex literals. Literals are
   decoded (escapes, multi-line indentation, line continuations);
   interpolations become `\\(…)` and their expressions are tokenized too.
2. A literal is an event name when it fits the grammar `family.what[.more]`
   (lowercase, digits and `_`) and either its family is a known event family
   (FAMILIES, plus every family the catalogue uses) or it sits anywhere in the
   argument of an `event:` label. That catches names passed through enums, helpers and
   variables, as long as the full name is a literal somewhere.
3. A literal in an event family that is interpolated or next to a `+` builds a
   name at run time. It must be one of BUILT_NAMES, whose assembling
   expression must still read as recorded, and whose produced names are read
   from the calls that feed it and compared both ways with the names the
   entry lists. A `+` chain of plain literals is folded first and read as the
   name it spells, so `"lifecycle" + "." + "superseded"` is checked as a whole.
   NOT_EVENTS lists literals in event families that are not event names (file
   names, hosts, config keys, symbols).

The catalogue is the first column of the tables under "## Event catalogue":
every backticked token there is a full event name. A row containing
*(planned)* needs no emitter.

Failures:
- a name in product sources (Sources/ minus pm-sim) missing from the catalogue;
- a catalogued name, not planned, that no product source contains;
- a name pm-sim refers to that is neither catalogued nor in PM_SIM_FIXTURES;
- a built literal that is not a BUILT_NAMES template, a template gone from its
  file, or a call feeding it whose first argument holds no string literal, or
  calls that produce a different set of names than the entry lists;
- a catalogue token that is not a full name (shorthand such as `/ started`);
- a NOT_EVENTS or PM_SIM_FIXTURES entry no source uses any more.

Blind spots. The check is a heuristic over literals, not over what runs:
- a name assembled from pieces none of which is a family literal (for example
  `[family, what].joined(separator: ".")`, or a prefix held in a constant and
  a rawValue `"started"`), and a name in a family the catalogue does not use
  yet that never sits at an `event:` label, are not seen;
- a `+` chain is folded only across plain literals: past a variable, the
  chain's concrete prefix is read but the variable's part is not, so
  `"lifecycle" + "." + suffix` is caught as the closed `lifecycle.` prefix while
  the name `suffix` supplies is not;
- any literal in an event family counts as an emitter: an unrelated string
  such as a test host `"auth.example.test"` fails until it is listed in
  NOT_EVENTS, and an event name kept in product code only as a consumer
  (a UI match, a constant) keeps its catalogue row alive after the emitter
  is gone;
- a feeding call's first argument is read for its literals only, so
  `report(x ?? "a")` counts as building just the name from "a";
- a line continuation in a multi-line literal drops all of the next line's
  indentation, where Swift keeps what exceeds the closing delimiter's;
- a bare `/…/` regex literal is read as code, so a quote or comment opener
  inside one can confuse the tokenizer (Sources/ has none today);
- names in Tests/ are not read, and the `kind` a name is emitted with is not
  compared with the catalogue section it sits in.
All need a reviewer until #180 makes names a type.

Authority. This is a static check over the recognised forms only: plain, raw and
escaped literals, interpolations, and `+` chains of literals. It does not prove what
a computed string is. The run-time precondition behind the legacy RuntimeEvent init
(which calls RuntimeEventPayload.requiresTypedPayload) stays the authority; this gate
stops the recognised forms from reaching it unreviewed.

Typed families (decision 0013). The `lifecycle.*` names with a typed value are
pinned in TYPED_NAMES below and must match `LifecycleEventName` in
Sources/RuntimeEvents. The `lifecycle.` namespace is closed: a literal in it
outside Sources/RuntimeEvents and the wire's spelling is a failure, with no
exception list, so every emitter and consumer goes through the typed value. A
built name in that namespace is caught by the run-time rule above. The kernel's
legacy envelope must keep refusing the whole namespace (`requiresTypedPayload`,
which must still test the `lifecycle.` prefix). This is a checked inventory, not
a naming convention: the types are what stop an untyped producer, and this check
stops a later edit from quietly removing that.

Usage: check-event-catalogue.py [ROOT]
"""
import bisect
import re
import sys
from pathlib import Path

NAME = re.compile(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$')
# A built literal that could be (part of) a name: name characters and
# interpolations only, with a family and a dot. Messages and keys with spaces,
# capitals or brackets are not names.
BUILT_NAME = re.compile(r'^[a-z][a-z0-9_]*\.([a-z0-9_.]|\\\(…\))*$')
# Families that carry events. A family is also known when the catalogue uses it.
FAMILIES = {
    'auth', 'config', 'connection', 'connectivity', 'daemon', 'direct', 'direct_mode', 'dns',
    'error_rate', 'health', 'helper', 'lifecycle', 'local_pac', 'network', 'observability', 'pac',
    'platform', 'proxy', 'recovery', 'request', 'routing', 'streaming', 'tcp_relay',
    'transparent_proxy', 'tunnel', 'update', 'upstream', 'vpn',
}
# Names with no family: the ring buffer's placeholder.
UNDOTTED_EVENTS = {'init'}
# Literals in an event family that are not event names.
NOT_EVENTS = {
    'config.json', 'platform.json', 'proxy.log', 'proxy.pac',      # state and fixture files
    'proxy.host', 'proxy.port',                                     # config validation keys
    'network.slash', 'network.badge.shield.half.filled',            # SF Symbol names
    'proxy.example.com', 'proxy.example.test', 'proxy.corp.sim.example',  # example hosts
    'pac.fixture',                                                  # pm-sim PAC host
    'proxy.http.response.backpressure.\\(…)',                       # NIO observer name
}


class Built:
    """A literal that builds names: `template` as lexed, in `file`, inside the
    source text `expression`, which must appear verbatim so any change to how
    the name is assembled fails here. It is fed by the first argument of each
    call to `caller` in that file; `pattern` turns the argument into the name.
    `names` is what the entry expects."""

    def __init__(self, file, template, expression, caller, pattern, names):
        self.file, self.template, self.expression = file, template, expression
        self.caller, self.pattern, self.names = caller, pattern, names


BUILT_NAMES = [
    Built('Sources/PlatformMac/LocationSettingsRecovery.swift', 'platform.location_',
          'event: "platform.location_" + event, detail:', 'report', 'platform.location_{}', {
              'platform.location_apply', 'platform.location_cleanup_deferred', 'platform.location_contended',
              'platform.location_deleted', 'platform.location_external_preserved', 'platform.location_failed',
              'platform.location_legacy_cleanup', 'platform.location_legacy_retired',
              'platform.location_reconcile', 'platform.location_restore', 'platform.location_retry',
          }),
    Built('Sources/Conduit/App/AppState.swift', 'helper.\\(…)_failed',
          'event: "helper.\\(operation)_failed", detail:', 'changeHelper', 'helper.{}_failed',
          {'helper.install_failed', 'helper.uninstall_failed'}),
]
# The typed migration inventory (decision 0013): every lifecycle name with a
# typed value, which is the whole family. Changing it is a reviewed change to
# LifecycleEventName as well.
TYPED_NAMES = {
    'lifecycle.superseded', 'lifecycle.coalesced', 'lifecycle.termination_drain_expired',
    'lifecycle.version_changed',
}
TYPED_DIRECTORY = 'Sources/RuntimeEvents/'
TYPED_INVENTORY = 'Sources/RuntimeEvents/LifecycleEvents.swift'
LIFECYCLE_NAMESPACE = 'lifecycle.'
# The kernel's legacy envelope gate. It must test the namespace prefix, with no exception list.
PAYLOAD_INVENTORY = 'Sources/RuntimeEvents/RuntimeEventPayload.swift'
# The wire's spelling of the typed names: a projection of the typed value, pinned to the
# same inventory, so its literals are allowed outside the typed directory.
WIRE_TYPED_FILE = 'Sources/ConduitShared/ControlRuntimeEventTyped.swift'
KERNEL_EVENT = 'Sources/ProxyKernel/Models/RuntimeEvent.swift'
# Names only pm-sim uses: synthetic events it builds to test sinks and
# writers, and a report name the updater contract must reject. Never emitted
# by a product binary.
PM_SIM_FIXTURES = {'routing.test', 'pm_sim.action_failed', 'fixture.\\(…)', 'update.quit_now'}
PM_SIM = 'Sources/pm-sim/'

SIMPLE_ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', '0': '\0', '"': '"', "'": "'", '\\': '\\'}
RAW_STRING = re.compile(r'#+"')
REGEX_LITERAL = re.compile(r'(#+)/')
WORD = re.compile(r'\w+')


class Token:
    __slots__ = ('kind', 'text', 'line', 'interpolated')

    def __init__(self, kind, text, line, interpolated=False):
        self.kind, self.text, self.line, self.interpolated = kind, text, line, interpolated


class Tokenizer:
    """Tokens of a Swift file: ('str', decoded text), ('word', identifier) and
    ('punct', one character). Comments, whitespace and extended-delimiter
    regex literals (`#/…/#`) are dropped. Each interpolation's expression is
    tokenized as a stream of its own, appended after the file's tokens behind
    a `;`, so the literal it sits in keeps its real neighbours."""

    def __init__(self, source):
        self.source, self.n = source, len(source)
        self.newlines = [i for i, c in enumerate(source) if c == '\n']
        self.streams = []

    def tokens(self):
        main = []
        self.scan(0, main, inside_interpolation=False)
        for stream in self.streams:
            main.append(Token('punct', ';', stream[0].line if stream else 0))
            main.extend(stream)
        return main

    def line_at(self, i):
        return bisect.bisect_right(self.newlines, i - 1) + 1

    def skip_comment(self, i):
        """Index after a comment or `#/…/#` regex at `i`, or `i` when there is none."""
        source, n = self.source, self.n
        if source.startswith('//', i):
            end = source.find('\n', i)
            return n if end < 0 else end
        if source.startswith('/*', i):
            depth = 0
            while i < n:
                if source.startswith('/*', i):
                    depth, i = depth + 1, i + 2
                elif source.startswith('*/', i):
                    depth, i = depth - 1, i + 2
                    if depth == 0:
                        return i
                else:
                    i += 1
            return n
        regex = REGEX_LITERAL.match(source, i)
        if regex:
            end = source.find('/' + regex.group(1), regex.end())
            return n if end < 0 else end + 1 + len(regex.group(1))
        return i

    def scan(self, i, out, inside_interpolation):
        """Tokenize from `i`. Inside an interpolation, stop after its `)`."""
        source, depth = self.source, 1
        while i < self.n:
            after_comment = self.skip_comment(i)
            if after_comment != i:
                i = after_comment
                continue
            c = source[i]
            if c == '"' or RAW_STRING.match(source, i):
                i = self.read_string(i, out)
                continue
            word = WORD.match(source, i)
            if word:
                out.append(Token('word', word.group(), self.line_at(i)))
                i = word.end()
                continue
            i += 1
            if c.isspace():
                continue
            if inside_interpolation:
                depth += {'(': 1, ')': -1}.get(c, 0)
                if depth == 0:
                    return i
            out.append(Token('punct', c, self.line_at(i - 1)))
        return i

    def read_string(self, i, out):
        """`i` at the first `#` or `"`. Appends the literal; returns the index after it."""
        source, n, start, hashes = self.source, self.n, i, 0
        while source[i] == '#':
            hashes, i = hashes + 1, i + 1
        multiline = source.startswith('"""', i)
        quote = '"""' if multiline else '"'
        i += len(quote)
        close, escape = quote + '#' * hashes, '\\' + '#' * hashes
        text, interpolated = [], False
        while i < n and not source.startswith(close, i):
            if source.startswith(escape, i):
                i, interpolated = self.read_escape(i + len(escape), multiline, text, interpolated)
            elif not multiline and source[i] == '\n':
                break  # unterminated; the compiler reports it
            else:
                text.append(source[i])
                i += 1
        if source.startswith(close, i):
            i += len(close)
        value = ''.join(text)
        out.append(Token('str', dedent(value) if multiline else value, self.line_at(start), interpolated))
        return i

    def read_escape(self, j, multiline, text, interpolated):
        """`j` just after the escape delimiter. Returns (next index, interpolated)."""
        source = self.source
        c = source[j:j + 1]
        if c == '(':
            nested = []
            self.streams.append(nested)
            text.append('\\(…)')
            return self.scan(j + 1, nested, inside_interpolation=True), True
        if c == 'u' and source[j + 1:j + 2] == '{':
            end = source.find('}', j)
            try:
                text.append(chr(int(source[j + 2:end], 16)))
            except ValueError:
                text.append('�')
            return end + 1, interpolated
        continuation = re.match(r'[ \t]*\n', source[j:j + 64]) if multiline else None
        if continuation:
            # A line continuation joins the next line. Its indentation is
            # dropped whole, not just the closing delimiter's (a stated limit).
            j += continuation.end()
            while source[j:j + 1] in (' ', '\t'):
                j += 1
            return j, interpolated
        text.append(SIMPLE_ESCAPES.get(c, c))
        return j + 1, interpolated


def dedent(value):
    """A multi-line literal's content: from after the opening line to before
    the closing delimiter's line, with the closing indentation stripped."""
    lines = value.split('\n')
    indent = lines[-1] if lines[-1].strip() == '' else ''
    body = lines[1:-1] if len(lines) > 1 else lines
    return '\n'.join(line[len(indent):] if line.startswith(indent) else line for line in body)


def tokenize(source):
    return Tokenizer(source).tokens()


class Literal:
    __slots__ = ('text', 'built', 'at_event_label', 'line')

    def __init__(self, text, built, at_event_label, line):
        self.text, self.built, self.at_event_label, self.line = text, built, at_event_label, line


def is_punct(token, characters):
    return token is not None and token.kind == 'punct' and token.text in characters


def event_label_literals(tokens):
    """Indices of string tokens anywhere in the argument after an `event:`
    label, so parentheses and both arms of a ternary count."""
    marked = set()
    for index in range(len(tokens) - 1):
        if not (tokens[index].kind == 'word' and tokens[index].text == 'event' and is_punct(tokens[index + 1], ':')):
            continue
        if index and tokens[index - 1].kind == 'word' and tokens[index - 1].text in ('let', 'var'):
            continue  # a declaration `let event: String`, not an argument label
        depth, i = 0, index + 2
        while i < len(tokens):
            t = tokens[i]
            if is_punct(t, '([{'):
                depth += 1
            elif is_punct(t, ')]}'):
                depth -= 1
                if depth < 0:
                    break
            elif depth == 0 and is_punct(t, ',;'):
                break
            elif t.kind == 'str':
                marked.add(i)
            i += 1
    return marked


def literals(tokens):
    """String tokens with their context judged: a `+` either side, past any
    parentheses, builds a name; one in an `event:` argument is labelled."""
    found, labelled = [], event_label_literals(tokens)
    for index, token in enumerate(tokens):
        if token.kind != 'str':
            continue
        before, after = index - 1, index + 1
        while before >= 0 and is_punct(tokens[before], '('):
            before -= 1
        while after < len(tokens) and is_punct(tokens[after], ')'):
            after += 1
        plus = (before >= 0 and is_punct(tokens[before], '+')) or (after < len(tokens) and is_punct(tokens[after], '+'))
        found.append(Literal(token.text, token.interpolated or plus, index in labelled, token.line))
    return found + concatenations(tokens, labelled)


def at(tokens, index):
    return tokens[index] if 0 <= index < len(tokens) else None


def chain_continues(tokens, index):
    """Whether the plain string at `index` follows a plain string through a `+`."""
    before = index - 1
    while is_punct(at(tokens, before), '('):
        before -= 1
    if not is_punct(at(tokens, before), '+'):
        return False
    before -= 1
    while is_punct(at(tokens, before), ')'):
        before -= 1
    previous = at(tokens, before)
    return previous is not None and previous.kind == 'str' and not previous.interpolated


def chain_from(tokens, start):
    """The text a `+` chain of plain strings from `start` spells, the index of its
    last string, and whether the chain goes on into a piece that is not a plain string."""
    text, last = tokens[start].text, start
    while True:
        plus = last + 1
        while is_punct(at(tokens, plus), ')'):
            plus += 1
        if not is_punct(at(tokens, plus), '+'):
            return text, last, False
        piece = plus + 1
        while is_punct(at(tokens, piece), '('):
            piece += 1
        token = at(tokens, piece)
        if token is None or token.kind != 'str' or token.interpolated:
            return text, last, True
        text, last = text + token.text, piece


def concatenations(tokens, labelled):
    """Names split across `+` pieces, as the literal each spells. Plain pieces are folded,
    so `"lifecycle" + "." + "superseded"` is `lifecycle.superseded` however it is written,
    raw or escaped. A chain that goes on into a non-literal piece is folded as far as it
    goes and marked built, like an interpolation, so its concrete prefix is still checked."""
    found = []
    for index, token in enumerate(tokens):
        if token.kind != 'str' or token.interpolated or chain_continues(tokens, index):
            continue
        text, last, open_chain = chain_from(tokens, index)
        if last == index:
            continue  # one piece: literals() already judged it
        if open_chain:
            text += '\\(…)'
        found.append(Literal(text, open_chain, index in labelled, token.line))
    return found


def first_arguments(tokens, caller):
    """For each call `caller(`, not its declaration: (line, the plain string
    literals anywhere in its first argument, so both arms of a ternary count)."""
    calls = []
    for index, token in enumerate(tokens):
        if token.kind != 'word' or token.text != caller:
            continue
        if index and tokens[index - 1].kind == 'word' and tokens[index - 1].text == 'func':
            continue
        if index + 1 >= len(tokens) or tokens[index + 1].text != '(':
            continue
        depth, strings, i = 0, [], index + 1
        while i < len(tokens):
            t = tokens[i]
            if t.kind == 'punct' and t.text in '([{':
                depth += 1
            elif t.kind == 'punct' and t.text in ')]}':
                depth -= 1
                if depth == 0:
                    break
            elif t.kind == 'punct' and t.text == ',' and depth == 1:
                break
            elif t.kind == 'str' and not t.interpolated:
                strings.append(t.text)
            i += 1
        calls.append((token.line, strings))
    return calls


def catalogue(text):
    """(names, planned names, problems) from the catalogue tables' first column."""
    names, planned, problems = set(), set(), []
    section = text.split('\n## Event catalogue', 1)
    if len(section) != 2:
        return names, planned, ['docs/events.md has no "## Event catalogue" section']
    body = section[1].split('\n## ', 1)[0]
    for line in body.splitlines():
        row = line.strip()
        if not row.startswith('|') or re.match(r'^\|\s*:?-', row) or row.startswith('| Event |'):
            continue
        cell = re.split(r'(?<!\\)\|', row)[1]  # first column; `\|` is an escaped pipe
        for token in re.findall(r'`([^`]+)`', cell):
            if not (NAME.match(token) or token in UNDOTTED_EVENTS):
                problems.append(f'docs/events.md: `{token}` is not a full event name; write each name out in full')
                continue
            names.add(token)
            if '*(planned)*' in row:
                planned.add(token)
    return names, planned, problems


def is_event_literal(literal, families, seen_exceptions):
    text = literal.text
    if text in UNDOTTED_EVENTS:
        return literal.at_event_label
    if text in NOT_EVENTS:
        seen_exceptions.add(text)
        return False
    family = text.split('.', 1)[0]
    pattern = BUILT_NAME if literal.built else NAME
    return bool(pattern.match(text)) and (family in families or literal.at_event_label)


def check_built(entry, tokens, problems):
    """Names `entry` produces, read from the calls that feed its template."""
    produced = set()
    calls = first_arguments(tokens, entry.caller)
    if not calls:
        problems.append(f'{entry.file}: no {entry.caller}(…) call feeds "{entry.template}"; update BUILT_NAMES')
    for line, strings in calls:
        if not strings:
            problems.append(f'{entry.file}:{line}: {entry.caller}(…) is not given a string literal, '
                            f'so the names "{entry.template}" builds cannot be read')
        produced |= {entry.pattern.format(s) for s in strings}
    for name in sorted(produced - entry.names):
        problems.append(f'{entry.file}: `{name}` is built by "{entry.template}" but not listed in BUILT_NAMES')
    for name in sorted(entry.names - produced):
        problems.append(f'BUILT_NAMES: `{name}` is listed for "{entry.template}" but no call in {entry.file} builds it')
    return produced


def check(root):
    problems = []
    documented, planned, problems_in_docs = catalogue((root / 'docs' / 'events.md').read_text())
    problems += problems_in_docs
    families = FAMILIES | {name.split('.', 1)[0] for name in documented if '.' in name}
    templates = {(entry.file, entry.template): entry for entry in BUILT_NAMES}

    product, pm_sim = {}, {}
    built_seen, seen_exceptions = set(), set()
    for path in sorted((root / 'Sources').rglob('*.swift')):
        relative = path.relative_to(root).as_posix()
        source = path.read_text()
        tokens = tokenize(source)
        target = pm_sim if relative.startswith(PM_SIM) else product
        for literal in literals(tokens):
            where = f'{relative}:{literal.line}'
            if (literal.text.startswith(LIFECYCLE_NAMESPACE)
                    and not relative.startswith(TYPED_DIRECTORY) and relative != WIRE_TYPED_FILE):
                what = 'a typed name' if literal.text in TYPED_NAMES else 'in the closed lifecycle namespace'
                problems.append(f'{where}: `{literal.text}` is {what}; emit it through RuntimeEvent(payload:) '
                                'and match its typed value, not a literal (decision 0013)')
            if not is_event_literal(literal, families, seen_exceptions):
                continue
            if literal.built:
                entry = templates.get((relative, literal.text))
                if entry is not None:
                    if entry.expression not in source:
                        problems.append(f'{where}: "{entry.template}" is no longer built as '
                                        f'`{entry.expression}`; check the names it builds and update BUILT_NAMES')
                    elif entry.template not in built_seen:
                        built_seen.add(entry.template)
                        for name in check_built(entry, tokens, problems):
                            product.setdefault(name, f'{relative} (built)')
                    continue
                if target is pm_sim and literal.text in PM_SIM_FIXTURES:
                    seen_exceptions.add(literal.text)
                    continue
                problems.append(f'{where}: event name built at run time ("{literal.text}"); '
                                'list it and the names it produces in BUILT_NAMES')
                continue
            target.setdefault(literal.text, where)

    for entry in BUILT_NAMES:
        if entry.template not in built_seen:
            problems.append(f'BUILT_NAMES: "{entry.template}" no longer appears in {entry.file}; update the entry')

    for name, where in sorted(product.items()):
        if name not in documented:
            problems.append(f'{where}: `{name}` is emitted but not catalogued in docs/events.md')
    for name in sorted(documented - planned - set(product)):
        problems.append(f'docs/events.md: `{name}` is catalogued but no product source emits it; '
                        'remove it or mark it *(planned)*')
    for name, where in sorted(pm_sim.items()):
        if name in PM_SIM_FIXTURES:
            seen_exceptions.add(name)
        elif name not in documented:
            problems.append(f'{where}: pm-sim refers to `{name}`, which is not catalogued in docs/events.md')
    for text in sorted((NOT_EVENTS | PM_SIM_FIXTURES) - seen_exceptions):
        problems.append(f'"{text}" is listed in NOT_EVENTS or PM_SIM_FIXTURES but no source uses it; drop it')
    problems += typed_inventory_problems(root)
    return problems, product


def typed_inventory_problems(root):
    """The typed inventory matches LifecycleEventName, the wire spells the same names, and
    the kernel's legacy envelope still refuses the whole namespace."""
    problems = []
    inventory = root / TYPED_INVENTORY
    text = inventory.read_text() if inventory.exists() else ''
    block = re.search(r'enum LifecycleEventName\b[^{]*\{(.*?)\n\}', text, re.S)
    listed = set(re.findall(r'"(lifecycle\.[a-z_]+)"', block.group(1))) if block else set()
    if listed != TYPED_NAMES:
        problems.append(f'{TYPED_INVENTORY}: LifecycleEventName lists {sorted(listed)}, but the typed inventory '
                        f'pins {sorted(TYPED_NAMES)}; change both together')
    payload = root / PAYLOAD_INVENTORY
    payload_text = payload.read_text() if payload.exists() else ''
    if 'legacyLifecycleNames' in payload_text:
        problems.append(f'{PAYLOAD_INVENTORY}: legacyLifecycleNames reintroduces an untyped lifecycle exception; '
                        'the namespace is closed, so a lifecycle name gets a typed case')
    if 'name.hasPrefix(namespacePrefix)' not in payload_text:
        problems.append(f'{PAYLOAD_INVENTORY}: requiresTypedPayload no longer closes the lifecycle namespace')
    wire = root / WIRE_TYPED_FILE
    wire_text = wire.read_text() if wire.exists() else ''
    wire_names = set(re.findall(r'"(lifecycle\.[a-z_]+)"', wire_text))
    if wire_names != TYPED_NAMES:
        problems.append(f'{WIRE_TYPED_FILE}: the wire spells {sorted(wire_names)}, but the typed inventory '
                        f'pins {sorted(TYPED_NAMES)}; change both together')
    kernel = root / KERNEL_EVENT
    if not kernel.exists() or '!RuntimeEventPayload.requiresTypedPayload(event)' not in kernel.read_text():
        problems.append(f'{KERNEL_EVENT}: the legacy RuntimeEvent init no longer refuses the lifecycle namespace; '
                        'a typed name must be emitted through RuntimeEvent(payload:)')
    return problems


if __name__ == '__main__':
    root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent)
    problems, emitted = check(root)
    for problem in problems:
        print(f'FAIL: {problem}', file=sys.stderr)
    if problems:
        sys.exit(1)
    print(f'PASS: docs/events.md catalogues all {len(emitted)} event names in product sources, and nothing more')
