import argparse,hashlib,json,os,signal,subprocess,time
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--repo',type=Path,default=Path.cwd());parser.add_argument('--out',type=Path,required=True);args=parser.parse_args()
root=args.repo.resolve();out=args.out.resolve();out.mkdir(parents=True,exist_ok=False)
env=os.environ.copy();env['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
def git(*parts):return subprocess.check_output(['git',*parts],cwd=root,text=True).strip()
assert not git('status','--porcelain','--','Sources','Tests','scripts','Package.swift','Package.resolved'),'Product/test/script work must be clean'
methods=['testTheHostsTypedEventsReachTheActualStreamAndTheWriterRecordsEachOnce','testTheShutdownAloneWakesAParkedWaitAfterWhatWasPublished','testASubmitBudgetRefusalReturnsWhileTheStalledOwnerStillHoldsItsRound','testAnOpenBudgetRefusalReturnsWhileTheStalledOwnerStillHoldsItsRound']
cases=[('event-feed','Sources/ConduitRuntime/RuntimeHostControlOwner.swift','            service?.ingest(ControlRuntimeEvent(event))','            _ = service',methods[0]),('shutdown-wakeup','Sources/ConduitRuntime/RuntimeServiceCore.swift','        ingress.close()\n        wakeWaiters()','        ingress.close()',methods[1]),('deadline-provenance','Sources/ConduitRuntime/RuntimeInMemoryTransport.swift','            if gate.resolvedFromClaimedRound {','            if true {',methods[2]+'|'+methods[3])]
original={path:(root/path).read_bytes() for _,path,_,_,_ in cases}
record={'head':git('rev-parse','HEAD'),'sourceTree':git('rev-parse','HEAD:Sources'),'testTree':git('rev-parse','HEAD:Tests'),'driver_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'records':[]}
def persist(): (out/'results.json').write_text(json.dumps(record,indent=2)+'\n')
def run(name,selection,expected):
 cmd=['xcrun','swift','test','--filter',selection];start=time.monotonic();timed=False
 with (out/(name+'.log')).open('w') as log:
  p=subprocess.Popen(cmd,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  try:code=p.wait(timeout=120)
  except subprocess.TimeoutExpired:
   timed=True;os.killpg(p.pid,signal.SIGTERM)
   try:code=p.wait(timeout=5)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);code=p.wait()
 text=(out/(name+'.log')).read_text();intended=any(m in text for m in selection.split('|')) and 'XCTAssert' in text and 'failed' in text
 bad=any(s in text for s in ['error: emit-module','error: fatalError','Program crashed','unexpected signal','no matching test cases'])
 result={'name':name,'command':cmd,'exit':code,'seconds':round(time.monotonic()-start,3),'timeout':timed,'intendedAssertion':intended,'compileOrCrashFailure':bad,'log':name+'.log'};record['records'].append(result);persist();print(json.dumps(result),flush=True)
 assert not timed and not bad and code==expected,(name,'wrong failure mechanism')
 if expected:assert intended,(name,'no intended XCTest assertion')
try:
 run('baseline','|'.join(methods),0)
 for name,path,needle,replacement,selection in cases:
  p=root/path;source=original[path].decode();assert source.count(needle)==1,(name,'needle not unique')
  p.write_text(source.replace(needle,replacement,1))
  try:run(name,selection,1)
  finally:p.write_bytes(original[path])
 run('restored','|'.join(methods),0)
finally:
 for path,data in original.items():
  (root/path).write_bytes(data)
 record['exactBytesRestored']=all((root/path).read_bytes()==data for path,data in original.items());record['productCleanAfter']=not bool(git('status','--porcelain','--','Sources','Tests','scripts','Package.swift','Package.resolved'));persist()
assert record['exactBytesRestored'] and record['productCleanAfter']
print('PASS: all three source variants failed their intended assertions; exact restoration passed',flush=True)
