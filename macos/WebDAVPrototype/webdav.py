"""Bounded, metadata-provider WebDAV core. Importing this module opens no sockets.

The only content provider shipped here generates explicitly synthetic fixtures.
A future MTP adapter must implement MetadataProvider with complete snapshots and
ContentProvider independently; it must not derive bytes from metadata or sizes.
"""
from dataclasses import dataclass, field, replace
from enum import Enum
from typing import Protocol
from urllib.parse import quote, unquote_to_bytes
from xml.etree import ElementTree as ET
import hashlib
import re
import threading
import uuid
from collections import deque
from contextlib import nullcontext
from email.utils import formatdate
from http import HTTPStatus

CHUNK = 65536
MAX_RESPONSE = 8 * 1024 * 1024
MAX_XML = 256 * 1024
MAX_CHILDREN = 128
MAX_REQUEST = 32768
MAX_HEADERS = 16384
ALLOW = 'OPTIONS, PROPFIND, HEAD, GET'
MUTATING = {'PUT','POST','PATCH','DELETE','COPY','MOVE','MKCOL','PROPPATCH','LOCK','UNLOCK'}
DAV = '{DAV:}'
ET.register_namespace('D', 'DAV:')
TOKEN = re.compile(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")

class Failure(Exception):
    def __init__(self, status=503, reason='unavailable', headers=None, body=b''):
        self.status, self.reason, self.headers, self.body = status, reason, headers or {}, body

class State(Enum):
    COMPLETE = 'complete'
    EMPTY_SUCCESS = 'emptySuccess'
    PARTIAL = 'partial'
    DEVICE_UNAVAILABLE = 'deviceUnavailable'

@dataclass(frozen=True)
class Identity:
    generation: str
    namespace: str
    storage: int
    handle: int

@dataclass(frozen=True)
class Node:
    identity: Identity
    name: str
    directory: bool
    size: int | None = None
    content_key: str | None = None  # Only a verified content provider can resolve this.
    modified: str | None = None
    format: int | None = None  # Known MTP format, not a guessed MIME type or content capability.

@dataclass(frozen=True)
class Listing:
    state: State
    entries: tuple[Node, ...] = ()

class MetadataProvider(Protocol):
    def root(self) -> Node: ...
    def current(self, node: Node) -> bool: ...
    def children(self, node: Node) -> Listing: ...

class ContentProvider(Protocol):
    def read(self, node: Node, offset: int, count: int) -> bytes: ...
    def digest(self, node: Node, offset: int, count: int) -> str: ...
    # digest is a trusted synthetic oracle, not a claim that MTP supplies hashes.

class Cancel:
    def __init__(self): self.event = threading.Event()
    def check(self):
        if self.event.is_set(): raise Failure(503, 'cancelled')
    def cancel(self): self.event.set()

# Independent oracle algorithm in oracle.py uses a different construction.
def fixture_bytes(offset, count):
    return bytes(((i * 31 + 7) % 251) for i in range(offset, offset + count))

class SyntheticProvider:
    """Small Android-style metadata fixture; no device or filesystem content access."""
    def __init__(self):
        self.generation, self.namespace = str(uuid.uuid4()), str(uuid.uuid4())
        self.states = {}
        self.reads = deque(maxlen=128)
        self.metadata_reads = 0
        self.fault_at = None
        self.fault = 'short'
        self._make_tree()

    def _make_tree(self):
        def node(handle, name, directory=False, size=None, key=None):
            return Node(Identity(self.generation, self.namespace, 77, handle), name, directory, size, key, 'Wed, 28 Oct 2026 00:00:00 GMT')
        self.nodes = {
            0: node(0, 'Android synthetic', True),
            1: node(1, 'Phone', True),
            2: node(2, '写真 & Notes', True),
            3: node(3, 'integrity.bin', size=CHUNK * 3 + 17, key='pattern'),
            4: node(4, 'empty.bin', size=0, key='pattern'),
            5: node(5, 'Résumé <&>.txt', size=257, key='pattern'),
            6: node(6, 'duplicate.txt', size=17, key='pattern'),
            7: node(7, 'duplicate.txt', size=31, key='pattern'),
            8: node(8, 'metadata-only.bin'),
        }
        self.tree = {0: (1,), 1: (2, 3, 4, 6, 7, 8), 2: (5,)}

    def root(self): return self.nodes[0]
    def current(self, node):
        return (node.identity.generation == self.generation and node.identity.namespace == self.namespace
                and self.nodes.get(node.identity.handle) == node)
    def invalidate(self):
        self.namespace = str(uuid.uuid4()); self._make_tree()
    def children(self, node):
        if not self.current(node): raise Failure(409, 'stale identity')
        self.metadata_reads += 1
        entries = tuple(self.nodes[h] for h in self.tree.get(node.identity.handle, ()))
        state = self.states.get(node.identity.handle, State.COMPLETE if entries else State.EMPTY_SUCCESS)
        return Listing(state, entries)
    def digest(self, node, offset, count):
        return hashlib.sha256(fixture_bytes(offset, count)).hexdigest()
    def read(self, node, offset, count):
        if not self.current(node): raise Failure(409, 'stale identity')
        if node.content_key != 'pattern' or node.size is None: raise Failure()
        if not 0 <= count <= CHUNK or offset < 0 or offset > node.size: raise Failure(500, 'invalid read')
        self.reads.append((offset, count))
        result = fixture_bytes(offset, min(count, node.size - offset))
        if self.fault_at is not None and offset >= self.fault_at:
            if self.fault == 'raise': raise Failure(502, 'synthetic source failed')
            if self.fault == 'short': return result[:-1]
            if self.fault == 'corrupt': return bytes([result[0] ^ 1]) + result[1:] if result else b'x'
            if self.fault == 'extra': return result + b'x'
        return result


def safe_name(name):
    if (not name or name in ('.', '..') or '/' in name or '\\' in name or
            len(name.encode('utf-8')) > 255 or any(ord(c) < 32 or ord(c) == 127 or
            0xD800 <= ord(c) <= 0xDFFF or ord(c) in (0xFFFE, 0xFFFF) for c in name)):
        raise Failure(502, 'unsafe metadata name')
    return name


def path_parts(target):
    if not target.startswith('/') or target.startswith('//') or '?' in target or '#' in target:
        raise Failure(400, 'invalid target')
    if re.search(r'%(?![0-9a-fA-F]{2})', target): raise Failure(400, 'invalid escape')
    raw = target[1:].removesuffix('/')
    if not raw: return ()
    parts = []
    for part in raw.split('/'):
        try: name = unquote_to_bytes(part).decode('utf-8', 'strict')
        except UnicodeError: raise Failure(400, 'invalid UTF-8')
        try: parts.append(safe_name(name))
        except Failure: raise Failure(400, 'invalid path')
    if len(parts) > 16: raise Failure(414, 'path depth cap')
    return tuple(parts)


def href(parts, directory):
    value = '/' + '/'.join(quote(p, safe='') for p in parts)
    return value + ('/' if directory and parts else '')


def complete_children(provider, node):
    listing = provider.children(node)
    if not provider.current(node): raise Failure(409, 'stale identity')
    if listing.state not in (State.COMPLETE, State.EMPTY_SUCCESS): raise Failure(503, listing.state.value)
    if listing.state == State.EMPTY_SUCCESS and listing.entries: raise Failure(502, 'invalid empty success')
    if len(listing.entries) > MAX_CHILDREN: raise Failure(507, 'directory cap')
    names, identities = {}, set()
    for entry in listing.entries:
        safe_name(entry.name)
        if entry.size is not None and (not isinstance(entry.size, int) or entry.size < 0):
            raise Failure(502, 'invalid metadata size')
        if (not provider.current(entry) or entry.identity.generation != node.identity.generation or
                entry.identity.namespace != node.identity.namespace or entry.identity in identities):
            raise Failure(409, 'stale or duplicate identity')
        identities.add(entry.identity)
        names.setdefault(entry.name, []).append(entry)
    used = {name for name, entries in names.items() if len(entries) == 1}
    result = []
    for entry in listing.entries:
        display = entry.name
        if len(names[display]) > 1:
            stem = f'{display} [MTP-{entry.identity.storage:x}-{entry.identity.handle:x}]'
            display, suffix = stem, 2
            while display in used:
                display = f'{stem} ({suffix})'; suffix += 1
        used.add(display); safe_name(display)
        result.append((display, entry))
    return result

@dataclass
class Request:
    method: str
    target: str
    headers: dict = field(default_factory=dict)
    body: bytes = b''
    close: bool = False


def _log_target(target):
    path, separator, _ = target.partition('?')
    target = path + ('?<redacted>' if separator else '')
    if '://' in target:
        scheme, rest = target.split('://', 1)
        authority, slash, suffix = rest.partition('/')
        if '@' in authority: authority = '<redacted>@' + authority.rsplit('@', 1)[1]
        target = scheme + '://' + authority + (slash + suffix if slash else '')
    if '#' in target:
        target = target.split('#', 1)[0] + '#<redacted>'
    target = re.sub(r'(?i)\b(password|passwd|access[_-]?token|token|api[_-]?key|secret)(\s*[=:]\s*|/)[^/?#&\s]+',
                    lambda match: match.group(1) + match.group(2) + '<redacted>', target)
    return target[:1024]


def _log_user_agent(value):
    value = re.sub(r'(?i)\b(Bearer|Basic)\s+\S+', r'\1 <redacted>', value)
    return re.sub(r'(?i)\b(password|passwd|access[_-]?token|token|api[_-]?key|secret)(\s*[=:]\s*)[^&#;\s]+',
                  lambda match: match.group(1) + match.group(2) + '<redacted>', value)[:512]


def read_request(stream, expected_host='127.0.0.1:18765', on_request_line=None, on_authorization=None):
    """Bounded HTTP/1.1 parser. No TE/CL ambiguity, folding or duplicate fields."""
    def report_line(parsed, reason=None, method=None, target=None):
        if on_request_line is not None:
            event = {'parsed':parsed}
            if reason is not None: event['reason'] = reason
            if method is not None: event['method'] = method
            if target is not None: event['target'] = _log_target(target)
            on_request_line(event)

    def reject_line(reason):
        report_line(False, reason=reason)
        raise Failure(400, reason)

    line = stream.readline(4097)
    if not line: return None
    if len(line) > 4096 or not line.endswith(b'\r\n'): reject_line('request line')
    try: method, target, version = line[:-2].decode('ascii').split(' ')
    except (ValueError, UnicodeError): reject_line('request line')
    if not TOKEN.fullmatch(method) or version != 'HTTP/1.1': reject_line('HTTP/1.1 required')
    report_line(True, method=method, target=target)
    headers, total = {}, len(line)
    for _ in range(65):
        line = stream.readline(MAX_HEADERS + 1); total += len(line)
        if total > MAX_HEADERS: raise Failure(431, 'header cap')
        if line == b'\r\n': break
        if not line or not line.endswith(b'\r\n') or line[:1] in (b' ', b'\t'): raise Failure(400, 'header framing')
        try: name, value = line[:-2].decode('ascii').split(':', 1)
        except (ValueError, UnicodeError): raise Failure(400, 'header encoding')
        if not TOKEN.fullmatch(name) or any(ord(c) < 32 and c != '\t' or ord(c) == 127 for c in value):
            raise Failure(400, 'header syntax')
        name = name.lower()
        if name in headers: raise Failure(400, 'duplicate header')
        headers[name] = value.strip()
    else: raise Failure(431, 'header count')
    if on_authorization is not None: on_authorization('authorization' in headers)
    if headers.get('host') != expected_host: raise Failure(400, 'host not allowed')
    if 'expect' in headers: raise Failure(417, 'expectation unsupported')
    body = b''
    if 'transfer-encoding' in headers:
        if 'content-length' in headers or headers['transfer-encoding'].lower() != 'chunked':
            raise Failure(400, 'ambiguous transfer framing')
        chunks = []
        for _ in range(1024):
            size_line = stream.readline(128)
            if not re.fullmatch(rb'[0-9A-Fa-f]{1,8}\r\n', size_line): raise Failure(400, 'chunk framing')
            size = int(size_line, 16)
            if size == 0:
                if stream.readline(3) != b'\r\n': raise Failure(400, 'trailers unsupported')
                break
            if sum(map(len, chunks)) + size > MAX_REQUEST: raise Failure(413, 'body cap')
            chunk = stream.read(size)
            if len(chunk) != size or stream.read(2) != b'\r\n': raise Failure(400, 'incomplete chunk')
            chunks.append(chunk)
        else: raise Failure(413, 'chunk count')
        body = b''.join(chunks)
    else:
        length = headers.get('content-length', '0')
        if not re.fullmatch(r'[0-9]{1,10}', length): raise Failure(400, 'content length')
        length = int(length)
        if length > MAX_REQUEST: raise Failure(413, 'body cap')
        body = stream.read(length)
        if len(body) != length: raise Failure(400, 'incomplete request')
    if method not in MUTATING and method != 'PROPFIND' and body: raise Failure(400, 'unexpected body')
    return Request(method, target, headers, body, 'close' in [v.strip() for v in headers.get('connection', '').lower().split(',')])


def byte_range(value, size):
    if not value: return 0, size, False
    match = re.fullmatch(r'bytes=([0-9]{0,20})-([0-9]{0,20})', value)
    if not match or size == 0: raise Failure(416, 'range', {'Content-Range': f'bytes */{size}'})
    start, end = match.groups()
    if not start:
        count = int(end or '0')
        if count == 0: raise Failure(416, 'range', {'Content-Range': f'bytes */{size}'})
        offset = max(0, size - count); return offset, size - offset, True
    offset, last = int(start), int(end) if end else size - 1
    if offset >= size or last < offset: raise Failure(416, 'range', {'Content-Range': f'bytes */{size}'})
    return offset, min(last, size - 1) - offset + 1, True


def prop_request(body):
    if not body: return 'allprop', []
    try:
        # XML's UTF-8 and UTF-16 encodings are supported, but DTDs/entities are not.
        encoding = 'utf-16' if body.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8'
        text = body.decode(encoding)
        if '<!DOCTYPE' in text.upper() or '<!ENTITY' in text.upper(): raise ValueError()
        root = ET.fromstring(text)
    except (ValueError, UnicodeError, ET.ParseError): raise Failure(400, 'invalid XML')
    if root.tag != DAV + 'propfind': raise Failure(400, 'propfind required')
    modes = [c for c in root if c.tag in (DAV+'prop', DAV+'allprop', DAV+'propname')]
    if len(modes) != 1: raise Failure(400, 'one property selection required')
    mode = modes[0].tag.removeprefix(DAV)
    requested = [c.tag for c in modes[0]] if mode == 'prop' else []
    if mode == 'allprop':
        requested = [c.tag for include in root if include.tag == DAV+'include' for c in include]
    if len(requested) > 64: raise Failure(413, 'property cap')
    return mode, requested

@dataclass
class Response:
    status: int
    headers: dict = field(default_factory=dict)
    body: bytes = b''
    node: Node | None = None
    offset: int = 0
    count: int = 0
    head: bool = False
    validate: object = None  # Metadata-only reply lease; no content provider involved.

class Handler:
    def __init__(self, metadata: MetadataProvider, content: ContentProvider):
        self.metadata, self.content = metadata, content
    def resolve(self, parts):
        node = self.metadata.root()
        for part in parts:
            if not node.directory: raise Failure(404, 'not found')
            matches = [entry for name, entry in complete_children(self.metadata, node) if name == part]
            if len(matches) != 1: raise Failure(404, 'not found')
            node = matches[0]
        if not self.metadata.current(node): raise Failure(409, 'stale identity')
        return node
    def handle(self, request, cancel=None):
        try:
            scope = getattr(self.metadata, 'request_scope', None)
            with scope(cancel) if scope else nullcontext(): return self._handle(request)
        except Failure as error:
            return Response(error.status, error.headers, error.body, head=request.method == 'HEAD')
    def _handle(self, request):
        if request.method in MUTATING: raise Failure(403, 'read-only policy')
        metadata_only = getattr(self.metadata, 'supports_content', True) is False
        if metadata_only and request.method in ('GET', 'HEAD'):
            raise Failure(503, 'MTP content disabled', {'Allow': 'OPTIONS, PROPFIND'})
        if request.method == 'OPTIONS' and request.target == '*':
            return Response(200, {'Allow': 'OPTIONS, PROPFIND' if metadata_only else ALLOW, 'DAV': '1'})
        parts = path_parts(request.target)
        node = self.resolve(parts)
        if request.target.endswith('/') and parts and not node.directory: raise Failure(404, 'not collection')
        allowed = 'OPTIONS, PROPFIND' if node.directory or node.content_key is None or node.size is None else ALLOW
        if request.method not in ALLOW.split(', '): raise Failure(405, 'unsupported method', {'Allow': allowed})
        if request.method == 'OPTIONS':
            return Response(200, {'Allow': allowed, 'DAV': '1'})
        if request.method == 'PROPFIND':
            depth = request.headers.get('depth', 'infinity')
            if depth == 'infinity':
                raise Failure(403, 'finite depth only', {'Content-Type': 'application/xml; charset=utf-8'},
                              b'<D:error xmlns:D="DAV:"><D:propfind-finite-depth/></D:error>')
            if depth not in ('0', '1'): raise Failure(400, 'depth')
            mode, requested = prop_request(request.body)
            entries = [(parts, node, parts[-1] if parts else node.name)]
            if node.directory:
                children = complete_children(self.metadata, node) # Even Depth 0 rejects unavailable/partial collections.
                if depth == '1': entries += [(parts+(name,), child, name) for name, child in children]
            root = ET.Element(DAV+'multistatus')
            for path, item, name in entries:
                response = ET.SubElement(root, DAV+'response')
                ET.SubElement(response, DAV+'href').text = href(path, item.directory)
                props = {DAV+'displayname': name, DAV+'resourcetype': None}
                if item.modified is not None: props[DAV+'getlastmodified'] = item.modified
                if not item.directory:
                    props[DAV+'getcontenttype'] = 'application/octet-stream'
                    if item.size is not None: props[DAV+'getcontentlength'] = str(item.size)
                keys = list(props) + [k for k in requested if k not in props] if mode != 'prop' else requested
                for found in (True, False):
                    selected = [k for k in keys if (k in props) == found]
                    if not selected: continue
                    propstat = ET.SubElement(response, DAV+'propstat'); prop = ET.SubElement(propstat, DAV+'prop')
                    for key in selected:
                        element = ET.SubElement(prop, key)
                        if mode != 'propname' and found:
                            element.text = props[key]
                            if key == DAV+'resourcetype' and item.directory: ET.SubElement(element, DAV+'collection')
                    ET.SubElement(propstat, DAV+'status').text = 'HTTP/1.1 200 OK' if found else 'HTTP/1.1 404 Not Found'
            body = ET.tostring(root, encoding='utf-8', xml_declaration=True)
            if len(body) > MAX_XML: raise Failure(507, 'XML cap')
            if not all(self.metadata.current(item) for _, item, _ in entries): raise Failure(409, 'stale identity')
            validate = None
            if metadata_only:
                nodes = tuple(item for _, item, _ in entries)
                validate = lambda: self.metadata.validate_response(nodes)
            return Response(207, {'Content-Type': 'application/xml; charset=utf-8'}, body, validate=validate)
        if node.directory: raise Failure(405, 'collection content unsupported', {'Allow': 'OPTIONS, PROPFIND'})
        if node.size is None or node.content_key is None: raise Failure(503, 'metadata only')
        if not 0 <= node.size <= MAX_RESPONSE: raise Failure(503, 'content cap')
        # HEAD ignores Range, per HTTP semantics. Unsupported conditional ranges use full body.
        range_header = request.headers.get('range') if request.method == 'GET' and 'if-range' not in request.headers else None
        offset, count, ranged = byte_range(range_header, node.size)
        headers = {'Content-Type': 'application/octet-stream', 'Accept-Ranges': 'bytes', 'Content-Length': str(count)}
        if ranged: headers['Content-Range'] = f'bytes {offset}-{offset+count-1}/{node.size}'
        return Response(206 if ranged else 200, headers, node=node, offset=offset, count=count, head=request.method=='HEAD')

@dataclass
class Delivery:
    status: int
    committed: bool = False
    sent: int = 0
    complete: bool = False  # Server output only, never proof of client receipt.
    failure: str | None = None
    headers: dict = field(default_factory=dict)


def write_all(sink, data, cancel):
    view = memoryview(data)
    while view:
        cancel.check()
        written = sink.write(view)
        if written is None or not 0 < written <= len(view): raise OSError('short/invalid sink write')
        view = view[written:]


def send(handler, response, sink, cancel=None, close=False):
    """Blocking writes provide backpressure; content buffers are bounded by chunk size.

    First chunk validated before headers. No second response or success record after
    a committed transfer fails. abort() must close the transport, not append data.
    """
    cancel = cancel or Cancel()
    result = Delivery(response.status)
    def read(offset, count):
        cancel.check()
        if not handler.metadata.current(response.node): raise Failure(409, 'stale identity')
        data = handler.content.read(response.node, offset, count)
        if len(data) != count: raise Failure(502, 'source byte count')
        if hashlib.sha256(data).hexdigest() != handler.content.digest(response.node, offset, count):
            raise Failure(502, 'source digest')
        # At the representation boundary, independently require EOF before
        # committing its last chunk (or the empty response headers).
        if offset + count == response.node.size:
            if handler.content.read(response.node, response.node.size, 1) != b'':
                raise Failure(502, 'source did not reach EOF')
        cancel.check()
        if not handler.metadata.current(response.node): raise Failure(409, 'stale identity')
        return data
    try:
        cancel.check()
        if response.validate: response.validate()
        first = b''
        if response.node:
            if not handler.metadata.current(response.node): raise Failure(409, 'stale identity')
            if not response.head:
                first = read(response.offset, min(CHUNK, response.count)) # zero-count validates exact empty EOF
        headers = {'Date': formatdate(usegmt=True), 'Server': 'MacdroidSynthetic/0.1',
                   'Cache-Control': 'no-store', 'Connection': 'close' if close else 'keep-alive', **response.headers}
        headers.setdefault('Content-Length', str(len(response.body)))
        result.headers = headers.copy()
        if 'Transfer-Encoding' in headers: raise Failure(500, 'response framing')
        wire = f'HTTP/1.1 {response.status} {HTTPStatus(response.status).phrase}\r\n'
        wire += ''.join(f'{key}: {value}\r\n' for key, value in headers.items()) + '\r\n'
        result.committed = True # Any partial header write is already committed.
        write_all(sink, wire.encode('ascii'), cancel)
        if not response.head:
            if response.node:
                data = first
                del first
                while result.sent < response.count:
                    write_all(sink, data, cancel); result.sent += len(data)
                    if result.sent < response.count:
                        data = read(response.offset + result.sent, min(CHUNK, response.count-result.sent))
            else:
                if response.validate: response.validate()
                write_all(sink, response.body, cancel); result.sent = len(response.body)
        cancel.check()
        sink.flush()
        cancel.check()
        if response.node and not handler.metadata.current(response.node): raise Failure(409, 'stale identity')
        if response.validate: response.validate()
        result.complete = True
    except Exception as error:
        result.failure = error.reason if isinstance(error, Failure) else type(error).__name__
        if not result.committed and not cancel.event.is_set():
            failure = Response(error.status if isinstance(error, Failure) else 502, head=response.head)
            delivered = send(handler, failure, sink, cancel, close=True)
            result.status, result.committed, result.headers = delivered.status, delivered.committed, delivered.headers
        sink.abort() # No zero padding, length adjustment, retry, or terminating chunk.
    return result


def serve_connection(handler, source, sink, cancel=None, max_requests=32, log=lambda event: None,
                     close_after_response=False):
    """Transport-neutral connection loop, used by tests and the unlaunched runner."""
    cancel = cancel or Cancel()
    for index in range(max_requests):
        line_state = {'parsed':False}
        auth_state = {'present':None}
        def request_line_event(event):
            line_state['parsed'] = event['parsed']
            log({'event':'request_line', 'request':index, **event})
        def authorization_event(present):
            auth_state['present'] = present
            log({'event':'request_authorization', 'request':index, 'present':present})
        try: request = read_request(source, on_request_line=request_line_event,
                                    on_authorization=authorization_event)
        except (Failure, OSError) as error:
            result = send(handler, Response(error.status if isinstance(error, Failure) else 400), sink, cancel, close=True)
            reason = error.reason if isinstance(error, Failure) else type(error).__name__
            close_reason = ('server_cancelled' if cancel.event.is_set() else
                            'socket_timeout' if isinstance(error, TimeoutError) else
                            'parse_error' if isinstance(error, Failure) else 'socket_error')
            log({'event':'parse_error', 'request':index, 'status':result.status,
                 'reason':reason[:128], 'request_line_parsed':line_state['parsed'],
                 'authorization_present':auth_state['present'],
                 'first_bytes_received':getattr(source, 'first_bytes_received', False),
                 'close_reason':close_reason})
            sink.abort(); return close_reason
        if request is None:
            return 'peer_closed_without_request' if index == 0 else 'peer_closed'
        close = request.close or index == max_requests-1 or close_after_response
        result = send(handler, handler.handle(request, cancel), sink, cancel, close)
        log({'event':'request', 'request':index, 'request_line_parsed':True,
             'first_bytes_received':getattr(source, 'first_bytes_received', True),
             'method':request.method, 'target':_log_target(request.target),
             'user_agent':_log_user_agent(request.headers.get('user-agent', '')),
             'authorization_present':auth_state['present'],
             'depth':request.headers.get('depth'), 'range':request.headers.get('range'),
             'response_headers':result.headers, 'status':result.status, 'sent':result.sent,
             'complete':result.complete, 'failure':result.failure, 'close':close})
        if close or not result.complete:
            sink.abort()
            if cancel.event.is_set(): return 'server_cancelled'
            if request.close: return 'peer_requested_close'
            if close_after_response: return 'server_requested_close'
            if index == max_requests-1: return 'request_limit'
            return 'response_incomplete'
    return 'request_limit'
