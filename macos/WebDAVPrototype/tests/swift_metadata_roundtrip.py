"""Launched only by XCTest: stdin/stdout are metadata envelopes, never sockets."""
import json
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from mtp_metadata import MTPMetadataProvider
from webdav import Handler, Request, send

def exchange(data):
    sys.stdout.buffer.write(data+b'\n'); sys.stdout.buffer.flush()
    reply=sys.stdin.buffer.readline(1024*1024+1)
    if not reply: raise EOFError()
    return reply

provider=MTPMetadataProvider(exchange)
handler=Handler(provider,None)
def prop(path,depth='1'):
    return handler.handle(Request('PROPFIND',path,{'depth':depth}))
assert prop('/').status==207
response=prop('/Internal/')
assert response.status==207, response.status
assert response.body.count(b'<D:response>')==46
assert b'duplicate [MTP-20002-2]' in response.body
assert '写真'.encode() in response.body
assert b'getcontentlength' not in response.body  # Unknown sizes remain unknown.
assert prop('/Internal/entry-1/').status==207
for method in ('GET','HEAD','PUT','DELETE','MOVE'):
    result=handler.handle(Request(method,'/Internal/entry-2'))
    assert result.status==(503 if method in ('GET','HEAD') else 403)
old=provider.root()
provider.refresh()
assert not provider.current(old)
assert prop('/').status==207
provider.invalidate()
assert prop('/').status==503
print('Swift MTPFolderBrowser -> metadata source -> JSON service -> Python WebDAV: PASS',file=sys.stderr)
