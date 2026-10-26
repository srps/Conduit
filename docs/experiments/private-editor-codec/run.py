#!/usr/bin/env python3
"""Release sizing and lifetime probe for the private editor reply codec (decision 0034); no app launch, no product change.

Build the Release products first:
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build -c release

The runner compiles Probe.swift together with the pure maximum fixture
(Tests/ConduitTests/Fixtures/PrivateEditorMaximumFixture.swift) against the Release ConduitShared object alone, with
`-package-name conduit`. ConduitShared has no package dependencies, so no NIO object or module map is involved, and no
product access is widened. Each mode runs in a fresh process and prints numeric NDJSON records only.

Evidence names files relative to the repository. Absolute paths in captured logs are replaced with placeholders.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import time

MODES = ['wide-shared', 'wide-distinct', 'repeat-distinct']
WIDE_MODES = ['wide-shared', 'wide-distinct']
FIXTURE = 'Tests/ConduitTests/Fixtures/PrivateEditorMaximumFixture.swift'
KEY_SOURCES = [
    'Sources/ConduitShared/PrivateConfiguration/PrivateConfigurationFrame.swift',
    'Sources/ConduitShared/PrivateConfiguration/PrivateConfigurationEncoder.swift',
    'Sources/ConduitShared/PrivateConfiguration/PrivateConfigurationDecoder.swift',
    'Sources/ConduitShared/PrivateConfiguration/PrivateJSONScanner.swift',
    'Sources/ConduitShared/PrivateConfiguration/PrivateEditorReply.swift',
    'Sources/ConduitShared/Grammar/JSONByteCursor.swift',
    'Sources/ConduitShared/SecretBytes.swift',
    FIXTURE,
]
# SwiftPM's `.build/release` link first, then the Swift Build product directory it points at.
PRODUCT_DIRS = ['.build/release', '.build/out/Products/Release']
COMPILE_TIMEOUT = 180
MODE_TIMEOUT = 100

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument('output', type=Path, help='a directory for the compile log, the NDJSON results and metadata.json')
args = parser.parse_args()

here = Path(__file__).resolve().parent
root = Path(__file__).resolve().parents[3]
probe_source = here / 'Probe.swift'
runner_source = Path(__file__).resolve()
fixture = root / FIXTURE
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def relative(path):
    return path.resolve().relative_to(root).as_posix()


def git(*arguments):
    return subprocess.run(['git', *arguments], cwd=root, capture_output=True, text=True, check=True).stdout


products = None
product_label = None
for candidate in PRODUCT_DIRS:
    directory = root / candidate
    if (directory / 'ConduitShared.o').is_file() and (directory / 'ConduitShared.swiftmodule').exists():
        products, product_label = directory.resolve(), candidate
        break
if products is None:
    parser.error('Missing Release ConduitShared.o and ConduitShared.swiftmodule; build the Release products first.')
for path in (probe_source, fixture):
    if not path.is_file():
        parser.error('Missing source: ' + relative(path))

env = os.environ.copy()
env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'

shared_sources = sorted((root / 'Sources/ConduitShared').rglob('*.swift'))
shared_digest = hashlib.sha256()
for path in shared_sources:
    shared_digest.update((relative(path) + '\0' + sha256(path) + '\n').encode())
object_path = products / 'ConduitShared.o'
object_mtime = object_path.stat().st_mtime
module_files = sorted(p for p in (products / 'ConduitShared.swiftmodule').rglob('*.swiftmodule') if p.is_file())
toolchain = subprocess.run(['xcrun', 'swiftc', '--version'], cwd=root, env=env, capture_output=True, text=True,
                           check=True)

metadata = dict(
    head=git('rev-parse', 'HEAD').strip(),
    productStatus=git('status', '--porcelain=v1', '--untracked-files=all', '--', 'Sources', 'Package.swift',
                      'Package.resolved', 'Tests/ConduitTests/Fixtures').splitlines(),
    toolchain=(toolchain.stdout + toolchain.stderr).strip(),
    os=dict(macOS=platform.mac_ver()[0], machine=platform.machine()),
    probe=dict(probe=dict(path=relative(probe_source), sha256=sha256(probe_source)),
               runner=dict(path=relative(runner_source), sha256=sha256(runner_source))),
    sources={name: sha256(root / name) for name in KEY_SOURCES},
    conduitSharedSourcesSha256=shared_digest.hexdigest(),
    conduitSharedSourceCount=len(shared_sources),
    releaseProducts=product_label,
    objectSha256=sha256(object_path),
    moduleSha256={p.name: sha256(p) for p in module_files},
    # A source edited after the object was built means the measurement may not describe that source.
    sourcesNewerThanObject=[relative(p) for p in shared_sources if p.stat().st_mtime > object_mtime],
    output=output.name,
)
# A restored file has a new mtime and the committed bytes; an edited one differs from HEAD.
metadata['sourcesNewerThanObjectDifferFromHead'] = [
    name for name in metadata['sourcesNewerThanObject']
    if subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--', name], cwd=root).returncode != 0
]
if metadata['sourcesNewerThanObject']:
    print('WARNING: ConduitShared sources are newer than the Release object: '
          + ', '.join(metadata['sourcesNewerThanObject']) + '; differing from HEAD: '
          + (', '.join(metadata['sourcesNewerThanObjectDifferFromHead']) or 'none'), flush=True)

with tempfile.TemporaryDirectory(prefix='conduit-editor-codec-') as scratch_name:
    scratch = Path(scratch_name)

    def sanitize(text):
        for path, label in [(scratch.resolve(), '<scratch>'), (scratch, '<scratch>'), (root, '<repo>'),
                            (Path.home(), '~')]:
            text = text.replace(str(path), label)
        return text

    metadata['toolchain'] = sanitize(metadata['toolchain'])
    executable = scratch / 'probe'
    command = ['xcrun', 'swiftc', '-O', '-parse-as-library', '-module-name', 'EditorCodecProbe',
               '-module-cache-path', str(scratch / 'modules'),
               '-target', platform.machine() + '-apple-macosx26.0', '-package-name', 'conduit',
               '-I', str(products), str(probe_source), str(fixture), str(object_path), '-o', str(executable)]
    metadata['compileCommand'] = [sanitize(part) for part in command]
    started = time.monotonic()
    compiled = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True, timeout=COMPILE_TIMEOUT)
    metadata['compileSeconds'] = round(time.monotonic() - started, 3)
    compile_log = sanitize(compiled.stdout + compiled.stderr)
    (output / 'compile.log').write_text(compile_log)
    if compiled.returncode:
        (output / 'metadata.json').write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')
        print(compile_log[-9000:])
        raise SystemExit('Probe compile failed; see compile.log.')

    problems = []
    modes = {}
    for mode in MODES:
        started = time.monotonic()
        result = subprocess.run([str(executable), mode], cwd=scratch, env=env, capture_output=True, text=True,
                                timeout=MODE_TIMEOUT)
        seconds = round(time.monotonic() - started, 3)
        (output / (mode + '.ndjson')).write_text(sanitize(result.stdout))
        if result.stderr:
            (output / (mode + '.stderr.log')).write_text(sanitize(result.stderr))
        records = []
        for line in result.stdout.splitlines():
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                problems.append(mode + ': a stdout line is not a JSON record')
        summary = next((r for r in records if r.get('record') == 'summary'), {})
        lifetime = next((r for r in records if r.get('record') == 'lifetime-summary'), {})
        frames = sorted({r['frameBytes'] for r in records if r.get('record') in ('transfer', 'size')})
        calls = sorted({r['consumeCalls'] for r in records if r.get('record') == 'transfer'})
        modes[mode] = dict(exit=result.returncode, seconds=seconds, log=mode + '.ndjson',
                           failedChecks=summary.get('failedChecks'), frameBytes=frames, consumeCalls=calls,
                           lifetimeEndPeakRSSBytes=lifetime.get('peakRSSBytes'),
                           lifetimeEndPhysicalFootprintPeakBytes=lifetime.get('physicalFootprintPeakBytes'))
        if result.returncode or summary.get('failedChecks') != 0:
            problems.append(mode + ': exit ' + str(result.returncode) + ', failed checks '
                            + str(summary.get('failedChecks')))
        print(json.dumps(dict(mode=mode, **modes[mode])), flush=True)

    # Shared and distinct texts have the same widths, so every mode must see one frame size and one reader call count.
    all_frames = {size for record in modes.values() for size in record['frameBytes']}
    all_calls = {count for record in modes.values() for count in record['consumeCalls']}
    metadata['crossChecks'] = dict(oneFrameSizeAcrossModes=len(all_frames) == 1,
                                   oneReaderCallCountAcrossModes=len(all_calls) == 1)
    for name, passed in metadata['crossChecks'].items():
        if not passed:
            problems.append('cross-check failed: ' + name)
    metadata['modes'] = modes
    metadata['problems'] = problems
    (output / 'metadata.json').write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')
    if problems:
        raise SystemExit('Probe problems: ' + '; '.join(problems))
    print('PASS: every mode exited 0 with zero failed checks; metadata.json written', flush=True)
