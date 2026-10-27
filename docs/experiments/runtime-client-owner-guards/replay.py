import hashlib,json,os,subprocess,tempfile,time
from pathlib import Path
import argparse
parser=argparse.ArgumentParser(description='Replay the three bounded real-client guard checks on their recorded sources.')
parser.add_argument('output',type=Path,help='new output directory')
parser.add_argument('--repo',type=Path,default=Path(__file__).resolve().parents[3])
args=parser.parse_args();root=args.repo.resolve();out=args.output.resolve()
recorded=json.loads((Path(__file__).parent/'results.json').read_text())
for path,key in [('Sources/ConduitRuntime/RuntimeHostControlOwner.swift','source_sha256'),('Tests/ConduitTests/RuntimeHostControlOwnerTests.swift','tests_sha256')]:
 if hashlib.sha256((root/path).read_bytes()).hexdigest()!=recorded[key]:parser.error('Recorded source mismatch: '+path)
if subprocess.check_output(['git','status','--porcelain','--','Sources','Tests'],cwd=root,text=True):parser.error('Product/test worktree must be clean')
out.mkdir(parents=True,exist_ok=False)
env=os.environ.copy();env['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
records=[]
mutants=[
 ('settlement-cites-old-snapshot','!presentation.reserveUnprojected()', 'false', 'RuntimeHostControlOwnerTests.testAStopCompletedWhileTheSnapshotFailsNamesTheRevisionTheRecoveredSnapshotTakes'),
 ('manufacture-companion-revision','dns: conditionalDNS?.rawValue, tunnels: nil)', 'dns: conditionalDNS.map { _ in workflow.revisions.dns }, tunnels: nil)', 'RuntimeHostControlOwnerTests.testARestartNamingTheObservedDNSRevisionStartsTheCompanionAndAMovedOneIsRefusedWhole'),
 ('abandon-dropped-stop-admission','dropAdmittedStop(replaced)', '_ = replaced', 'RuntimeHostControlOwnerTests.testAQueuedStopReplacedByANewerStopIsDroppedAndItsAdmissionReleased')]
source=root/'Sources/ConduitRuntime/RuntimeHostControlOwner.swift'
original=source.read_bytes();original_hash=hashlib.sha256(original).hexdigest()
def run(name,filter):
 start=time.monotonic();log=out/(name+'.log')
 with log.open('w') as f:
  proc=subprocess.run(['xcrun','swift','test','--filter',filter],cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=300)
 raw=log.read_text(errors='replace');lines=raw.splitlines()
 assertions=[x for x in lines if ': error:' in x and ('XCTAssert' in x or 'failed -' in x)]
 invalid=[v for v in ['emit-module command failed','compile command failed','exited with unexpected signal','fatal error:','program crashed:','assertion failed:'] if v in raw.lower()]
 result={'name':name,'exit':proc.returncode,'seconds':round(time.monotonic()-start,2),'assertions':assertions[:18],'invalid_markers':invalid,'summary':[x for x in lines if 'Executed ' in x and 'tests' in x][-1:]}
 records.append(result);(out/'partial-results.json').write_text(json.dumps(records,indent=2)+'\n');print(json.dumps(result),flush=True);return result
baseline='RuntimeHostControlOwnerTests'
assert run('baseline',baseline)['exit']==0
for name,old,new,filter in mutants:
 assert original.count(old.encode())==1,(name,original.count(old.encode()))
 modified=original.replace(old.encode(),new.encode())
 try:
  source.write_bytes(modified);r=run(name,filter)
 finally:
  assert source.read_bytes()==modified,'source changed during mutation'
  source.write_bytes(original)
 assert r['exit']==1 and r['assertions'] and not r['invalid_markers'],name+' lacks a clean intended assertion failure'
assert run('restored',baseline)['exit']==0
summary={'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'source_sha256':original_hash,'tests_sha256':hashlib.sha256((root/'Tests/ConduitTests/RuntimeHostControlOwnerTests.swift').read_bytes()).hexdigest(),'restored_exactly':source.read_bytes()==original,'checks':records}
(out/'results.json').write_text(json.dumps(summary,indent=2)+'\n');print(str(out),flush=True)
