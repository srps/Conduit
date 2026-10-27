import hashlib,json,os,subprocess,tempfile,time
from pathlib import Path
import argparse
parser=argparse.ArgumentParser(description='Replay this recorded, bounded actual-client source-guard experiment.')
parser.add_argument('output',type=Path,help='new output directory')
parser.add_argument('--repo',type=Path,default=Path(__file__).resolve().parents[3])
args=parser.parse_args();root=args.repo.resolve();out=args.output.resolve()
recorded=json.loads((Path(__file__).parent/'authority-model-results.json').read_text())
for path,digest in recorded['source_sha256'].items():
 if hashlib.sha256((root/path).read_bytes()).hexdigest()!=digest:parser.error('Recorded source mismatch: '+path)
if hashlib.sha256((root/'Tests/ConduitTests/RuntimePrivateEditorAuthorityModelTests.swift').read_bytes()).hexdigest()!=recorded['tests_sha256']:parser.error('Recorded test mismatch')
if subprocess.check_output(['git','status','--porcelain','--','Sources','Tests'],cwd=root,text=True):parser.error('Product/test worktree must be clean')
out.mkdir(parents=True,exist_ok=False)
env=os.environ.copy();env['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
records=[]
mutants=[
('model-stale-baseline','Sources/ConduitRuntime/RuntimeConfigurationWorkflow.swift','expecting: frozen.expected, context: context(generation: generation, requestID: ticket.requestID), claim: claim','expecting: nil, context: context(generation: generation, requestID: ticket.requestID), claim: claim','testAllThreeStepTwoClientAuthorityHistories'),
('model-private-id-reuse','Sources/ConduitRuntime/RuntimeServiceCore.swift','if aliasTable.live(requestID, now: now) != nil { return .rejected(.requestReused) }','if false && aliasTable.live(requestID, now: now) != nil { return .rejected(.requestReused) }','testAllThreeStepTwoClientAuthorityHistories')]

def run(name,pattern):
 start=time.monotonic();log=out/(name+'.log')
 with log.open('w') as f:p=subprocess.run(['xcrun','swift','test','--filter',pattern],cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=300)
 raw=log.read_text(errors='replace')
 assertions=[line for line in raw.splitlines() if ': error:' in line and ('XCTAssert' in line or 'failed -' in line)]
 invalid=[marker for marker in ['emit-module command failed','compile command failed','exited with unexpected signal','fatal error:','program crashed:','assertion failed:'] if marker in raw.lower()]
 r={'name':name,'exit':p.returncode,'seconds':round(time.monotonic()-start,2),'assertions':assertions[:18],'invalid_markers':invalid,'summary':[x for x in raw.splitlines() if 'Executed ' in x and 'tests' in x][-1:]}
 records.append(r);(out/'partial-results.json').write_text(json.dumps(records,indent=2)+chr(10));print(json.dumps(r),flush=True);return r
assert run('baseline','RuntimePrivateEditorAuthorityModelTests')['exit']==0
originals={}
for name,path,old,new,test in mutants:
 source=root/path;original=source.read_bytes();originals[path]=hashlib.sha256(original).hexdigest()
 assert original.count(old.encode())==1,(name,original.count(old.encode()))
 modified=original.replace(old.encode(),new.encode())
 try:
  source.write_bytes(modified);r=run(name,'RuntimePrivateEditorAuthorityModelTests.'+test)
 finally:
  assert source.read_bytes()==modified,'source changed while mutation active'
  source.write_bytes(original)
 r['caught_by_intended_assertion']=r['exit']==1 and bool(r['assertions']) and not r['invalid_markers']
 assert r['caught_by_intended_assertion'],name+' did not fail cleanly at intended assertions'
assert run('restored','RuntimePrivateEditorAuthorityModelTests')['exit']==0
summary={'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'source_sha256':originals,'tests_sha256':hashlib.sha256((root/'Tests/ConduitTests/RuntimePrivateEditorAuthorityModelTests.swift').read_bytes()).hexdigest(),'restored_exactly':all(hashlib.sha256((root/k).read_bytes()).hexdigest()==v for k,v in originals.items()),'checks':records}
(out/'results.json').write_text(json.dumps(summary,indent=2)+chr(10));print(str(out),flush=True)
