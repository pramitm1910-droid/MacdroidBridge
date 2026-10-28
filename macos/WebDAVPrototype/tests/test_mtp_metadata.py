import copy
import io
import json
import threading
import time
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch
from urllib.parse import quote
import webdav as w
from mtp_metadata import MTPMetadataProvider
from test_webdav import Sink

class Source:
    """Swift Codable-shaped metadata service double. No content entry point."""
    def __init__(self):
        self.generation, self.namespace, self.session = [str(uuid.uuid4()) for _ in range(3)]
        self.state = 'available'; self.phase = 'complete'; self.calls = []
        self.partial = False; self.stuck = False; self.entered = threading.Event()
        self.release = threading.Event(); self.block = False
        self.active = 0; self.peak = 0; self.path = []; self.invalid = False
        self.root_entries = [self.entry(1, '写真', True), self.entry(2, 'same.txt', size=9),
                             self.entry(3, 'same.txt'), self.entry(4, 'é.txt', size=0)]
    def entry(self, handle, name, directory=False, size=None, parent=0):
        return dict(generation=self.generation, storage=77, handle=handle, parent=parent,
                    name=name, isDirectory=directory, size=size, format=0x3001 if directory else 0x3000)
    def exchange(self, raw):
        req = json.loads(raw); self.calls.append(req['operation'])
        self.active += 1; self.peak = max(self.peak, self.active)
        try:
            if self.block and req['operation'] == 'directory':
                self.entered.set()
                if not self.release.wait(3): raise TimeoutError()
            if self.invalid: raise OSError('disconnected')
            op = req['operation']
            if op == 'refresh': self.namespace = str(uuid.uuid4())
            if op == 'directory': self.path = req['path']
            parent = self.path[-1]['handle'] if self.path else 0
            entries = self.root_entries if parent == 0 else [self.entry(5, 'nested.txt', size=17, parent=1)]
            phase = self.phase
            if op == 'directory' and self.partial or op == 'nextPage' and self.stuck: phase = 'partial'
            snapshot = dict(generation=self.generation, namespace=self.namespace, state={phase:{}},
                            storageState=self.state, storages=[dict(generation=self.generation,id=77,name='Phone')],
                            directoryStorage=77, directoryHandle=parent, entries=copy.deepcopy(entries))
            return json.dumps(dict(version=1,id=req['id'],sequence=req['sequence'],session=self.session,snapshot=snapshot)).encode()
        finally: self.active -= 1
    def interrupt(self): self.invalid = True; self.release.set()

