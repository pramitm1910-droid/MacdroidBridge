#!/usr/bin/env python3
"""Build and verify without sockets, devices, Finder or signing."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipapp
from unittest.mock import patch

HERE=Path(__file__).resolve().parent
OUT=Path(os.environ.get('MACDROID_VERIFY_OUT', str(HERE.parents[1]/'mtp-storage-investigation/webdav-prototype-01')))
OUT.mkdir(parents=True,exist_ok=True)
commands=[]

def run(args,log,expected=0):
    with (OUT/log).open('w') as f:
        result=subprocess.run(args,cwd=HERE,stdout=f,stderr=subprocess.STDOUT)
    commands.append({'argv':list(map(str,args)),'cwd':str(HERE),'log':log,'exit':result.returncode})
    (OUT/'commands.json').write_text(json.dumps(commands,indent=2))
    if result.returncode!=expected: raise RuntimeError(f'{log}: unexpected exit {result.returncode}')

run([sys.executable,'-m','unittest','discover','-s','tests','-v'],'tests.log')
run([sys.executable,'-m','compileall','-q','webdav.py','runner.py','oracle.py','receive.py'],'build.log')
with tempfile.TemporaryDirectory() as temporary:
    for name in ('webdav.py','runner.py'):shutil.copy2(HERE/name,Path(temporary)/name)
    zipapp.create_archive(temporary,OUT/'webdav-synthetic.pyz',interpreter=sys.executable,main='runner:main')
run([sys.executable,str(OUT/'webdav-synthetic.pyz')],'runner-default.log')

import webdav as w
class Sink:
    def __init__(self):self.data=bytearray();self.aborted=False
    def write(self,data):self.data.extend(data);return len(data)
    def flush(self):pass
    def abort(self):self.aborted=True

results={}
with patch('socket.socket',side_effect=AssertionError('No sockets permitted')):
    for label,method,path,headers,fault in [
        ('options','OPTIONS','/',{},None),
        ('propfind','PROPFIND','/Phone/',{'depth':'1'},None),
        ('head','HEAD','/Phone/integrity.bin',{},None),
        ('full','GET','/Phone/integrity.bin',{},None),
        ('range','GET','/Phone/integrity.bin',{'range':'bytes=65535-65537'},None),
        ('preheader','GET','/Phone/integrity.bin',{},0),
        ('truncated','GET','/Phone/integrity.bin',{},w.CHUNK)]:
        provider=w.SyntheticProvider();provider.fault_at=fault
        handler=w.Handler(provider,provider);sink=Sink()
        result=w.send(handler,handler.handle(w.Request(method,path,headers)),sink)
        (OUT/(label+'.http')).write_bytes(sink.data)
        results[label]={'status':result.status,'committed':result.committed,'sent':result.sent,
                        'server_complete':result.complete,'aborted':sink.aborted,'failure':result.failure}
    data=(b'OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\n\r\n'
          b'PROPFIND / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\nDepth: 1\r\nConnection: close\r\n\r\n')
    provider=w.SyntheticProvider();sink=Sink();events=[]
    w.serve_connection(w.Handler(provider,provider),io.BytesIO(data),sink,log=events.append)
    (OUT/'options-propfind-request.http').write_bytes(data)
    (OUT/'options-propfind-response.http').write_bytes(sink.data)
    (OUT/'synthetic-requests.jsonl').write_text(''.join(json.dumps(e)+'\n' for e in events))
wire=bytearray((OUT/'full.http').read_bytes());wire[-1]^=1
(OUT/'corrupt.http').write_bytes(wire)
for case,flags,client_exit,oracle_exit in [
    ('full',[],0,0),('truncated',[],2,1),('truncated',['--unchecked-chunks'],0,1),('corrupt',[],0,1)]:
    name=case+('-unchecked' if flags else '-strict')
    run([sys.executable,'receive.py',str(OUT/(case+'.http')),str(OUT/(name+'.bin'))]+flags,name+'-client.log',client_exit)
    run([sys.executable,'oracle.py',str(OUT/(name+'.bin'))],name+'-oracle.json',oracle_exit)
    results[name]={'client_exit':client_exit,'independent_oracle_exit':oracle_exit,
                   'verified':oracle_exit==0,'unresolved_client_integrity_failure':client_exit==0 and oracle_exit!=0}
(OUT/'results.json').write_text(json.dumps(results,indent=2))
import oracle
manifest={name:{'bytes':size,'sha256':hashlib.sha256(oracle.expected(size)).hexdigest()} for name,size in oracle.SIZES.items()}
(OUT/'fixture-oracles.json').write_text(json.dumps(manifest,indent=2))
files=list(HERE.glob('*.py'))+list((HERE/'tests').glob('*.py'))+[OUT/'webdav-synthetic.pyz']
(OUT/'source-hashes.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2))
print('PASS: offline tests, bytecode build, unsigned zipapp, independent client/oracle probes. No listener launched.')
