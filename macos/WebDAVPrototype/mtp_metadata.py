"""Metadata-only adapter for MTPMetadataService's v1 Codable JSON envelopes.

No socket, USB, process or listener is opened here. The embedding owner supplies
an exchange(bytes)->bytes transport and must call invalidate on disconnect,
replacement or transport loss. A transport must bound exchange time and bytes,
and its interrupt callback must abort an active exchange without waiting on it.
"""
from contextlib import contextmanager
import json
import threading
import time
import uuid
from webdav import Failure, Identity, Node, Listing, State, MAX_CHILDREN, safe_name

MAX_ENVELOPE = 1024 * 1024

class MTPMetadataProvider:
    supports_content = False

    def __init__(self, exchange, interrupt=lambda: None, *, max_pending=8,
                 max_pages=4, queue_timeout=2.0):
        if not 1 <= max_pending <= 64 or not 1 <= max_pages <= 128 or not 0 < queue_timeout <= 30:
            raise ValueError('invalid metadata bounds')
        self.exchange, self.interrupt = exchange, interrupt
        self.max_pages, self.queue_timeout = max_pages, queue_timeout
        self._slots = threading.BoundedSemaphore(max_pending)
        self._operations = threading.RLock()
        self._state = threading.RLock()
        self._local = threading.local()
        self._closed = False
        self._epoch = 0
        self._session = None
        self._sequence = 0
        self._snapshot = None
        self._nodes, self._routes = {}, {}
        with self._operations:
            self._call('initialize')

    def invalidate(self):
        # Never wait for a transaction or a blocked HTTP writer to revoke metadata.
        with self._state:
            self._closed = True
            self._epoch += 1
            self._nodes.clear(); self._routes.clear(); self._snapshot = None
        self.interrupt()

    cancel = invalidate

    @contextmanager
    def request_scope(self, cancel=None):
        """One complete resolve/enumerate operation owns the mutable MTP cursor.

        At most max_pending callers (active + waiting). Queue waits are timed and
        cancellable. In-flight cancellation requires transport interruption by owner.
        """
        if getattr(self._local, 'active', False):
            yield
            return
        if not self._slots.acquire(blocking=False): raise Failure(503, 'metadata queue full')
        acquired = False
        try:
            deadline = time.monotonic() + self.queue_timeout
            with self._state: ticket = self._epoch
            while not acquired:
                if cancel: cancel.check()
                with self._state:
                    if self._closed or ticket != self._epoch: raise Failure(503, 'metadata invalidated')
                remaining = deadline - time.monotonic()
                if remaining <= 0: raise Failure(503, 'metadata queue timeout')
                acquired = self._operations.acquire(timeout=min(0.02, remaining))
            if cancel: cancel.check()
            with self._state:
                if self._closed or ticket != self._epoch: raise Failure(503, 'metadata invalidated')
            self._local.active = True
            self._local.cancel = cancel
            self._call('storages')  # authoritative state, no discovery or hidden refresh
            yield
            if cancel: cancel.check()
        finally:
            self._local.active = False
            self._local.cancel = None
            if acquired: self._operations.release()
            self._slots.release()

    def _call(self, operation, **arguments):
        cancel = getattr(self._local, 'cancel', None)
        if cancel: cancel.check()
        with self._state:
            if self._closed: raise Failure(503, 'metadata disconnected')
            epoch = self._epoch
            request = dict(version=1, id=str(uuid.uuid4()), sequence=self._sequence,
                           operation=operation, path=[])
            request.update(arguments)
            if self._session:
                self._sequence += 1
                request.update(sequence=self._sequence, session=self._session,
                               generation=self._snapshot['generation'], namespace=self._snapshot['namespace'])
        try:
            raw = self.exchange(json.dumps(request).encode())
            if cancel: cancel.check()
            if not isinstance(raw, bytes) or len(raw) > MAX_ENVELOPE: raise ValueError('envelope cap')
            reply = json.loads(raw)
            if (reply.get('version') != 1 or uuid.UUID(reply.get('id', '')) != uuid.UUID(request['id']) or
                    reply.get('sequence') != request['sequence']): raise ValueError('reply identity')
            session = str(uuid.UUID(reply['session']))
            if self._session and session.lower() != self._session.lower(): raise ValueError('replaced session')
            if reply.get('error'):
                if reply['error'] in ('unavailable', 'busy'): raise Failure(503, reply['error'])
                raise ValueError(reply['error'])
            snapshot = reply['snapshot']
            self._validate(snapshot)
            with self._state:
                if self._closed or epoch != self._epoch: raise Failure(503, 'metadata invalidated')
                previous = self._snapshot
                changed = previous and any(snapshot[k] != previous[k] for k in ('generation', 'namespace'))
                if changed:
                    self._epoch += 1; self._nodes.clear(); self._routes.clear()
                    if operation != 'refresh': raise ValueError('stale namespace')
                self._session, self._snapshot = session, snapshot
            return snapshot
        except Failure:
            raise
        except Exception:
            self.invalidate()
            raise Failure(503, 'metadata transport or identity failure') from None

    @staticmethod
    def _validate(s):
        uuid.UUID(s['generation']); uuid.UUID(s['namespace'])
        if s['storageState'] not in ('available', 'emptySuccess', 'deviceUnavailable', 'transportFailure', 'disconnected', 'cancelled'):
            raise ValueError('storage state')
        if not isinstance(s['state'], dict) or len(s['state']) != 1: raise ValueError('snapshot state')
        if next(iter(s['state'])) not in ('available','empty','partial','complete','failed','disconnected','cancelled'):
            raise ValueError('snapshot state')
        if len(s['storages']) > 16 or len(s['entries']) > 4096: raise ValueError('snapshot cap')
        seen = set()
        for storage in s['storages']:
            sid = storage['id']
            if type(sid) is not int or not 0 < sid < 0xffffffff or sid in seen: raise ValueError('storage identity')
            if storage['generation'] != s['generation']: raise ValueError('storage generation')
            safe_name(storage['name']); seen.add(sid)
        for entry in s['entries']:
            required = ('generation', 'storage', 'handle', 'parent', 'name', 'isDirectory', 'format')
            if not isinstance(entry, dict) or any(k not in entry for k in required):
                raise ValueError('entry schema')

    def _available(self):
        with self._state:
            if self._closed or self._snapshot is None: raise Failure(503, 'metadata disconnected')
            s = self._snapshot
            if s['storageState'] != 'available': raise Failure(503, s['storageState'])
            if next(iter(s['state'])) in ('failed', 'disconnected', 'cancelled', 'empty'):
                raise Failure(503, 'metadata unavailable')
            return s

    def root(self):
        with self._state:
            s = self._available()
            node = Node(Identity(s['generation'], s['namespace'], 0, 0), 'Android', True)
            self._nodes[node.identity] = node; self._routes[node.identity] = ()
            return node

    def current(self, node):
        with self._state:
            try: s = self._available()
            except Failure: return False
            return (node.identity.generation == s['generation'] and node.identity.namespace == s['namespace']
                    and (node.identity.storage == 0 or any(x['id'] == node.identity.storage for x in s['storages']))
                    and self._nodes.get(node.identity) == node)

    def validate_response(self, nodes):
        with self.request_scope():
            if not all(self.current(n) for n in nodes): raise Failure(409, 'stale metadata response')

    def refresh(self):
        # Explicit caller action only; revokes cached responses before the transaction.
        with self.request_scope():
            with self._state:
                self._epoch += 1; self._nodes.clear(); self._routes.clear()
            return self._call('refresh')

    def children(self, node):
        with self.request_scope():
            if not self.current(node): raise Failure(409, 'stale identity')
            s = self._available()
            if node.identity.storage == 0:
                if not s['storages']: raise Failure(503, 'no available storage')
                entries = [Node(Identity(s['generation'], s['namespace'], x['id'], 0), x['name'], True)
                           for x in s['storages']]
                routes = {n.identity: () for n in entries}
            else:
                route = self._routes[node.identity]
                path = [dict(generation=i.generation, storage=i.storage, handle=i.handle) for i in route]
                s = self._call('directory', storage=node.identity.storage, path=path)
                for _ in range(self.max_pages - 1):
                    if next(iter(s['state'])) != 'partial': break
                    if len(s['entries']) > MAX_CHILDREN: raise Failure(507, 'directory cap')
                    s = self._call('nextPage')  # explicit bounded continuation; snapshots are cumulative
                if s['storageState'] != 'available' or next(iter(s['state'])) != 'complete':
                    raise Failure(503, 'incomplete or unavailable directory')
                if len(s['entries']) > MAX_CHILDREN: raise Failure(507, 'directory cap')
                if (s.get('directoryStorage') != node.identity.storage or
                        s.get('directoryHandle') != node.identity.handle): raise Failure(409, 'directory identity')
                entries, routes, seen = [], {}, set()
                for e in s['entries']:
                    if (e['generation'] != node.identity.generation or e['storage'] != node.identity.storage or
                            e['parent'] != node.identity.handle or type(e['handle']) is not int or
                            not 0 < e['handle'] < 0xffffffff or e['handle'] in seen):
                        raise Failure(409, 'entry identity')
                    if type(e['isDirectory']) is not bool: raise Failure(502, 'entry kind')
                    if type(e['format']) is not int or not 0 <= e['format'] <= 0xffff: raise Failure(502, 'entry format')
                    size = e.get('size')
                    if size is not None and (type(size) is not int or not 0 <= size <= 0xffffffffffffffff):
                        raise Failure(502, 'entry size')
                    safe_name(e['name']); seen.add(e['handle'])
                    child = Node(Identity(s['generation'], s['namespace'], e['storage'], e['handle']),
                                 e['name'], e['isDirectory'], None if e['isDirectory'] else size, format=e['format'])
                    entries.append(child); routes[child.identity] = route + (child.identity,)
            with self._state:
                if not self.current(node): raise Failure(409, 'invalidated listing')
                # Revoke previously learned descendants on each complete relisting.
                parent_route = self._routes[node.identity]
                obsolete = [i for i, r in self._routes.items() if i != node.identity and
                            (node.identity.storage == 0 or (i.storage == node.identity.storage and
                             len(r) > len(parent_route) and r[:len(parent_route)] == parent_route))]
                # Storage-root identities have empty routes; keep unrelated storages.
                for i in obsolete: self._nodes.pop(i, None); self._routes.pop(i, None)
                if len(self._nodes) + len(entries) > 2048: raise Failure(507, 'metadata cache cap')
                self._nodes.update({n.identity: n for n in entries}); self._routes.update(routes)
            return Listing(State.COMPLETE, tuple(entries))
