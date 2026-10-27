#!/usr/bin/env python3
"""Actual Conduit client/host resource probe runner: macOS/Xcode layout, no app launch, no product change.

Build the Release products first (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build -c release`).
The probe links the existing Release objects with `-package-name conduit` (the link structure of the private-editor-reply
runner plus ConduitRuntime, PlatformMac, ProxyAuth and ProxyPAC), so it widens no product access and adds no product,
dependency or test hook. Each mode runs in a fresh process under its own owned scratch root, with a bounded deadline and a
bounded output, and prints numeric NDJSON only. The runner refuses any string value that is not a short fixed label.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import time

MODES = ['lifetime-open', 'lifetime-composed', 'lifetime-read', 'lifetime-save', 'lifetime-start', 'small',
         'realistic-valid-64', 'realistic-valid-128', 'validator-widest', 'escape-maximum', 'padded-8mib', 'repeat',
         'contention', 'contention-encode', 'contention-store', 'contention-encode-nosampler', 'contention-store-nosampler',
         'held', 'cancel', 'codec-bounds']
# Fresh-process trials per mode; the live-A contention modes run several so a single outlier is visible as one.
TRIALS = {'contention-encode': 3, 'contention-store': 3, 'contention-encode-nosampler': 3, 'contention-store-nosampler': 3}
MODE_TIMEOUT_SECONDS = 300
MAX_OUTPUT_BYTES = 4 * 1024 * 1024
OBJECTS = [
    'CNIOOpenBSD.o', 'RuntimeEvents.o', 'CNIOLinux.o', 'InternalCollectionsUtilities.o', 'CNIOFreeBSD.o',
    '_AtomicsShims.o', 'CNIOAtomics.o', 'CNIOLLHTTP.o', '_NIODataStructures.o', 'CNIOWindows.o', 'Atomics.o',
    'NIOConcurrencyHelpers.o', 'ProxyKernel.o', 'CNIOPosix.o', 'NIOCore.o', 'DequeModule.o', 'CNIODarwin.o',
    'NIOEmbedded.o', 'NIO.o', 'ConduitShared.o', 'NIOPosix.o', 'ContainersPreview.o', 'CNIOWASI.o',
    'NIOHTTP1.o', '_NIOBase64.o', 'ProxyControlBridge.o',
    'ConduitRuntime.o', 'PlatformMac.o', 'ProxyAuth.o', 'ProxyPAC.o',
]
LABEL = re.compile(r'^[A-Za-z0-9_.:;=, ()\-]{0,120}$')

parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path, help='a new directory for the compile log, NDJSON results and metadata')
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[3],
                    help='checkout whose Release products are linked')
parser.add_argument('--modes', nargs='*', default=MODES, choices=MODES)
args = parser.parse_args()
root = args.repo.resolve()
source = Path(__file__).resolve().parent / 'Probe.swift'
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
products = (root / '.build/release').resolve()
for name in OBJECTS:
    if not (products / name).is_file():
        parser.error('Missing release object: ' + name + '; build the release products first.')
module_maps = root / '.build/out/Intermediates.noindex/GeneratedModuleMaps'
maps = sorted(module_maps.glob('CNIO*.modulemap')) + [module_maps / 'ContainersPreview.modulemap']
maps += [root / '.build/checkouts/swift-atomics/Sources/_AtomicsShims/include/module.modulemap',
         root / '.build/checkouts/swift-nio/Sources/CNIOWindows/include/module.modulemap']
for path in maps:
    if not path.is_file():
        parser.error('Missing dependency module map: ' + str(path))
env = os.environ.copy()
env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'


def git(*arguments):
    result = subprocess.run(['git', *arguments], cwd=root, capture_output=True, text=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


PRODUCT_PATHS = ['Sources', 'Package.swift', 'Package.resolved']


def provenance():
    """HEAD, a dirty flag and one fingerprint of the product sources as the working tree holds them: the index's blob ids,
    the working-tree diff against HEAD, and the content of every untracked source file."""
    digest = hashlib.sha256()
    for arguments in (['ls-files', '-s', '--', *PRODUCT_PATHS], ['diff', 'HEAD', '--binary', '--', *PRODUCT_PATHS]):
        digest.update((git(*arguments) or '<git failed>').encode())
    untracked = (git('ls-files', '--others', '--exclude-standard', '--', *PRODUCT_PATHS) or '').splitlines()
    for name in sorted(untracked):
        digest.update(name.encode())
        digest.update(sha256(root / name).encode())
    experiment = Path(__file__).resolve().parent
    return dict(head=git('rev-parse', 'HEAD'), productSourcesDirty=bool(git('status', '--porcelain', '--', *PRODUCT_PATHS)),
                productSourceFingerprint=digest.hexdigest(), untrackedProductFiles=len(untracked),
                experimentFiles={path.name: sha256(path) for path in sorted(experiment.iterdir()) if path.is_file()})


def string_values(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from string_values(item)
    elif isinstance(value, list):
        for item in value:
            yield from string_values(item)


def audit(log):
    """Every line is one JSON object whose strings are short fixed labels."""
    records, violations = 0, 0
    for line in log.read_text(errors='replace').splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            violations += 1
            continue
        records += 1
        if not isinstance(record, dict) or any(not LABEL.match(text) for text in string_values(record)):
            violations += 1
    return records, violations


before = provenance()
objects_at_start = {name: dict(sha256=sha256(products / name), mtime=(products / name).stat().st_mtime) for name in OBJECTS}

with tempfile.TemporaryDirectory(prefix='conduit-actual-client-') as scratch_name:
    scratch = Path(scratch_name)
    executable = scratch / 'probe'
    command = ['xcrun', 'swiftc', '-O', '-parse-as-library', '-module-cache-path', str(scratch / 'modules'),
               '-target', platform.machine() + '-apple-macosx26.0', '-package-name', 'conduit',
               '-I', str(products), str(source)]
    command += [str(products / name) for name in OBJECTS]
    command += ['-o', str(executable)]
    for path in maps:
        command += ['-Xcc', '-fmodule-map-file=' + str(path)]
    (output / 'link-command.json').write_text(json.dumps([str(part) for part in command], indent=2) + '\n')
    with (output / 'compile.log').open('w') as log:
        compiled = subprocess.run(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=600)
    if compiled.returncode != 0:
        print((output / 'compile.log').read_text()[-6000:])
        raise SystemExit('The probe did not compile; see compile.log.')
    checks = []
    runs = [(mode, trial) for mode in args.modes for trial in range(1, TRIALS.get(mode, 1) + 1)]
    for mode, trial in runs:
        name = mode if TRIALS.get(mode, 1) == 1 else mode + '-t' + str(trial)
        mode_scratch = output / 'scratch' / name
        mode_scratch.mkdir(parents=True, exist_ok=False)
        log_path = output / (name + '.ndjson')
        began = time.monotonic()
        with log_path.open('w') as log:
            try:
                result = subprocess.run([str(executable), mode, str(mode_scratch)], cwd=scratch, env=env, stdout=log,
                                        stderr=subprocess.STDOUT, timeout=MODE_TIMEOUT_SECONDS)
                exit_code = result.returncode
            except subprocess.TimeoutExpired:
                exit_code = 'timeout'
        size = log_path.stat().st_size
        if size > MAX_OUTPUT_BYTES:
            with log_path.open('r+b') as handle:
                handle.truncate(MAX_OUTPUT_BYTES)
        records, violations = audit(log_path)
        check = dict(kind=mode, trial=trial, exit=exit_code, seconds=round(time.monotonic() - began, 3), log=log_path.name,
                     outputBytes=size, outputTruncated=size > MAX_OUTPUT_BYTES, records=records,
                     labelViolations=violations, scratchRemoved=not mode_scratch.exists())
        checks.append(check)
        print(json.dumps(check), flush=True)
    after = provenance()
    objects_at_end = {name: sha256(products / name) for name in OBJECTS}
    metadata = dict(
        sourceCommit=before['head'], provenanceBefore=before, provenanceAfter=after,
        sourceUnchangedDuringRun=before == after,
        objectsUnchangedDuringRun=all(objects_at_start[name]['sha256'] == objects_at_end[name] for name in OBJECTS),
        probe_sha256=sha256(source), runner_sha256=sha256(Path(__file__).resolve()),
        swiftc=subprocess.run(['xcrun', 'swiftc', '--version'], env=env, capture_output=True, text=True).stdout.strip(),
        objects=objects_at_start,
        modeTimeoutSeconds=MODE_TIMEOUT_SECONDS, maxOutputBytes=MAX_OUTPUT_BYTES, checks=checks,
    )
    (output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    if not metadata['sourceUnchangedDuringRun'] or not metadata['objectsUnchangedDuringRun']:
        raise SystemExit('The product sources or linked objects changed during the run; the results are not one coherent build.')
    if any(check['exit'] != 0 or check['labelViolations'] or check['outputTruncated'] for check in checks):
        raise SystemExit('A mode failed, timed out, was inconclusive (exit 3) or printed a non-label string; see its NDJSON.')