class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.network = patch('socket.socket', side_effect=AssertionError('network forbidden')); self.network.start()
        self.addCleanup(self.network.stop)
        self.source = Source()
        self.provider = MTPMetadataProvider(self.source.exchange, self.source.interrupt)
        self.content = unittest.mock.Mock()
        self.handler = w.Handler(self.provider, self.content)
    def prop(self, target='/', depth='1'):
        return self.handler.handle(w.Request('PROPFIND', target, {'depth':depth}))
    def test_complete_root_and_nested_depths(self):
        for depth, count in [('0',1),('1',2)]:
            response = self.prop(depth=depth)
            self.assertEqual(response.status,207)
            self.assertEqual(response.body.count(b'<D:response>'),count)
        response = self.prop('/Phone/')
        self.assertEqual(response.status,207)
        self.assertIn('写真'.encode(),response.body)
        self.assertIn(b'same.txt [MTP-4d-2]',response.body)
        self.assertIn(b'same.txt [MTP-4d-3]',response.body)
        self.assertEqual(self.prop('/Phone/'+quote('写真')+'/').status,207)
    def test_known_and_unknown_sizes(self):
        response = self.prop('/Phone/')
        root = w.ET.fromstring(response.body)
        values={r.find(w.DAV+'href').text:r for r in root}
        for path, size in [('/Phone/same.txt%20%5BMTP-4d-2%5D','9'),('/Phone/same.txt%20%5BMTP-4d-3%5D',None),('/Phone/%C3%A9.txt','0')]:
            element = values[path].find('.//'+w.DAV+'getcontentlength')
            self.assertEqual(None if element is None else element.text,size)
    def test_explicit_continuation_and_incomplete_rejection(self):
        self.source.partial = True
        self.assertEqual(self.prop('/Phone/').status,207)
        self.assertEqual(self.source.calls.count('nextPage'),1)
        self.source.stuck = True
        for depth in ('0','1'):
            before = self.source.calls.count('nextPage')
            response = self.prop('/Phone/',depth)
            self.assertEqual(response.status,503); self.assertEqual(response.body,b'')
            self.assertEqual(self.source.calls.count('nextPage')-before,3)
    def test_directory_cap_is_all_or_nothing(self):
        self.source.root_entries = [self.source.entry(i,str(i)) for i in range(1,130)]
        response = self.prop('/Phone/')
        self.assertEqual(response.status,507); self.assertEqual(response.body,b'')
    def test_storage_states_fail_explicitly_without_refresh(self):
        for state in ('emptySuccess','deviceUnavailable','transportFailure','disconnected','cancelled'):
            self.source.state = state
            for depth in ('0','1'):
                self.assertEqual(self.prop(depth=depth).status,503)
        self.assertNotIn('refresh',self.source.calls)
    def test_empty_complete_directory_is_valid(self):
        self.source.root_entries=[]
        self.assertEqual(self.prop('/Phone/').status,207)
    def test_get_head_no_content_or_read_capability(self):
        for method in ('GET','HEAD'):
            for path in ('/Phone/known','/Phone/unknown','/'):
                response = self.handler.handle(w.Request(method,path,{'range':'bytes=0-1'}))
                sink = Sink(); result = w.send(self.handler,response,sink)
                self.assertEqual(result.status,503); self.assertEqual(result.sent,0)
                self.assertNotIn('Accept-Ranges',result.headers)
        response = self.handler.handle(w.Request('OPTIONS','*'))
        self.assertEqual(response.headers['Allow'],'OPTIONS, PROPFIND')
        self.assertEqual(self.content.mock_calls,[])
    def test_mutations_rejected(self):
        for method in w.MUTATING:
            self.assertEqual(self.handler.handle(w.Request(method,'/Phone/')).status,403)
        self.assertEqual(self.content.mock_calls,[])
    def test_disconnect_rejects_prepared_body(self):
        response = self.prop('/Phone/')
        self.provider.invalidate()
        sink = Sink(); result = w.send(self.handler,response,sink)
        self.assertEqual(result.status,503); self.assertEqual(result.sent,0)
        self.assertNotIn(b'multistatus',sink.data)
        self.assertEqual(self.prop().status,503)
    def test_disconnect_between_headers_and_body(self):
        response = self.prop('/Phone/')
        sink = Sink(on_write=lambda *_: self.provider.invalidate())
        result = w.send(self.handler,response,sink)
        self.assertFalse(result.complete); self.assertTrue(sink.aborted)
        self.assertNotIn(b'multistatus',sink.data)
    def test_refresh_revokes_old_nodes_and_response(self):
        root = self.provider.root(); response = self.prop()
        self.provider.refresh()
        self.assertFalse(self.provider.current(root))
        sink=Sink(); result=w.send(self.handler,response,sink)
        self.assertEqual(result.status,409); self.assertNotIn(b'multistatus',sink.data)
        self.assertEqual(self.prop().status,207)
        self.assertEqual(self.source.calls.count('refresh'),1)
    def test_replacement_generation_and_namespace_fail_closed(self):
        for field in ('generation','namespace','session'):
            source=Source(); provider=MTPMetadataProvider(source.exchange,source.interrupt)
            root=provider.root(); setattr(source,field,str(uuid.uuid4()))
            response=w.Handler(provider,None).handle(w.Request('PROPFIND','/',{'depth':'1'}))
            self.assertEqual(response.status,503); self.assertFalse(provider.current(root))
    def test_wrong_storage_parent_generation_and_duplicate_handles(self):
        for field,value in [('storage',88),('parent',99),('generation',str(uuid.uuid4())),('handle',0)]:
            previous=self.source.root_entries[0][field]; self.source.root_entries[0][field]=value
            self.assertEqual(self.prop('/Phone/').status,409)
            self.source.root_entries[0][field]=previous
        self.source.root_entries.append(self.source.root_entries[0])
        self.assertEqual(self.prop('/Phone/').status,409)
    def test_concurrent_requests_serialize_entire_continuations(self):
        self.source.partial=True
        with ThreadPoolExecutor(max_workers=6) as pool:
            replies=list(pool.map(lambda _: self.prop('/Phone/'),range(12)))
        self.assertTrue(all(r.status==207 for r in replies)); self.assertEqual(self.source.peak,1)
        calls=self.source.calls
        for i,op in enumerate(calls):
            if op=='directory': self.assertEqual(calls[i+1],'nextPage')
    def test_queue_bound_and_disconnect_cancel_active_and_waiting(self):
        self.provider=MTPMetadataProvider(self.source.exchange,self.source.interrupt,max_pending=2)
        self.handler=w.Handler(self.provider,None); self.source.block=True
        with ThreadPoolExecutor(max_workers=3) as pool:
            first=pool.submit(self.prop,'/Phone/')
            self.assertTrue(self.source.entered.wait(1))
            waiting=pool.submit(self.prop,'/Phone/')
            # Wait for both admission permits, without blocking the active call.
            deadline=time.monotonic()+1
            while self.provider._slots._value != 0 and time.monotonic()<deadline: time.sleep(.005)
            self.assertEqual(self.prop('/Phone/').status,503)
            self.provider.invalidate()
            self.assertEqual(first.result(timeout=1).status,503)
            self.assertEqual(waiting.result(timeout=1).status,503)
        self.assertEqual(self.source.peak,1)
    def test_queue_timeout_and_per_request_cancellation(self):
        provider=MTPMetadataProvider(self.source.exchange,self.source.interrupt,queue_timeout=.05)
        held=threading.Event(); release=threading.Event()
        def hold():
            with provider.request_scope(): held.set(); release.wait(1)
        thread=threading.Thread(target=hold); thread.start(); self.assertTrue(held.wait(1))
        try:
            with self.assertRaises(w.Failure):
                with provider.request_scope(): self.fail('must time out')
            cancel=w.Cancel(); cancel.cancel()
            with self.assertRaises(w.Failure):
                with provider.request_scope(cancel): self.fail('must cancel')
        finally: release.set(); thread.join(1)
        with provider.request_scope(): pass
    def test_reply_mismatch_and_oversize_fail_closed(self):
        for exchange in (lambda _: b'x'*(1024*1024+1),lambda _: b'{}'):
            with self.assertRaises(w.Failure): MTPMetadataProvider(exchange)

    def test_handler_cancellation_stops_before_next_batch(self):
        cancel=w.Cancel(); original=self.source.exchange
        self.source.partial=True
        def exchange(raw):
            reply=original(raw)
            if json.loads(raw)['operation']=='directory': cancel.cancel()
            return reply
        self.provider.exchange=exchange
        response=self.handler.handle(w.Request('PROPFIND','/Phone/',{'depth':'1'}),cancel)
        self.assertEqual(response.status,503); self.assertEqual(response.body,b'')
        self.assertNotIn('nextPage',self.source.calls)

    def test_missing_entry_field_fails_closed(self):
        del self.source.root_entries[0]['format']
        self.assertEqual(self.prop('/Phone/').status,503)
        self.assertEqual(self.prop().status,503)

