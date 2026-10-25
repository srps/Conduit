#!/usr/bin/env python3
"""macOS/Xcode-layout reproduction of final display experiments; no app launch."""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
source_dir = Path(__file__).resolve().parent
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
products = (root / '.build/release').resolve()
if not (products / 'ProxyControlBridge.o').is_file():
    parser.error('Build release ProxyControlBridge first; this harness expects the Xcode SwiftPM product layout.')
env = os.environ.copy()
env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
objects = ['CNIOOpenBSD.o', '_NIOBase64.o', 'RuntimeEvents.o', 'CNIOLinux.o', 'InternalCollectionsUtilities.o', 'CNIOFreeBSD.o', '_AtomicsShims.o', 'CNIOAtomics.o', 'CNIOLLHTTP.o', '_NIODataStructures.o', 'NIOHTTP1.o', 'CNIOWindows.o', 'Atomics.o', 'NIOConcurrencyHelpers.o', 'ProxyKernel.o', 'CNIOPosix.o', 'NIOCore.o', 'DequeModule.o', 'CNIODarwin.o', 'NIOEmbedded.o', 'NIO.o', 'ConduitShared.o', 'NIOPosix.o', 'ContainersPreview.o', 'CNIOWASI.o', 'ProxyControlBridge.o']
for name in objects:
    if not (products / name).is_file():
        parser.error('Missing release object: ' + name)
module_maps = root / '.build/out/Intermediates.noindex/GeneratedModuleMaps'
maps = sorted(module_maps.glob('CNIO*.modulemap')) + [module_maps / 'ContainersPreview.modulemap']
maps += [root / '.build/checkouts/swift-atomics/Sources/_AtomicsShims/include/module.modulemap',
         root / '.build/checkouts/swift-nio/Sources/CNIOWindows/include/module.modulemap']
for path in maps:
    if not path.is_file():
        parser.error('Missing dependency module map: ' + str(path))
with tempfile.TemporaryDirectory(prefix='conduit-display-') as scratch_name:
    scratch = Path(scratch_name)
    for source_name, cases in [
        ('ResourceProbe.swift', ['plain-short','redacted-short','plain-cap-over','nul-cap-over','sanitizer-input-limit','omitted-input','double-input-limit']),
        ('URLDenseProbe.swift', ['url-dense','userinfo-dense']),
    ]:
        executable = scratch / Path(source_name).stem
        command = ['xcrun','swiftc','-O','-module-cache-path',str(scratch / 'modules'),
                   '-target',platform.machine() + '-apple-macosx26.0','-package-name','conduit',
                   '-I',str(products),str(source_dir / source_name)]
        command += [str(products / name) for name in objects]
        command += ['-o',str(executable)]
        for path in maps:
            command += ['-Xcc','-fmodule-map-file=' + str(path)]
        with (output / (Path(source_name).stem + '-compile.log')).open('w') as log:
            subprocess.run(command,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=120)
        results = []
        for case in cases:
            result = subprocess.run([str(executable),case],cwd=root,env=env,text=True,capture_output=True,timeout=120)
            results.append(dict(kind=case,exit=result.returncode,stdout=result.stdout,stderr=result.stderr))
        (output / (Path(source_name).stem + '-results.json')).write_text(json.dumps(results,indent=2) + '\n')
        if any(result['exit'] for result in results):
            raise SystemExit('Probe failed; inspect saved results.')
        print(source_name + ': all synthetic cases passed')
