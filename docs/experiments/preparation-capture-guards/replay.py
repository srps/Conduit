import argparse,hashlib,json,os,re,subprocess,tempfile
from pathlib import Path
parser=argparse.ArgumentParser(description='Replay the three guards on an isolated, clean capture checkpoint.')
parser.add_argument('source_root',type=Path)
args=parser.parse_args()
root=args.source_root.resolve()
assert not subprocess.check_output(['git','status','--porcelain'],cwd=root), 'Use a clean isolated checkout'
out=Path(tempfile.mkdtemp(prefix='preparation-capture-mutants-'))
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
store='Sources/ConduitRuntime/ConfigurationStore.swift'
intent='Sources/ConduitRuntime/RuntimeModuleIntent.swift'
workflow='Sources/ConduitRuntime/RuntimeConfigurationWorkflow.swift'
cases=[
 ('receipt-freshness',store,'&& records[receipt.component].version == receipt.version','&& true','ConfigurationCaptureModelTests','testBoundedCaptureHistoriesAgreeWithAnIndependentReference'),
 ('late-stop-after-quit',intent,'let persistsDNSStop = reason == .session && !terminal','let persistsDNSStop = reason == .session','RuntimeModuleIntentTests.testALateDNSStopAfterQuitCreatesAndDropsNoSave','testALateDNSStopAfterQuitCreatesAndDropsNoSave'),
 ('captured-write-claim',workflow,'return intent.withLockedValue { $0.holdsGroup(lifecycle) }','return true','ConfigurationWorkflowPhaseTests.testAStopAdmittedBeforeTheClaimRevokesTheWriteAndNothingApplies','testAStopAdmittedBeforeTheClaimRevokesTheWriteAndNothingApplies'),
]
original={path:(root/path).read_bytes() for path in (store,intent,workflow)}
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
assert head=='291267029bc0d09117fe03e77923cee9411db643'
for path,data in original.items():
 assert data==subprocess.check_output(['git','show','HEAD:'+path],cwd=root),path+' is not frozen'
 (out/(Path(path).name+'.before')).write_bytes(data)
def run(name,test):
 pth=out/(name+'.log')
 with pth.open('w') as f:
  p=subprocess.run(['xcrun','swift','test','--filter',test],cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=300)
 return p.returncode,pth.read_text(errors='replace')
records=[]
try:
 for name,path,before,after,test,witness in cases:
  source=original[path].decode();assert source.count(before)==1,(name,source.count(before))
  (root/path).write_text(source.replace(before,after))
  try:
   code,log=run(name,test)
   failed=bool(re.search(r'Test Case .*'+re.escape(witness)+r'.* failed',log))
   detected=code!=0 and failed and 'XCTAssert' in log and 'unexpected signal' not in log
   record=dict(name=name,exit=code,detectedByAssertion=detected,witness=witness,mutant_sha256=hashlib.sha256((root/path).read_bytes()).hexdigest())
   records.append(record);print(json.dumps(record),flush=True)
   assert detected,'Mutation did not fail the intended assertion without a crash: '+name
  finally:
   (root/path).write_bytes(original[path]);assert (root/path).read_bytes()==original[path]
 code,log=run('restored','ConfigurationCaptureModelTests|RuntimeModuleIntentTests|ConfigurationWorkflowPhaseTests|ConfigurationWorkflowModelTests')
 assert code==0,'Restored tests failed'
 assert all((root/path).read_bytes()==data for path,data in original.items())
 (out/'results.json').write_text(json.dumps(dict(head=head,mutations=records,restoredExit=code,restored_sha256={path:hashlib.sha256(data).hexdigest() for path,data in original.items()}),indent=2)+'\n')
 print('PASS; exact bytes restored; results '+str(out/'results.json'),flush=True)
finally:
 for path,data in original.items():(root/path).write_bytes(data)