class ReadClassificationRegression(unittest.TestCase):
    def test_explicit_cancellation_after_128k_keeps_original_length(self):
        provider=w.SyntheticProvider(); handler=w.Handler(provider,provider); cancel=w.Cancel()
        def stop(sink,data):
            if len(sink.writes)==2: cancel.cancel()
        result=w.send(handler,handler.handle(w.Request('GET','/Phone/integrity.bin')),Sink(on_write=stop),cancel)
        self.assertFalse(result.complete); self.assertEqual(result.sent,131072)
        self.assertEqual(result.failure,'cancelled')
        self.assertEqual(result.headers['Content-Length'],'196625')

    def test_broken_pipe_after_128k_is_not_a_successful_bounded_read(self):
        provider=w.SyntheticProvider(); handler=w.Handler(provider,provider)
        class BrokenSink(Sink):
            def write(self,data):
                if len(self.writes)>=3: raise BrokenPipeError()
                return super().write(data)
        sink=BrokenSink(); events=[]
        reason=w.serve_connection(handler,io.BytesIO(b'GET /Phone/integrity.bin HTTP/1.1\r\nHost: 127.0.0.1:18765\r\n\r\n'),sink,log=events.append)
        event=next(e for e in events if e['event']=='request')
        self.assertEqual((event['sent'],event['status'],event['failure']),(131072,200,'BrokenPipeError'))
        self.assertEqual(event['response_headers']['Content-Length'],'196625')
        self.assertIsNone(event['range']); self.assertFalse(event['complete'])
        self.assertEqual(reason,'response_incomplete'); self.assertIsNone(provider.fault_at)
    def test_same_128k_count_can_be_valid_range_or_injected_failure(self):
        for bounded in (True,False):
            provider=w.SyntheticProvider(); handler=w.Handler(provider,provider)
            if not bounded: provider.fault_at=131072
            response=handler.handle(w.Request('GET','/Phone/integrity.bin',{'range':'bytes=0-131071'} if bounded else {}))
            result=w.send(handler,response,Sink())
            self.assertEqual(result.sent,131072)
            self.assertEqual(result.complete,bounded)
            self.assertEqual(result.status,206 if bounded else 200)
            self.assertEqual(result.failure,None if bounded else 'source byte count')
