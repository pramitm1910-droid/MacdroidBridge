import io
import hashlib
import http.client
import unittest
from unittest.mock import patch
from dataclasses import replace
from xml.etree import ElementTree as ET
import webdav as w
import oracle
import receive

class Sink:
    def __init__(self, limit=None, on_write=None):
        self.data = bytearray(); self.aborted = False; self.limit = limit; self.on_write = on_write
        self.writes = []
    def write(self, data):
        if self.on_write: self.on_write(self, data)
        count = min(len(data), self.limit) if self.limit else len(data)
        self.data.extend(data[:count]); self.writes.append(count); return count
    def flush(self): pass
    def abort(self): self.aborted = True


class MemorySocket:
    """In-memory socket-shaped fixture; it never opens an OS socket."""
    def __init__(self, incoming=b'', error=None):
        self.incoming = bytearray(incoming); self.error = error
        self.outgoing = bytearray(); self.closed = False
    def recv(self, count):
        if self.incoming:
            data = bytes(self.incoming[:count]); del self.incoming[:count]
            return data
        if self.error: raise self.error
        return b''
    def send(self, data): self.outgoing.extend(data); return len(data)
    def shutdown(self, how): pass
    def settimeout(self, value): self.timeout=value
    def close(self): self.closed = True


class DAVTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import socket
        cls.real_socket=socket.socket
        cls.network = patch('socket.socket', side_effect=AssertionError('network socket forbidden in synthetic tests'))
        cls.network.start()
    @classmethod
    def tearDownClass(cls): cls.network.stop()
    def setUp(self):
        self.provider = w.SyntheticProvider(); self.handler = w.Handler(self.provider, self.provider)
    def request(self, method='GET', target='/Phone/integrity.bin', headers=None, body=b''):
        return w.Request(method, target, headers or {}, body)
    def deliver(self, request=None, sink=None, cancel=None):
        sink = sink or Sink(); response = self.handler.handle(request or self.request())
        result = w.send(self.handler, response, sink, cancel)
        return result, sink
    def parsed(self, sink, method='GET'):
        response = http.client.HTTPResponse(receive.CapturedSocket(bytes(sink.data)), method=method)
        response.begin(); return response
    def test_options_exact_framing_and_capabilities(self):
        for path in ('/', '*', '/Phone/', '/Phone/integrity.bin'):
            result, sink = self.deliver(self.request('OPTIONS', path))
            response = self.parsed(sink)
            self.assertEqual(response.status, 200); self.assertEqual(response.getheader('Content-Length'), '0')
            self.assertEqual(response.getheader('Allow'), w.ALLOW if path in ('*','/Phone/integrity.bin') else 'OPTIONS, PROPFIND')
            self.assertEqual(response.getheader('DAV'), '1')
            self.assertIsNone(response.getheader('Transfer-Encoding'))
            self.assertIsNone(response.getheader('MS-Author-Via'))
            self.assertEqual(response.read(), b''); self.assertTrue(result.complete)
    def test_options_then_propfind_same_connection(self):
        data = (b'OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\n\r\n'
                b'PROPFIND / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\nDepth: 1\r\nConnection: close\r\n\r\n')
        sink, logs = Sink(), []
        w.serve_connection(self.handler, io.BytesIO(data), sink, log=logs.append)
        self.assertEqual([e['status'] for e in logs if 'status' in e], [200,207])
        self.assertIn(b'HTTP/1.1 207 Multi-Status', sink.data); self.assertTrue(sink.aborted)
    def test_propfind_depth_zero_one_no_recursive_scan(self):
        for depth, count in [('0',1), ('1',7)]:
            self.provider.metadata_reads = 0
            result, sink = self.deliver(self.request('PROPFIND','/Phone/', {'depth':depth}))
            parsed = self.parsed(sink); body = parsed.read()
            self.assertEqual(parsed.status, 207)
            self.assertEqual(len(body), int(parsed.getheader('Content-Length')))
            root = ET.fromstring(body)
            self.assertEqual(len(root.findall(w.DAV+'response')), count)
            self.assertEqual(self.provider.metadata_reads, 2)
            self.assertFalse(self.provider.reads)
    def test_root_propfind_collection_metadata_and_complete_framing(self):
        for depth, expected_hrefs in [('0', ['/']), ('1', ['/', '/Phone/'])]:
            result, sink = self.deliver(self.request('PROPFIND', '/', {'depth':depth}))
            parsed = self.parsed(sink); body = parsed.read()
            self.assertEqual(parsed.status, 207)
            self.assertTrue(result.complete)
            self.assertEqual(result.sent, len(body))
            self.assertEqual(len(body), int(parsed.getheader('Content-Length')))
            self.assertEqual(parsed.getheader('Content-Type'), 'application/xml; charset=utf-8')
            root = ET.fromstring(body)
            self.assertEqual([node.text for node in root.iter(w.DAV+'href')], expected_hrefs)
            first = root.find(w.DAV+'response')
            self.assertEqual(first.find('.//' + w.DAV+'displayname').text, 'Android synthetic')
            self.assertIsNotNone(first.find('.//' + w.DAV+'resourcetype/' + w.DAV+'collection'))
            self.assertFalse(self.provider.reads)
    def test_propfind_xml_uri_unicode_duplicates(self):
        _, sink = self.deliver(self.request('PROPFIND','/Phone/',{'depth':'1'}))
        root = ET.fromstring(self.parsed(sink).read())
        links = [x.text for x in root.iter(w.DAV+'href')]
        self.assertEqual(len(links), len(set(links)))
        self.assertTrue(any('%E5%86%99%E7%9C%9F%20%26%20Notes/' in x for x in links))
        path = '/Phone/' + w.quote('写真 & Notes', safe='') + '/'
        _, sink = self.deliver(self.request('PROPFIND',path,{'depth':'1'}))
        body = self.parsed(sink).read(); self.assertIn(b'&lt;&amp;&gt;', body)
        root = ET.fromstring(body); link = list(root.iter(w.DAV+'href'))[-1].text
        _, sink = self.deliver(self.request(target=link)); self.assertEqual(len(self.parsed(sink).read()), 257)
    def test_propfind_select_unknown_propname_utf16(self):
        body = '<D:propfind xmlns:D="DAV:" xmlns:x="urn:test"><D:prop><D:getcontentlength/><x:missing/></D:prop></D:propfind>'
        _, sink = self.deliver(self.request('PROPFIND','/Phone/integrity.bin',{'depth':'0'},body.encode('utf-16')))
        root = ET.fromstring(self.parsed(sink).read())
        self.assertEqual([x.text for x in root.iter(w.DAV+'status')], ['HTTP/1.1 200 OK','HTTP/1.1 404 Not Found'])
        body = b'<D:propfind xmlns:D="DAV:"><D:propname/></D:propfind>'
        _, sink = self.deliver(self.request('PROPFIND','/',{'depth':'0'},body))
        root = ET.fromstring(self.parsed(sink).read()); self.assertIsNone(next(root.iter(w.DAV+'displayname')).text)
    def test_infinite_default_and_invalid_depth(self):
        for headers, status in [({},403), ({'depth':'infinity'},403), ({'depth':'2'},400)]:
            response = self.handler.handle(self.request('PROPFIND','/',headers)); self.assertEqual(response.status,status)
    def test_get_head_and_sha256(self):
        result, sink = self.deliver(); response = self.parsed(sink); data = response.read()
        self.assertEqual(len(data), 196625)
        self.assertEqual(hashlib.sha256(data).hexdigest(), hashlib.sha256(oracle.expected(196625)).hexdigest())
        self.assertEqual(result.sent,196625); self.assertTrue(result.complete)
        self.provider.reads.clear()
        _, sink = self.deliver(self.request('HEAD',headers={'range':'bytes=0-1'}))
        response = self.parsed(sink,'HEAD')
        self.assertEqual(response.getheader('Content-Length'),'196625'); self.assertEqual(response.status,200)
        self.assertEqual(response.read(),b''); self.assertFalse(self.provider.reads)
    def test_range_boundaries_and_exact_content(self):
        for value, offset, count in [('bytes=0-0',0,1), ('bytes=65535-65537',65535,3), ('bytes=-17',196608,17),
                                     ('bytes=196624-',196624,1), ('bytes=196620-999999',196620,5)]:
            _, sink = self.deliver(self.request(headers={'range':value}))
            response = self.parsed(sink); data=response.read()
            self.assertEqual(response.status,206)
            self.assertEqual(response.getheader('Content-Range'),f'bytes {offset}-{offset+count-1}/196625')
            self.assertEqual(int(response.getheader('Content-Length')),count)
            self.assertEqual(data, oracle.expected(196625)[offset:offset+count])
    def test_invalid_unsatisfiable_and_multi_ranges(self):
        for value in ('bytes=196625-', 'bytes=9-1', 'bytes=-0', 'bytes=-', 'bytes=0-1,4-5', 'bytes=x-y'):
            response=self.handler.handle(self.request(headers={'range':value}))
            self.assertEqual(response.status,416); self.assertEqual(response.headers['Content-Range'],'bytes */196625')
    def test_empty_file_eof(self):
        result,sink=self.deliver(self.request(target='/Phone/empty.bin'))
        response=self.parsed(sink); self.assertEqual(response.getheader('Content-Length'),'0'); self.assertEqual(response.read(),b'')
        self.assertTrue(result.complete)
        self.assertEqual(self.handler.handle(self.request(target='/Phone/empty.bin',headers={'range':'bytes=0-0'})).status,416)
    def test_source_must_confirm_eof_before_last_chunk(self):
        original=self.provider.read
        def wrong_eof(node,offset,count):
            if offset==node.size and count==1:return b'x'
            return original(node,offset,count)
        self.provider.read=wrong_eof
        result,sink=self.deliver()
        self.assertFalse(result.complete);self.assertTrue(sink.aborted)
        with self.assertRaises(http.client.IncompleteRead):self.parsed(sink).read()
        result,sink=self.deliver(self.request(target='/Phone/empty.bin'))
        self.assertEqual(self.parsed(sink).status,502)
    def test_preheader_failure_short_corrupt_extra_raise(self):
        for fault in ('short','corrupt','extra','raise'):
            self.provider.fault_at=0; self.provider.fault=fault
            result,sink=self.deliver(); response=self.parsed(sink)
            self.assertEqual(response.status,502); self.assertFalse(result.complete); self.assertTrue(sink.aborted)
            self.assertNotIn(b'200 OK',sink.data)
    def test_mid_body_failure_short_corrupt_extra_raise(self):
        for fault in ('short','corrupt','extra','raise'):
            self.provider.fault_at=w.CHUNK; self.provider.fault=fault
            result,sink=self.deliver()
            self.assertEqual(result.sent,w.CHUNK); self.assertFalse(result.complete); self.assertTrue(sink.aborted)
            with self.assertRaises(http.client.IncompleteRead): self.parsed(sink).read()
            self.assertEqual(bytes(sink.data).count(b'HTTP/1.1'),1)
    def test_unchecked_chunk_client_can_silently_truncate(self):
        self.provider.fault_at=w.CHUNK
        result,sink=self.deliver(); data=receive.receive(bytes(sink.data),unchecked=True)
        self.assertEqual(len(data),w.CHUNK); self.assertFalse(result.complete)
        self.assertNotEqual(hashlib.sha256(data).digest(),hashlib.sha256(oracle.expected(196625)).digest())
    def test_same_length_wire_corruption_requires_hash(self):
        _,sink=self.deliver(); sink.data[-1] ^= 1
        data=receive.receive(bytes(sink.data)) # HTTP framing succeeds; integrity does not.
        self.assertEqual(len(data),196625)
        self.assertNotEqual(hashlib.sha256(data).digest(),hashlib.sha256(oracle.expected(196625)).digest())
    def test_cancel_before_headers(self):
        cancel=w.Cancel();cancel.cancel()
        result,sink=self.deliver(cancel=cancel)
        self.assertFalse(result.complete);self.assertFalse(result.committed);self.assertEqual(sink.data,b'');self.assertTrue(sink.aborted)
    def test_cancel_mid_stream(self):
        cancel=w.Cancel()
        def hook(sink,data):
            if len(sink.writes)==2: cancel.cancel()
        result,sink=self.deliver(sink=Sink(on_write=hook),cancel=cancel)
        self.assertFalse(result.complete);self.assertTrue(sink.aborted)
    def test_disconnect_and_short_writes_backpressure(self):
        result,sink=self.deliver(sink=Sink(limit=997))
        self.assertTrue(result.complete);self.assertEqual(receive.receive(bytes(sink.data)),oracle.expected(196625))
        self.assertTrue(all(count<=w.CHUNK for _,count in self.provider.reads))
        def hook(sink,data):
            if len(sink.writes)==2: raise BrokenPipeError()
        result,sink=self.deliver(sink=Sink(on_write=hook)); self.assertFalse(result.complete);self.assertTrue(sink.aborted)
    def test_no_prefetch_while_sink_is_blocked(self):
        observed=[]
        def hook(sink,data): observed.append(len(self.provider.reads))
        result,sink=self.deliver(sink=Sink(on_write=hook))
        self.assertTrue(result.complete);self.assertEqual(observed[:3],[1,1,2])
    def test_unknown_size_metadata_only_rejected(self):
        for method in ('GET','HEAD'):
            result,sink=self.deliver(self.request(method,'/Phone/metadata-only.bin'))
            self.assertEqual(result.status,503)
        self.assertFalse(self.provider.reads)
        _,sink=self.deliver(self.request('PROPFIND','/Phone/metadata-only.bin',{'depth':'0'}))
        self.assertNotIn(b'getcontentlength',self.parsed(sink).read())
    def test_partial_unavailable_empty_success(self):
        for state in (w.State.PARTIAL,w.State.DEVICE_UNAVAILABLE):
            self.provider.states[1]=state
            self.assertEqual(self.handler.handle(self.request('PROPFIND','/Phone/',{'depth':'1'})).status,503)
        self.provider.states[1]=w.State.EMPTY_SUCCESS
        self.assertEqual(self.handler.handle(self.request('PROPFIND','/Phone/',{'depth':'1'})).status,502)
        self.provider.tree[1]=()
        self.assertEqual(self.handler.handle(self.request('PROPFIND','/Phone/',{'depth':'1'})).status,207)
    def test_stale_identity_before_and_during_read(self):
        response=self.handler.handle(self.request());self.provider.invalidate()
        result=w.send(self.handler,response,Sink());self.assertEqual(result.status,409);self.assertFalse(result.complete)
        response=self.handler.handle(self.request())
        def hook(sink,data):
            if len(sink.writes)==1:self.provider.invalidate()
        sink=Sink(on_write=hook);result=w.send(self.handler,response,sink)
        self.assertFalse(result.complete);self.assertTrue(sink.aborted)
    def test_all_mutations_rejected(self):
        for method in ('PUT','POST','PATCH','DELETE','COPY','MOVE','MKCOL','PROPPATCH','LOCK','UNLOCK'):
            response=self.handler.handle(self.request(method));self.assertEqual(response.status,403)
            self.assertNotIn('Allow',response.headers)
        self.assertFalse(self.provider.reads)
    def test_path_traversal_and_invalid_names(self):
        for target in ('/../','/%2e%2e/','/Phone/%2Fetc','/Phone/%5cetc','//evil/','/%00','/%zz','/Phone/?x=1','http://evil/'):
            self.assertEqual(self.handler.handle(self.request(target=target)).status,400,target)
        # Decode exactly once: a literal encoded traversal string is not traversed.
        self.assertEqual(self.handler.handle(self.request(target='/%252e%252e/')).status,404)
    def test_parser_caps_ambiguity_and_incomplete_requests(self):
        cases=[b'Content-Length: 4\r\nContent-Length: 4\r\n\r\nxxxx',
               b'Transfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n',
               b'Content-Length: 40000\r\n\r\n',b'Content-Length: 4\r\n\r\nx',
               b'Bad Header: x\r\n\r\n',b'Expect: 100-continue\r\n\r\n']
        for case in cases:
            with self.assertRaises(w.Failure):w.read_request(io.BytesIO(b'PROPFIND / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\n'+case))
        with self.assertRaises(w.Failure):w.read_request(io.BytesIO(b'GET / HTTP/1.1\r\nHost: evil\r\n\r\n'))
    def test_chunked_request_and_pipelining(self):
        data=b'PROPFIND / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n'
        self.assertEqual(w.read_request(io.BytesIO(data)).body,b'abc')
    def test_xml_entities_malformed_and_caps(self):
        for body in (b'bad',b'<!DOCTYPE x [<!ENTITY x "hello">]><x/>',b'<x/>'):
            self.assertEqual(self.handler.handle(self.request('PROPFIND','/',{'depth':'0'},body)).status,400)
        self.provider.tree[1]=tuple([3]*129)
        self.assertEqual(self.handler.handle(self.request('PROPFIND','/Phone/',{'depth':'1'})).status,507)
    def test_failed_stream_prevents_next_pipelined_response(self):
        self.provider.fault_at=w.CHUNK
        data=(b'GET /Phone/integrity.bin HTTP/1.1\r\nHost: 127.0.0.1:18765\r\n\r\n'
              b'OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\n\r\n')
        sink=Sink();logs=[]
        w.serve_connection(self.handler,io.BytesIO(data),sink,log=logs.append)
        responses=[event for event in logs if 'complete' in event]
        self.assertEqual(len(responses),1);self.assertFalse(responses[0]['complete']);self.assertTrue(sink.aborted)
    def test_replaced_generation_storage_and_handle_rejected(self):
        node=self.provider.nodes[3]
        for identity in (replace(node.identity,generation='old'),replace(node.identity,storage=88),replace(node.identity,handle=99)):
            stale=replace(node,identity=identity)
            self.assertFalse(self.provider.current(stale))
            with self.assertRaises(w.Failure):self.provider.read(stale,0,1)
    def test_header_cap_and_size_cap(self):
        with self.assertRaises(w.Failure):
            w.read_request(io.BytesIO(b'OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\nX: '+b'x'*20000+b'\r\n\r\n'))
        self.provider.nodes[3]=replace(self.provider.nodes[3],size=w.MAX_RESPONSE+1)
        self.assertEqual(self.handler.handle(self.request()).status,503)
    def test_runner_default_is_socket_free_and_log_bounded(self):
        import runner
        import tempfile
        from pathlib import Path
        with patch('sys.argv',['runner.py']), patch('builtins.print') as output:
            runner.main()
            self.assertIn('"listener_started": false',output.call_args.args[0])
        with tempfile.TemporaryDirectory() as directory:
            cancel=w.Cancel(); path=Path(directory)/'log.jsonl'
            log=runner.BoundedLog(path,cancel)
            for _ in range(100):log({'message':'x'*1000})
            log.close()
            self.assertLessEqual(path.stat().st_size,runner.LOG_CAP)
            self.assertTrue(log.limit_reached)
            self.assertTrue(cancel.event.is_set())

    def test_runner_deadline_expiration_is_logged_and_closes_fake_listener(self):
        import runner, tempfile, threading
        from pathlib import Path
        class FakeListener:
            closed=False
            def bind(self,address):self.address=address
            def listen(self,count):self.backlog=count
            def settimeout(self,value):self.timeout=value
            def close(self):self.closed=True
        listener=FakeListener()
        class ImmediateTimer:
            def __init__(self,interval,function,args=()):self.function=function;self.args=args
            def start(self):self.function(*self.args)
            def cancel(self):pass
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'deadline.jsonl'
            with patch.object(runner.socket,'socket',return_value=listener), \
                 patch.object(runner.threading,'Timer',ImmediateTimer), \
                 patch('signal.signal',lambda *args:None):
                runner.serve(path)
            import json
            events=[json.loads(line) for line in path.read_text().splitlines()]
            self.assertTrue(listener.closed)
            self.assertIn({'event':'server_timeout','reason':'lifetime_timeout'},
                          [{k:v for k,v in event.items() if k!='time'} for event in events])
            self.assertEqual(events[-1]['event'],'stop')
            self.assertEqual(events[-1]['reason'],'lifetime_timeout')

    def test_runner_signal_shutdown_is_cleanly_distinguished(self):
        import runner, signal, socket, tempfile, threading
        from pathlib import Path
        handlers={}
        class FakeListener:
            closed=False
            def bind(self,address):pass
            def listen(self,count):pass
            def settimeout(self,value):pass
            def close(self):self.closed=True
            def accept(self):
                handlers[signal.SIGINT](signal.SIGINT,None)
                raise socket.timeout()
        listener=FakeListener()
        class PassiveTimer:
            def __init__(self,*args,**kwargs):pass
            def start(self):pass
            def cancel(self):pass
        def install(signum,handler):handlers[signum]=handler
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'shutdown.jsonl'
            with patch.object(runner.socket,'socket',return_value=listener), \
                 patch.object(runner.threading,'Timer',PassiveTimer), \
                 patch('signal.signal',install):
                runner.serve(path)
            import json
            events=[json.loads(line) for line in path.read_text().splitlines()]
            self.assertTrue(listener.closed)
            self.assertEqual(events[-1]['event'],'stop')
            self.assertEqual(events[-1]['reason'],'sigint')

    def test_runner_fake_listener_accepts_and_serves_options(self):
        import runner, tempfile
        from pathlib import Path
        connection=MemorySocket(b'OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\nConnection: close\r\n\r\n')
        class FakeListener:
            closed=False
            def bind(self,address):self.address=address
            def listen(self,count):self.backlog=count
            def settimeout(self,value):pass
            def accept(self):return connection,('127.0.0.1',54321)
            def close(self):self.closed=True
        listener=FakeListener()
        class PassiveTimer:
            def __init__(self,*args,**kwargs):pass
            def start(self):pass
            def cancel(self):pass
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'synthetic-server.jsonl'
            with patch.object(runner.socket,'socket',return_value=listener), \
                 patch.object(runner.threading,'Timer',PassiveTimer), \
                 patch('signal.signal',lambda *args:None), \
                 patch.object(runner,'CONNECTIONS',1):
                runner.serve(path)
            import json
            events=[json.loads(line) for line in path.read_text().splitlines()]
            request=next(event for event in events if event.get('event')=='request')
            self.assertEqual(request['method'],'OPTIONS');self.assertEqual(request['status'],200)
            self.assertTrue(request['complete']);self.assertTrue(request['close'])
            self.assertTrue(connection.closed);self.assertTrue(listener.closed)
            self.assertEqual(events[-1]['reason'],'connection_budget')

    def test_actual_serve_loop_over_socketpairs_protocol_concurrency_and_shutdown(self):
        import json, queue, runner, socket, tempfile, threading
        from pathlib import Path
        requests=[
            ('OPTIONS','/',{},b''),
            ('OPTIONS','/',{},b''),
            ('PROPFIND','/',{'Depth':'0'},b''),
            ('PROPFIND','/',{'Depth':'1'},b''),
            ('GET','/Phone/integrity.bin',{'Range':'bytes=0-15'},b''),
            ('PROPFIND','/',{'Depth':'0'},b''),
        ]
        with patch('socket.socket',self.real_socket):
            pairs=[socket.socketpair() for _ in requests]
        self.assertTrue(all(pair[0].family==socket.AF_UNIX for pair in pairs))
        server_connections=[pair[0] for pair in pairs]
        clients=[pair[1] for pair in pairs]
        for client in clients:self.addCleanup(client.close)
        class FakeListener:
            def __init__(self):
                self.connections=queue.Queue();self.closed=False;self.ready=threading.Event()
            def bind(self,address):self.address=address;self.ready.set()
            def listen(self,count):self.backlog=count
            def settimeout(self,value):self.timeout=value
            def offer(self,index,connection):self.connections.put((connection,('127.0.0.1',54000+index)))
            def accept(self):
                try:return self.connections.get(timeout=0.5)
                except queue.Empty:raise socket.timeout()
            def close(self):self.closed=True
        listener=FakeListener();released=queue.Queue()
        class TrackingSlots(runner.ConnectionSlots):
            def release(self):super().release();released.put(True)
        class PassiveTimer:
            def __init__(self,*args,**kwargs):pass
            def start(self):pass
            def cancel(self):pass
        worker_errors=[];client_errors=[]
        def run_server(path):
            try:runner.serve(path)
            except BaseException as error:worker_errors.append(error)
        def wire_request(method,target,headers,body):
            values={'Host':'127.0.0.1:18765','Connection':'close',**headers}
            if body:values['Content-Length']=str(len(body))
            lines=[f'{method} {target} HTTP/1.1']+[f'{key}: {value}' for key,value in values.items()]
            return ('\r\n'.join(lines)+'\r\n\r\n').encode()+body
        results=[None]*len(requests)
        def exchange(index,gate=None):
            try:
                method,target,headers,body=requests[index];client=clients[index]
                client.settimeout(5)
                if gate is not None:gate.wait(timeout=4)
                client.sendall(wire_request(method,target,headers,body))
                response=bytearray()
                while True:
                    block=client.recv(4096)
                    if not block:break
                    response.extend(block)
                header,payload=bytes(response).split(b'\r\n\r\n',1)
                lines=header.split(b'\r\n')
                status=int(lines[0].split()[1])
                parsed_headers=[tuple(part.decode('ascii').strip() for part in line.split(b':',1))
                                for line in lines[1:]]
                results[index]=(status,parsed_headers,payload)
                client_errors.append((index,b''))
            except BaseException as error:client_errors.append((index,error))
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'real-serve-loop.jsonl'
            with patch.object(runner.socket,'socket',return_value=listener), \
                 patch.object(runner.threading,'Timer',PassiveTimer), \
                 patch('signal.signal',lambda *args:None), \
                 patch.object(runner,'CONNECTIONS',len(requests)), \
                 patch.object(runner,'ConnectionSlots',TrackingSlots):
                server=threading.Thread(target=run_server,args=(path,));server.start()
                self.assertTrue(listener.ready.wait(timeout=2))
                listener.offer(0,server_connections[0]);exchange(0);released.get(timeout=2)
                listener.offer(1,server_connections[1]);exchange(1);released.get(timeout=2)
                for index in range(2,len(requests)):listener.offer(index,server_connections[index])
                gate=threading.Barrier(5)
                clients_threads=[threading.Thread(target=exchange,args=(i,gate)) for i in range(2,len(requests))]
                for client_thread in clients_threads:client_thread.start()
                gate.wait(timeout=4)
                for client_thread in clients_threads:client_thread.join(timeout=7);self.assertFalse(client_thread.is_alive())
                server.join(timeout=7);self.assertFalse(server.is_alive())
            self.assertEqual(worker_errors,[])
            self.assertEqual(sorted(client_errors),[(i,b'') for i in range(len(requests))])
            self.assertTrue(listener.closed)
            import json
            events=[json.loads(line) for line in path.read_text().splitlines()]
        self.assertEqual([result[0] for result in results],[200,200,207,207,206,207])
        for index in range(len(requests)):
            headers=dict(results[index][1]);payload=results[index][2]
            self.assertEqual(headers['Connection'],'close')
            self.assertEqual(int(headers['Content-Length']),len(payload))
        self.assertEqual(len(ET.fromstring(results[2][2]).findall(w.DAV+'response')),1)
        self.assertEqual(len(ET.fromstring(results[3][2]).findall(w.DAV+'response')),2)
        self.assertEqual(len(ET.fromstring(results[5][2]).findall(w.DAV+'response')),1)
        range_headers=dict(results[4][1])
        self.assertEqual(range_headers['Content-Range'],f'bytes 0-15/{self.provider.nodes[3].size}')
        self.assertEqual(results[4][2],w.fixture_bytes(0,16))
        self.assertEqual(sum(event['event']=='connection_accepted' for event in events),len(requests))
        requests_logged=[event for event in events if event.get('event')=='request']
        requests_by_connection={event['connection']:(event['method'],event.get('depth'),event['status'])
                                for event in requests_logged}
        self.assertEqual(requests_by_connection,{0:('OPTIONS',None,200),1:('OPTIONS',None,200),
                            2:('PROPFIND','0',207),3:('PROPFIND','1',207),
                            4:('GET',None,206),5:('PROPFIND','0',207)})
        self.assertTrue(all(event['complete'] and event['close'] for event in requests_logged))
        self.assertEqual(sum(event.get('reason')=='peer_requested_close' for event in events),len(requests))
        self.assertFalse(any(event.get('reason')=='connection_limit' for event in events))
        self.assertFalse(any(event.get('event')=='parse_error' for event in events))
        self.assertEqual(events[-1]['event'],'stop')
        self.assertEqual(events[-1]['reason'],'connection_budget')

    def test_runner_worker_start_failure_logs_and_releases_slot(self):
        import runner, tempfile, threading
        from pathlib import Path
        from unittest.mock import patch
        class FakeListener:
            closed=False
            def bind(self,address):pass
            def listen(self,count):pass
            def settimeout(self,value):pass
            def accept(self):return connection,('127.0.0.1',54321)
            def close(self):self.closed=True
        listener=FakeListener();connection=MemorySocket()
        class FailedThread:
            def __init__(self,*args,**kwargs):pass
            def start(self):raise RuntimeError('synthetic thread start failure')
        class PassiveTimer:
            def __init__(self,*args,**kwargs):pass
            def start(self):pass
            def cancel(self):pass
        slots=runner.ConnectionSlots(4)
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'worker-start.jsonl'
            with patch.object(runner.socket,'socket',return_value=listener), \
                 patch.object(runner.threading,'Timer',PassiveTimer), \
                 patch.object(runner.threading,'Thread',FailedThread), \
                 patch('signal.signal',lambda *args:None), \
                 patch.object(runner,'ConnectionSlots',return_value=slots), \
                 patch.object(runner,'CONNECTIONS',1):
                with self.assertRaisesRegex(RuntimeError,'synthetic thread start failure'):
                    runner.serve(path)
            import json
            events=[json.loads(line) for line in path.read_text().splitlines()]
            self.assertTrue(connection.closed);self.assertTrue(listener.closed)
            self.assertTrue(slots.acquire());slots.release()
            self.assertTrue(any(e.get('event')=='worker_start_error' for e in events))
            error=next(e for e in events if e.get('event')=='server_error')
            self.assertEqual((error['stage'],error['error']),('worker_start','RuntimeError'))
            self.assertEqual(events[-1]['reason'],'server_error')

    def test_unexpected_worker_exception_is_logged_and_releases_slot(self):
        import runner
        slots=runner.ConnectionSlots(1);self.assertTrue(slots.acquire())
        connection=MemorySocket();events=[];sockets={connection}
        with patch.object(runner,'serve_connection',side_effect=RuntimeError('synthetic worker error')):
            reason=runner.finish_worker(connection,31,self.handler,w.Cancel(),events.append,
                                        sockets,__import__('threading').Lock(),slots)
        self.assertEqual(reason,'worker_error');self.assertTrue(connection.closed)
        self.assertEqual(sockets,set());self.assertTrue(slots.acquire());slots.release()
        self.assertTrue(any(e.get('event')=='worker_error' for e in events))
        self.assertEqual(next(e for e in events if e.get('event')=='connection_closed')['reason'],'worker_error')

    def test_runner_logs_accept_and_connection_without_http_bytes(self):
        import runner
        events=[];connection=MemorySocket()
        runner.log_startup_error(events.append,'bind',PermissionError(1,'Operation not permitted'))
        runner.log_accepted(events.append,7,('127.0.0.1',54321))
        reason=runner.handle_connection(connection,7,self.handler,w.Cancel(),events.append)
        startup=next(event for event in events if event['event']=='startup_error')
        accepted=next(event for event in events if event['event']=='connection_accepted')
        closed=next(event for event in events if event['event']=='connection_closed')
        self.assertEqual((startup['stage'],startup['error']),('bind','PermissionError'))
        self.assertIn('Operation not permitted',startup['reason'])
        self.assertEqual((accepted['connection'],accepted['peer_address'],accepted['peer_port']),(7,'127.0.0.1',54321))
        self.assertEqual(reason,'peer_closed_without_request')
        self.assertEqual(closed['reason'],reason);self.assertFalse(closed['first_bytes_received'])
        self.assertFalse(any(event['event']=='first_request_bytes' for event in events))
        self.assertFalse(any(event.get('method') for event in events))
        import tempfile,json
        from pathlib import Path
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'accepted.jsonl';bounded=runner.BoundedLog(path,w.Cancel())
            runner.log_accepted(bounded,8,('127.0.0.1',54322));bounded.close()
            record=json.loads(path.read_text())
            self.assertIsInstance(record['time'],float);self.assertEqual(record['peer_port'],54322)

    def test_runner_logs_first_byte_and_redacts_authorization_and_cookie(self):
        import runner
        secret='synthetic-test-token-987654321'
        wire=(b'OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\n'
              b'User-Agent: Synthetic Test Agent\r\nAuthorization: Bearer '+secret.encode()+
              b'\r\nCookie: session='+secret.encode()+b'\r\nConnection: close\r\n\r\n')
        events=[];connection=MemorySocket(wire)
        runner.log_accepted(events.append,2,('127.0.0.1',43210))
        reason=runner.handle_connection(connection,2,self.handler,w.Cancel(),events.append)
        first=next(event for event in events if event['event']=='first_request_bytes')
        request=next(event for event in events if event['event']=='request')
        closed=next(event for event in events if event['event']=='connection_closed')
        serialized=''.join(repr(event) for event in events)+connection.outgoing.decode('latin1')
        self.assertGreater(first['byte_count'],0)
        self.assertTrue(request['first_bytes_received']);self.assertTrue(request['request_line_parsed'])
        self.assertEqual(request['method'],'OPTIONS');self.assertEqual(request['status'],200)
        self.assertEqual(request['user_agent'],'Synthetic Test Agent')
        self.assertTrue(request['authorization_present'])
        self.assertEqual(reason,'peer_requested_close');self.assertEqual(closed['reason'],reason)
        self.assertNotIn(secret,serialized);self.assertNotIn('Cookie',serialized);self.assertNotIn('Authorization:',serialized)
        self.assertEqual(w._log_target('/Phone/integrity.bin?token='+secret),'/Phone/integrity.bin?<redacted>')
        self.assertNotIn(secret,w._log_target('/Phone/token/'+secret))
        self.assertNotIn(secret,w._log_target('http://user:'+secret+'@localhost/private#fragment'))
        self.assertNotIn(secret,w._log_user_agent('agent access_token='+secret))

    def test_instrumented_reader_preserves_options_propfind_head_and_get(self):
        import runner
        cases=(('OPTIONS','/',{},200,0),
               ('PROPFIND','/Phone/',{'Depth':'1'},207,None),
               ('HEAD','/Phone/integrity.bin',{},200,0),
               ('GET','/Phone/empty.bin',{},200,0))
        for method,target,headers,status,body_size in cases:
            with self.subTest(method=method,target=target):
                fields={'Host':'127.0.0.1:18765',**headers,'Connection':'close'}
                request=(f'{method} {target} HTTP/1.1\r\n' +
                         ''.join(f'{name}: {value}\r\n' for name,value in fields.items()) + '\r\n').encode()
                connection=MemorySocket(request);events=[]
                runner.handle_connection(connection,9,self.handler,w.Cancel(),events.append)
                response=http.client.HTTPResponse(receive.CapturedSocket(bytes(connection.outgoing)),method=method)
                response.begin();body=response.read()
                self.assertEqual(response.status,status)
                if body_size is not None:self.assertEqual(len(body),body_size)
                if method=='HEAD':self.assertEqual(int(response.getheader('Content-Length')),196625)
                self.assertTrue(any(event.get('event')=='request' and event.get('request_line_parsed') for event in events))

    def test_runner_reports_invalid_request_line_and_timeout(self):
        import runner
        invalid=b'GET / HTTP/0.9\r\nHost: 127.0.0.1:18765\r\n\r\n'
        events=[];connection=MemorySocket(invalid)
        reason=runner.handle_connection(connection,3,self.handler,w.Cancel(),events.append)
        line=next(event for event in events if event['event']=='request_line')
        error=next(event for event in events if event['event']=='parse_error')
        closed=next(event for event in events if event['event']=='connection_closed')
        self.assertFalse(line['parsed']);self.assertEqual(line['reason'],'HTTP/1.1 required')
        self.assertFalse(error['request_line_parsed']);self.assertEqual(error['status'],400)
        self.assertEqual(reason,'parse_error');self.assertEqual(closed['reason'],reason)

        timed_events=[];timed=MemorySocket(error=TimeoutError('synthetic timeout'))
        reason=runner.handle_connection(timed,4,self.handler,w.Cancel(),timed_events.append)
        timeout=next(event for event in timed_events if event['event']=='parse_error')
        closed=next(event for event in timed_events if event['event']=='connection_closed')
        self.assertEqual(timeout['close_reason'],'socket_timeout')
        self.assertFalse(timeout['first_bytes_received'])
        self.assertEqual(reason,'socket_timeout');self.assertEqual(closed['reason'],reason)

        partial_events=[];partial=MemorySocket(b'GET /',TimeoutError('synthetic partial-line timeout'))
        reason=runner.handle_connection(partial,6,self.handler,w.Cancel(),partial_events.append)
        timeout=next(event for event in partial_events if event['event']=='parse_error')
        self.assertTrue(timeout['first_bytes_received'])
        self.assertTrue(any(event['event']=='first_request_bytes' for event in partial_events))
        self.assertFalse(timeout['request_line_parsed']);self.assertEqual(reason,'socket_timeout')

    def test_runner_records_server_cancellation_close_reason(self):
        import runner
        cancel=w.Cancel();cancel.cancel()
        events=[];connection=MemorySocket(error=OSError('synthetic shutdown'))
        reason=runner.handle_connection(connection,5,self.handler,cancel,events.append)
        self.assertEqual(reason,'server_cancelled')
        self.assertEqual(next(event for event in events if event['event']=='connection_closed')['reason'],reason)
    def test_runner_reuses_http11_connection_then_honors_peer_close(self):
        import runner
        wire=(b'PROPFIND / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\nDepth: 0\r\n\r\n'
              b'PROPFIND / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\nDepth: 1\r\nConnection: close\r\n\r\n')
        connection=MemorySocket(wire);events=[]
        reason=runner.handle_connection(connection,12,self.handler,w.Cancel(),events.append)
        wire=bytes(connection.outgoing);parsed=[];offset=0
        for _ in range(2):
            header_end=wire.index(b'\r\n\r\n',offset);header=wire[offset:header_end]
            fields=header.split(b'\r\n');status=int(fields[0].split()[1])
            headers={line.split(b':',1)[0].decode().lower():line.split(b':',1)[1].strip().decode()
                     for line in fields[1:]}
            body_start=header_end+4;length=int(headers['content-length'])
            body=wire[body_start:body_start+length];self.assertEqual(len(body),length)
            parsed.append((status,headers,body));offset=body_start+length
        self.assertEqual([item[0] for item in parsed],[207,207])
        self.assertEqual([item[1]['connection'] for item in parsed],['keep-alive','close'])
        requests=[event for event in events if event['event']=='request']
        closed=next(event for event in events if event['event']=='connection_closed')
        self.assertTrue(all(request['complete'] for request in requests))
        self.assertEqual([request['depth'] for request in requests],['0','1'])
        self.assertEqual(reason,'peer_requested_close');self.assertEqual(closed['reason'],reason)
        self.assertFalse(any(event['event']=='parse_error' for event in events))
        self.assertFalse(self.provider.reads)

    def test_runner_connection_slots_stay_bounded_and_recover_after_worker_exits(self):
        import runner, threading
        slots=runner.ConnectionSlots(4)
        self.assertEqual([slots.acquire() for _ in range(4)],[True]*4)
        self.assertFalse(slots.acquire())
        lock=threading.Lock();sockets=set()
        outcomes=[(MemorySocket(b'OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\nConnection: close\r\n\r\n'),w.Cancel(),'peer_requested_close'),
                  (MemorySocket(error=TimeoutError('synthetic idle timeout')),w.Cancel(),'socket_timeout')]
        cancelled=w.Cancel();cancelled.cancel()
        outcomes.append((MemorySocket(error=OSError('synthetic cancellation')),cancelled,'server_cancelled'))
        for _ in range(4):slots.release()
        for number,(connection,cancel,expected) in enumerate(outcomes):
            self.assertTrue(slots.acquire());sockets.add(connection)
            reason=runner.finish_worker(connection,number,self.handler,cancel,lambda event:None,sockets,lock,slots)
            self.assertEqual(reason,expected);self.assertNotIn(connection,sockets)
        acquired=[slots.acquire() for _ in range(4)]
        self.assertEqual(acquired,[True]*4);self.assertFalse(slots.acquire())
        for _ in range(4):slots.release()

    def test_four_concurrent_synthetic_connections_hold_exactly_four_slots(self):
        import runner, threading
        slots=runner.ConnectionSlots(4);lock=threading.Lock();sockets=set()
        rendezvous=threading.Barrier(5);release_reads=threading.Event();workers=[];outcomes=[]
        class GatedMemorySocket(MemorySocket):
            def recv(self,count):
                rendezvous.wait(timeout=3)
                if not release_reads.wait(timeout=3):raise TimeoutError('synthetic gate timeout')
                return super().recv(count)
        def run(number,connection):
            outcomes.append(runner.finish_worker(connection,number,self.handler,w.Cancel(),lambda event:None,
                                                  sockets,lock,slots))
        for number in range(4):
            self.assertTrue(slots.acquire())
            connection=GatedMemorySocket(b'OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\nConnection: close\r\n\r\n')
            sockets.add(connection)
            worker=threading.Thread(target=run,args=(number,connection));worker.start();workers.append(worker)
        rendezvous.wait(timeout=3)
        self.assertFalse(slots.acquire())
        release_reads.set()
        for worker in workers:worker.join(timeout=3);self.assertFalse(worker.is_alive())
        self.assertEqual(outcomes,['peer_requested_close']*4)
        self.assertEqual(sockets,set())
        self.assertEqual([slots.acquire() for _ in range(4)],[True]*4)
        self.assertFalse(slots.acquire())
        for _ in range(4):slots.release()

    def test_repeated_root_depth_zero_responses_close_without_content_reads(self):
        import runner, threading
        slots=runner.ConnectionSlots(4)
        for number in range(7):
            self.assertTrue(slots.acquire())
            connection=MemorySocket(b'PROPFIND / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\nDepth: 0\r\nConnection: close\r\n\r\n')
            reason=runner.finish_worker(connection,number,self.handler,w.Cancel(),lambda event:None,
                                        set(),threading.Lock(),slots)
            response=http.client.HTTPResponse(receive.CapturedSocket(bytes(connection.outgoing)))
            response.begin();body=response.read()
            self.assertEqual(reason,'peer_requested_close')
            self.assertEqual(response.status,207)
            self.assertEqual(len(body),int(response.getheader('Content-Length')))
            self.assertEqual(len(ET.fromstring(body).findall(w.DAV+'response')),1)
            self.assertEqual(response.getheader('Connection'),'close')
            self.assertFalse(self.provider.reads)
    def test_memory_bound_for_maximum_response(self):
        import tracemalloc
        self.provider.nodes[3]=replace(self.provider.nodes[3],size=w.MAX_RESPONSE)
        class HashSink:
            def __init__(self): self.digest=hashlib.sha256();self.count=0;self.aborted=False
            def write(self,data): self.digest.update(data);self.count+=len(data);return len(data)
            def flush(self):pass
            def abort(self):self.aborted=True
        sink=HashSink()
        tracemalloc.start()
        result=w.send(self.handler,self.handler.handle(self.request()),sink)
        _,peak=tracemalloc.get_traced_memory();tracemalloc.stop()
        self.assertTrue(result.complete);self.assertEqual(result.sent,w.MAX_RESPONSE)
        self.assertLess(peak,1024*1024)
    def test_final_write_invalidation_cannot_publish_success(self):
        def hook(sink,data):
            if len(sink.writes)==4:self.provider.invalidate()
        result,sink=self.deliver(sink=Sink(on_write=hook))
        self.assertFalse(result.complete);self.assertTrue(sink.aborted)
    def test_socket_guard_and_connection_request_limit(self):
        import socket
        with self.assertRaises(AssertionError):socket.socket()
        data=b'OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:18765\r\n\r\n'*3
        sink=Sink();logs=[]
        w.serve_connection(self.handler,io.BytesIO(data),sink,max_requests=2,log=logs.append)
        self.assertEqual(len([event for event in logs if 'status' in event]),2);self.assertTrue(sink.aborted)

if __name__=='__main__':unittest.main()
