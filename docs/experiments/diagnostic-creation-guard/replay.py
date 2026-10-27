#!/usr/bin/env python3
"""Execute one bounded recheck-removal guard and restore exact source bytes."""
import argparse, hashlib, json, os, subprocess, time
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('--root',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args();root=args.root.resolve();out=args.output.resolve();out.mkdir(exist_ok=False)
source=root/'Sources/ProxyKernel/Support/SystemRecordFileDestinationGuard.swift'
original=source.read_bytes();before=hashlib.sha256(original).hexdigest()
needle=b'''                guard case .success(let base) = reads.resolve(existing.path) else {
                    throw RecordFileDestinationRefusal(reason: .inspectionFailed, resource: resource)
                }
                return Self.canonicalPath(resolved: base, missing: missing)'''
replacement=b'''                throw RecordFileDestinationRefusal(reason: .inspectionFailed, resource: resource)'''
assert original.count(needle)==1,'source no longer matches reviewed guard'
subprocess.run(['git','diff','--exit-code','--','Sources','Tests','scripts'],cwd=root,check=True,stdout=subprocess.DEVNULL)
env=os.environ.copy();env['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
command=['xcrun','swift','test','--filter','DiagnosticDestinationGuardTests.testProtectedFileCreatedBetweenTheTwoReadsResolvesOnTheRetry']
checks=[]
def run(name,mutated=False):
    start=time.monotonic();path=out/(name+'.log')
    with path.open('w') as f:
        r=subprocess.run(command,cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=240)
    log=path.read_text();lines=[l for l in log.splitlines() if 'XCTAssert' in l or 'Executed ' in l]
    record={'name':name,'exit':r.returncode,'seconds':round(time.monotonic()-start,3),'assertions':lines[-6:]}
    checks.append(record);print(json.dumps(record),flush=True)
    if mutated:
        assert r.returncode!=0 and 'XCTAssertNoThrow failed' in log,'mutant did not fail its intended effect assertion'
        assert 'error: emit-module' not in log and 'Signal ' not in log and 'Fatal error:' not in log,'non-assertion failure'
    else: assert r.returncode==0,'baseline/restored test failed'
try:
    run('baseline')
    source.write_bytes(original.replace(needle,replacement))
    mutant=hashlib.sha256(source.read_bytes()).hexdigest()
    run('recheck-removed',True)
finally:
    source.write_bytes(original)
    assert hashlib.sha256(source.read_bytes()).hexdigest()==before
run('restored')
subprocess.run(['git','diff','--exit-code','--','Sources','Tests','scripts'],cwd=root,check=True,stdout=subprocess.DEVNULL)
result={'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'source':str(source.relative_to(root)),'original_sha256':before,'mutant_sha256':mutant,'restored_exact':True,'checks':checks,'command':command,'scope':'One deterministic first-creation interleaving; no proof of every external filesystem race.'}
(out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('Guard complete; exact source restored.',flush=True)
