import hashlib,json,os,re,subprocess,time
from pathlib import Path
root=Path(__file__).resolve().parents[3]
import sys
assert len(sys.argv)==2,'usage: python3 replay.py /absolute/new-output-directory'
out=Path(sys.argv[1]);assert out.is_absolute()
out.mkdir(exist_ok=False)
env=os.environ.copy();env['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
target=root/'Sources/ConduitRuntime/RuntimePrivateEditor.swift'
original=target.read_bytes()
needle=b'prior: reportsPrior ? admitted.facts.prior : nil, unsaved: unsaved'
record=json.loads(Path(__file__).with_name('results.json').read_text())
assert hashlib.sha256(original).hexdigest()==record['original_sha256'],'target source differs from recorded experiment'
for name,expected in record['sourceTrees'].items():
 actual=subprocess.check_output(['git','rev-parse','HEAD:'+name],cwd=root,text=True).strip()
 assert actual==expected,'recorded source basis differs: '+name
assert not subprocess.check_output(['git','status','--porcelain','--','Sources','Tests','scripts','Package.swift','Package.resolved'],cwd=root),'source must be clean'
assert original.count(needle)==1
mutant=original.replace(needle,b'prior: nil, unsaved: unsaved')
sha=lambda b:hashlib.sha256(b).hexdigest()
summary={'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
'target':str(target.relative_to(root)),'original_sha256':sha(original),'mutant_sha256':sha(mutant),
'model':'RuntimePrivateEditorAuthorityModelTests/testAllThreeStepHistoriesWithTheMenusSavedStartAndItsOwnSave','runs':[]}
def run(label):
 start=time.monotonic()
 with (out/(label+'.log')).open('w') as f:
  try:p=subprocess.run(['xcrun','swift','test','--filter',summary['model']],cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT,text=True,timeout=300);code=p.returncode
  except subprocess.TimeoutExpired:code=124
 text=(out/(label+'.log')).read_text()
 r={'label':label,'exit':code,'seconds':round(time.monotonic()-start,3),
    'assertions':len(re.findall(r'XCT(?:Assert\w*|Unwrap) failed',text)),
    'fatal_or_crash':bool(re.search(r'Fatal error|Program crashed|error: emit-module|error: fatalError|compilation failed',text))}
 summary['runs'].append(r);(out/'results.json').write_text(json.dumps(summary,indent=2))
 print(json.dumps(r),flush=True)
 return r
baseline=run('baseline')
assert baseline['exit']==0 and 'histories=125' in (out/'baseline.log').read_text(),'the full125-history baseline must pass before mutation'
target.write_bytes(mutant)
try:
 killed=run('missing-start-prior')
finally:
 assert target.read_bytes()==mutant,'source changed externally; refusing to overwrite it'
 target.write_bytes(original)
 summary['byte_restored']=target.read_bytes()==original
 (out/'results.json').write_text(json.dumps(summary,indent=2))
restored=run('restored')
assert killed['exit'] not in (0,124) and killed['assertions']>0 and not killed['fatal_or_crash'],'requires an intended assertion failure, not build/crash/timeout'
assert restored['exit']==0 and summary['byte_restored'] and 'histories=125' in (out/'restored.log').read_text()
summary['passed']=True;(out/'results.json').write_text(json.dumps(summary,indent=2))
print(json.dumps({'passed':True,'results':str(out/'results.json')}),flush=True)
