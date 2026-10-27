#!/usr/bin/env python3
"""Force an owned audit-file read failure; assert scenario FAIL, then restore and pass."""
import argparse,hashlib,json,os,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();root=a.root.resolve();out=a.output.resolve();out.mkdir(exist_ok=False)
src=root/'Sources/pm-sim/RuntimeHostEffectsScenarios.swift';original=src.read_bytes();needle=b'let text = try String(contentsOf: auditFile, encoding: .utf8)';replacement=b'let text = try String(contentsOf: auditFile.appendingPathComponent("forced-read-failure"), encoding: .utf8)';assert original.count(needle)==1
subprocess.run(['git','diff','--exit-code','--','Sources','Tests','scripts'],cwd=root,check=True,stdout=subprocess.DEVNULL)
env=os.environ.copy();env['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer';command=['xcrun','swift','run','pm-sim','runtime-host-effects'];records=[]
def run(name,forced):
 t=time.monotonic();f=out/(name+'.log')
 with f.open('w') as log:r=subprocess.run(command,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=180)
 rows=[json.loads(l[len('SIM_NDJSON '):]) for l in f.read_text().splitlines() if l.startswith('SIM_NDJSON ')]
 assert len(rows)==1 and rows[0]['scenario']=='runtime-host-effects','no executed scenario record (compile/crash/timeout excluded)'
 d=rows[0];failed=[x['name'] for x in d['assertions'] if not x['passed']];cleaned=any(x['name']=='the audit error path settled the host and confirmed its flush' and x['passed'] for x in d['assertions'])
 if forced:assert r.returncode!=0 and not d['passed'] and failed==['the audit exercise completed without error'] and cleaned,'did not fail the intended audit evidence assertion with successful cleanup'
 else:assert r.returncode==0 and d['passed'] and not failed,'restored scenario failed'
 rec={'name':name,'exit':r.returncode,'seconds':round(time.monotonic()-t,3),'assertions':len(d['assertions']),'failed':failed,'error_path_cleanup_confirmed':cleaned};records.append(rec);print(json.dumps(rec),flush=True)
try:
 src.write_bytes(original.replace(needle,replacement));run('forced-audit-read-error',True)
finally:
 src.write_bytes(original);assert src.read_bytes()==original
run('restored',False)
subprocess.run(['git','diff','--exit-code','--','Sources','Tests','scripts'],cwd=root,check=True,stdout=subprocess.DEVNULL)
d={'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'source':str(src.relative_to(root)),'original_sha256':hashlib.sha256(original).hexdigest(),'restored_exact':True,'command':command,'records':records,'scope':'One forced audit-file read error; eight unexpected-error catches reviewed separately.'};(out/'results.json').write_text(json.dumps(d,indent=2)+'\n')
