import hashlib,json,os,subprocess,sys,tempfile,time
from pathlib import Path
root=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path.cwd()
out=Path(tempfile.mkdtemp(prefix='kernel-physical-mutants-',dir='/tmp'))
env=os.environ.copy();env['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
records=[]
mutants=[
 ('stale-effect-claim','Sources/ProxyKernel/Proxy/PhysicalLifecycle.swift','        guard isCurrent(epoch) else { return false }','        // Mutation: claim stale work.','PhysicalLifecycleTests.testAnEffectSupersededBeforeItsClaimRunsNothing'),
 ('stale-dns-publication','Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift','                guard self.dnsLifecycle.isCurrent(epoch) else { return }','                // Mutation: publish a superseded bind.','RuntimePhysicalOrderingTests.testDNSStopAdmittedDuringTheBindClosesItAndPublishesStopped'),
 ('repeated-tunnel-start','Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift','        guard ![.starting, .running, .warning].contains(state) || !tunnelLifecycle.admitsRunning else { return }','        // Mutation: rebind already running tunnel listeners.','RuntimePhysicalOrderingTests.testATunnelStartLeavesTheSharedPoolAloneAndARepeatedStartKeepsListenerAndSessions')]
mutants.append(('stale-bind-cleanup','Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift','                if self.dnsForwarder.listeningPort != nil {\n                    await self.closeDNSListeners()\n                }','                // Mutation: leave the superseded DNS bind open.','RuntimePhysicalOrderingTests.testANewerStartClosesTheBindOfTheStartItSuperseded'))
mutants.extend([('dns-edit-during-stop','Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift','if diff.dnsChanged && snapshot.dnsRunState == .running && dnsLifecycle.admitsRunning {','if diff.dnsChanged && snapshot.dnsRunState == .running {','RuntimePhysicalOrderingTests.testADNSEditDuringAStopsHeldTeardownNeitherRestartsNorBinds'),('tunnel-edit-during-stop','Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift','            && tunnelLifecycle.admitsRunning {','            {','RuntimePhysicalOrderingTests.testATunnelEditDuringAStopsHeldTeardownNeitherReconcilesNorBinds')])
def run(name,filter):
 start=time.monotonic();log=out/(name+'.log')
 with log.open('w') as f:
  p=subprocess.run(['xcrun','swift','test','--filter',filter],cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=240)
 text=log.read_text();assertions=[line for line in text.splitlines() if 'error:' in line and ('XCTAssert' in line or 'failed -' in line)]
 invalid_markers=[v for v in ['emit-module command failed','compile command failed','exited with unexpected signal','fatal error:','program crashed:','assertion failed:'] if v in text.lower()]
 result={'invalid_markers':invalid_markers,'name':name,'exit':p.returncode,'seconds':round(time.monotonic()-start,2),'assertions':assertions[:16]};records.append(result);(out/'partial-results.json').write_text(json.dumps(records,indent=2));print(json.dumps(result),flush=True)
 return result
assert run('baseline','PhysicalLifecycleTests|RuntimePhysicalOrderingTests')['exit']==0
originals={}
for name,path,old,new,filter in mutants:
 source=root/path;original=source.read_bytes();originals[path]=hashlib.sha256(original).hexdigest()
 assert original.count(old.encode())==1,(name,'needle')
 modified=original.replace(old.encode(),new.encode())
 try:
  source.write_bytes(modified);result=run(name,filter)
 finally:
  assert source.read_bytes()==modified,'source changed during mutation'
  source.write_bytes(original)
 assert result['exit']==1 and result['assertions'] and not result['invalid_markers'],name+' did not fail an intended assertion'
assert run('restored','PhysicalLifecycleTests|RuntimePhysicalOrderingTests')['exit']==0
summary={'source_sha256':originals,'restored_exactly':all(hashlib.sha256((root/k).read_bytes()).hexdigest()==v for k,v in originals.items()),'checks':records}
(out/'results.json').write_text(json.dumps(summary,indent=2)+'\n');print(str(out),flush=True)
