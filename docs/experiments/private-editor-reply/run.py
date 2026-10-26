#!/usr/bin/env python3
"""macOS/Xcode-layout reproduction of the private editor reply sizing probe; no app launch, no product change.

Build the release products first (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build -c release`).
The probe links the existing release objects with `-package-name conduit`, so it widens no product access.
Each mode runs in a fresh process and prints numeric NDJSON records only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

BASE_COMMIT = '7e7dccca3d32f28a0d593d5b2ccd4b4d0161d967'
MODES = ['small', 'string-maximum', 'unique-maximum', 'repeat']
OBJECTS = [
    'CNIOOpenBSD.o', 'RuntimeEvents.o', 'CNIOLinux.o', 'InternalCollectionsUtilities.o', 'CNIOFreeBSD.o',
    '_AtomicsShims.o', 'CNIOAtomics.o', 'CNIOLLHTTP.o', '_NIODataStructures.o', 'CNIOWindows.o', 'Atomics.o',
    'NIOConcurrencyHelpers.o', 'ProxyKernel.o', 'CNIOPosix.o', 'NIOCore.o', 'DequeModule.o', 'CNIODarwin.o',
    'NIOEmbedded.o', 'NIO.o', 'ConduitShared.o', 'NIOPosix.o', 'ContainersPreview.o', 'CNIOWASI.o',
    'NIOHTTP1.o', '_NIOBase64.o', 'ProxyControlBridge.o',
]

parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path, help='a new directory for the compile log and the NDJSON results')
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[3],
                    help='checkout with the historical product sources at ' + BASE_COMMIT)
args = parser.parse_args()
root = args.repo.resolve()
comparison = subprocess.run(['git', 'diff', '--quiet', BASE_COMMIT, '--', 'Sources', 'Package.swift', 'Package.resolved'],
                            cwd=root, check=False)
if comparison.returncode != 0:
    parser.error('This historical probe needs the product sources at ' + BASE_COMMIT
                 + '; use --repo with that checkout and build its Release products first.')
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

with tempfile.TemporaryDirectory(prefix='conduit-private-editor-') as scratch_name:
    scratch = Path(scratch_name)
    executable = scratch / 'probe'
    command = ['xcrun', 'swiftc', '-O', '-module-cache-path', str(scratch / 'modules'),
               '-target', platform.machine() + '-apple-macosx26.0', '-package-name', 'conduit',
               '-I', str(products), str(source)]
    command += [str(products / name) for name in OBJECTS]
    command += ['-o', str(executable)]
    for path in maps:
        command += ['-Xcc', '-fmodule-map-file=' + str(path)]
    with (output / 'compile.log').open('w') as log:
        subprocess.run(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
    checks = []
    for mode in MODES:
        with (output / (mode + '.ndjson')).open('w') as log:
            result = subprocess.run([str(executable), mode], cwd=scratch, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=300)
        checks.append(dict(kind=mode, exit=result.returncode, log=mode + '.ndjson'))
        print(json.dumps(checks[-1]), flush=True)
    metadata = dict(productCommit=BASE_COMMIT, probe_sha256=hashlib.sha256(source.read_bytes()).hexdigest(), checks=checks, replyCodecMeasured=False)
    (output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    if any(check['exit'] for check in checks):
        raise SystemExit('A mode failed or was inconclusive (exit 3); inspect its NDJSON summary record.')
