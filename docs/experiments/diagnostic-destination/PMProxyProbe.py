import http.server,json,signal,socket,subprocess,tempfile,threading,time,sys
from pathlib import Path
binary=Path(sys.argv[1]).resolve()
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200);self.send_header("Content-Length","2");self.end_headers();self.wfile.write(b"ok")
 def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(("127.0.0.1",0),Handler)
thread=threading.Thread(target=server.serve_forever);thread.start()
try:
 with tempfile.TemporaryDirectory(prefix="c-audit-",dir="/private/tmp") as temporary:
  root=Path(temporary);config=root/"config.json";out=root/"out.ndjson"
  original=json.dumps({"schemaVersion":2,"localHost":"127.0.0.1","localPort":0,"upstreams":[],"localPACEnabled":False,"dnsForwarderEnabled":False,"socksEnabled":False,"tunnelDefinitions":[],"verboseLogging":True,"auditLogEnabled":True,"auditLogPath":str(config)}).encode()
  config.write_bytes(original)
  def wait(predicate,why):
   end=time.monotonic()+10
   while time.monotonic()<end:
    if predicate():return
    if process.poll() is not None:raise AssertionError("proxy exited while waiting for "+why)
    time.sleep(.025)
   raise AssertionError("timeout "+why)
  with out.open("w") as stdout,(root/"err.log").open("w") as stderr:
   process=subprocess.Popen([str(binary),"--state-dir",str(root),"--port","0","--status-interval","0.1"],stdout=stdout,stderr=stderr)
   try:
    ready=root/"ready.json";wait(ready.exists,"readiness")
    port=json.loads(ready.read_text())["proxyPort"]
    for _ in range(2):
     with socket.create_connection(("127.0.0.1",port),timeout=5) as client:
      upstream=server.server_port
      client.sendall((f"GET http://127.0.0.1:{upstream}/fixture HTTP/1.1\r\nHost: 127.0.0.1:{upstream}\r\nConnection: close\r\n\r\n").encode())
      chunks=[]
      while True:
       piece=client.recv(65536)
       if not piece:break
       chunks.append(piece)
       assembled=b"".join(chunks)
       assert len(assembled)<65536,"fixture response exceeded bound"
       if b"\r\n\r\n" in assembled and assembled.split(b"\r\n\r\n",1)[1].endswith(b"ok"):break
      response=b"".join(chunks)
      assert b"200 OK" in response and response.endswith(b"ok"),"owned request failed"
    def events():
     p=root/"events.ndjson"
     if not p.exists():return []
     return [json.loads(l) for l in p.read_text().splitlines() if l]
    wait(lambda:any(e.get("event")=="config.diagnostic_destination_refused" for e in events()),"audit refusal event")
    assert config.read_bytes()==original,"audit modified authoritative config"
    refusal=[e for e in events() if e.get("event")=="config.diagnostic_destination_refused"]
    assert len(refusal)==1 and "resource=config" in refusal[0]["detail"],"refusal is missing or not latched"
    process.send_signal(signal.SIGTERM);assert process.wait(timeout=8)==0,"graceful stop failed"
    assert config.read_bytes()==original,"shutdown modified authoritative config"
    print("PASS: actual pm-proxy composition refuses audit-on-config, emits one refusal, serves two owned HTTP requests and stops normally; config bytes unchanged")
   except Exception:
    print("fixture stderr tail:", (root/"err.log").read_text()[-2000:])
    raise
   finally:
    if process.poll() is None:process.kill();process.wait(timeout=5)
finally:
 server.shutdown();server.server_close();thread.join(timeout=5);assert not thread.is_alive()
