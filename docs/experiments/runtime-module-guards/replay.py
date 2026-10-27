import hashlib,json,os,subprocess,sys,tempfile,time
from pathlib import Path
root=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path.cwd()
out=Path(tempfile.mkdtemp(prefix='module-owner-mutants-',dir='/tmp'))
env=os.environ.copy();env['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
records=[]
mutants=[('stale-whole-request', 'Sources/ConduitRuntime/RuntimeModuleIntent.swift', 'if let expected = request.expectedRevisions[module], expected != modules[module].revision {', 'if let expected = request.expectedRevisions[module], false && expected != modules[module].revision {', 'RuntimeHostInteractiveTests.testAStaleRevisionRefusesTheWholeRequestBeforeAnyWrite'), ('borrow-pending-enable', 'Sources/ConduitRuntime/RuntimeModuleIntent.swift', ', start.group == group { return true }', ' { return true }', 'RuntimeModuleIntentTests.testAProxyRequestNeverStagesAnotherRequestsPendingDNSEnable|RuntimeHostInteractiveTests.testAProxyRequestPreparedBesideAPendingDNSStartPersistsNoEnable'), ('unfinished-grant-retirement', 'Sources/ConduitRuntime/RuntimeHostLifecycle.swift', '        workflow.endFailedStart(start.ticket)', '        // Mutation: retain the unfinished grants.', 'RuntimeHostInteractiveTests.testAStartThatThrowsAfterAuthorizationLeavesNoGrantForItsUnsettledMembers|RuntimeHostInteractiveTests.testAProxyStopWhileTheWholeHostStartAppliesHoldsItWhole'), ('conditional-pair-after-wait', 'Sources/ConduitRuntime/RuntimeHostLifecycle.swift', 'workflow.conditionalActivationAllowed(ticket) && workflow.holdsInput(prepared)', 'workflow.conditionalActivationAllowed(ticket)', 'RuntimeHostInteractiveTests.testAReloadThatReplacesThePairHoldsTheCompanionAndKeepsTheCompletedProxy'), ('stop-save-busy-event', 'Sources/ConduitRuntime/RuntimeConfigurationWorkflow.swift', 'return (.owed, [held(.stop, .runtime, .storeBusy)])', 'return (.owed, [])', 'RuntimeHostInteractiveTests.testABusyStoreHoldsTheOwedDisableWithItsTypedStopCauseAndKeepsTheFence'), ('owed-disable-fulfilment', 'Sources/ConduitRuntime/RuntimeModuleIntent.swift', '        if !enabled, case .stopSave(let revision) = modules.dns.pending, revision == ticket.dnsIntentRevision {\n            modules.dns.pending = nil\n        }', '        // Mutation: keep an already-verified disable owed.', 'RuntimeHostInteractiveTests.testAVerifiedSharedWriteOfTheOwedDisableEndsTheObligationAndKeepsTheFence'), ('stop-the-wrong-modules', 'Sources/ConduitRuntime/RuntimeModuleIntent.swift', 'for module in ControlModule.allCases where stopped.contains(module) {', 'for module in ControlModule.allCases {', 'RuntimeModuleLifecycleModelTests.testTunnelHistoriesStayIsolatedFromTheOtherModules')]

def run(name,filter):
 start=time.monotonic();log=out/(name+'.log')
 with log.open('w') as f:
  p=subprocess.run(['xcrun','swift','test','--filter',filter],cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=300)
 lines=log.read_text(errors='replace').splitlines();assertions=[x for x in lines if ': error:' in x and ('XCTAssert' in x or 'failed -' in x)]
 r={'name':name,'exit':p.returncode,'seconds':round(time.monotonic()-start,2),'assertion_count':len(assertions),'assertions':assertions[:18]};records.append(r);(out/'partial-results.json').write_text(json.dumps(records,indent=2));print(json.dumps(r),flush=True);return r
baseline='RuntimeModuleIntentTests|RuntimeHostInteractiveTests|RuntimeModuleLifecycleModelTests'
assert run('baseline',baseline)['exit']==0,'baseline failed before mutation'
originals={}
for name,path,old,new,filter in mutants:
 source=root/path;original=source.read_bytes();originals[path]=hashlib.sha256(original).hexdigest();assert original.count(old.encode())==1,(name,'needle',original.count(old.encode()))
 modified=original.replace(old.encode(),new.encode())
 try:
  source.write_bytes(modified);r=run(name,filter)
 finally:
  assert source.read_bytes()==modified,'source changed during mutation'
  source.write_bytes(original)
 assert r['exit']!=0 and r['assertion_count']>0,name+' did not fail an intended assertion'
assert run('restored',baseline)['exit']==0
summary={'source_sha256':originals,'restored_exactly':all(hashlib.sha256((root/k).read_bytes()).hexdigest()==v for k,v in originals.items()),'checks':records}
(out/'results.json').write_text(json.dumps(summary,indent=2)+'\n');print(str(out),flush=True)
