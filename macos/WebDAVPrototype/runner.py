#!/usr/bin/env python3
"""Prepared synthetic-only runner. --serve requires separate authorization.
Default invocation prints limits and exits WITHOUT creating any socket.
"""
import argparse
import json
import socket
import threading
import time
from pathlib import Path
from webdav import Handler, SyntheticProvider, Cancel, serve_connection

ADDRESS, PORT = '127.0.0.1', 18765
LIFETIME, CONNECTIONS, ACTIVE, REQUESTS = 180, 64, 8, 32
LOG_CAP = 65536

class BoundedLog:
    def __init__(self, path, cancel):
        self.file = open(path, 'xb'); self.size = 0; self.lock = threading.Lock(); self.cancel = cancel
        self.limit_reached = False
    def __call__(self, event):
        wire = (json.dumps({'time':time.time(), **event}, ensure_ascii=True) + '\n').encode()
        with self.lock:
            if self.size + len(wire) > LOG_CAP:
                self.limit_reached = True
                self.cancel.cancel(); return
            self.file.write(wire); self.file.flush(); self.size += len(wire)
    def close(self): self.file.close()

class SocketSink:
    def __init__(self, connection): self.connection = connection
    def write(self, data): return self.connection.send(data)
    def flush(self): pass
    def abort(self):
        import socket
        try: self.connection.shutdown(socket.SHUT_RDWR)
        except OSError: pass
        self.connection.close()


class ConnectionSlots:
    """Nonblocking active-connection bound with explicit worker release."""
    def __init__(self, limit): self._permits = threading.BoundedSemaphore(limit)
    def acquire(self, blocking=False): return self._permits.acquire(blocking=blocking)
    def release(self): self._permits.release()


class ObservedSocketReader:
    """Bounded file-like reader that records arrival without exposing wire data."""
    def __init__(self, connection, log):
        self.connection = connection
        self.log = log
        self.buffer = bytearray()
        self.first_bytes_received = False

    def _receive(self, count):
        data = self.connection.recv(count)
        if data and not self.first_bytes_received:
            self.first_bytes_received = True
            self.log({'event':'first_request_bytes', 'byte_count':len(data)})
        return data

    def _take(self, count):
        data = bytes(self.buffer[:count])
        del self.buffer[:count]
        return data

    def readline(self, size=-1):
        if size == 0: return b''
        limit = size if size is not None and size >= 0 else None
        while True:
            newline = self.buffer.find(b'\n')
            if newline >= 0 and (limit is None or newline + 1 <= limit):
                return self._take(newline + 1)
            if limit is not None and len(self.buffer) >= limit:
                return self._take(limit)
            count = 4096 if limit is None else min(4096, max(1, limit - len(self.buffer)))
            data = self._receive(count)
            if not data: return self._take(len(self.buffer))
            self.buffer.extend(data)

    def read(self, size=-1):
        if size is None or size < 0:
            while True:
                data = self._receive(8192)
                if not data: return self._take(len(self.buffer))
                self.buffer.extend(data)
        while len(self.buffer) < size:
            data = self._receive(min(8192, size - len(self.buffer)))
            if not data: break
            self.buffer.extend(data)
        return self._take(min(size, len(self.buffer)))


def log_accepted(log, connection_id, peer):
    log({'event':'connection_accepted', 'connection':connection_id,
         'peer_address':peer[0], 'peer_port':peer[1], 'first_bytes_received':None})


def log_startup_error(log, stage, error):
    log({'event':'startup_error', 'stage':stage,
         'error':type(error).__name__, 'reason':str(error)[:128]})


def handle_connection(connection, connection_id, handler, cancel, log, max_requests=REQUESTS):
    def emit(event): log({'connection':connection_id, **event})
    reader = ObservedSocketReader(connection, emit)
    reason = 'worker_error'
    try:
        # HTTP/1.1 connections stay reusable unless the peer asks to close or
        # the per-connection request/idle limits are reached. Avoid turning a
        # Finder metadata burst into one accepted TCP connection per request.
        reason = serve_connection(handler, reader, SocketSink(connection), cancel, max_requests, emit,
                                  close_after_response=False)
    except OSError as error:
        reason = ('server_cancelled' if cancel.event.is_set() else
                  'socket_timeout' if isinstance(error, TimeoutError) else 'socket_error')
        emit({'event':'socket_error', 'error':type(error).__name__})
    finally:
        try: connection.close()
        except OSError: pass
        emit({'event':'connection_closed', 'reason':reason,
              'first_bytes_received':reader.first_bytes_received})
    return reason


def finish_worker(connection, connection_id, handler, cancel, log, sockets, lock, permits):
    """Run one accepted connection and release its slot on every exit path."""
    try:
        try:
            return handle_connection(connection, connection_id, handler, cancel, log)
        except Exception as error:
            log({'event':'worker_error', 'connection':connection_id,
                 'error':type(error).__name__})
            try: connection.close()
            except OSError: pass
            return 'worker_error'
    finally:
        with lock: sockets.discard(connection)
        permits.release()


def serve(log_path):
    # This is the only code path that creates sockets. No test calls it.
    import socket
    import signal
    cancel = Cancel(); log = BoundedLog(log_path, cancel)
    handler = Handler(SyntheticProvider(), None)
    handler.content = handler.metadata
    sockets, workers = set(), []
    lock, permits = threading.Lock(), ConnectionSlots(ACTIVE)
    listener = None
    stop_reason = [None]
    stop_lock = threading.Lock()
    def stop(reason):
        with stop_lock:
            if stop_reason[0] is not None: return
            stop_reason[0] = reason
        if reason == 'lifetime_timeout': log({'event':'server_timeout', 'reason':reason})
        cancel.cancel()
        if listener is not None:
            try: listener.close()
            except OSError as error:
                log({'event':'listener_close_error', 'error':type(error).__name__})
        with lock:
            for connection in list(sockets): SocketSink(connection).abort()
    def worker(connection, number):
        finish_worker(connection, number, handler, cancel, log, sockets, lock, permits)
    deadline = time.monotonic() + LIFETIME
    timer = threading.Timer(LIFETIME, stop, args=('lifetime_timeout',))
    signal.signal(signal.SIGINT, lambda signum, frame: stop('sigint'))
    signal.signal(signal.SIGTERM, lambda signum, frame: stop('sigterm'))
    stage = 'socket_create'
    accept_budget_exhausted = False
    try:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        startup_stage = 'bind'
        try:
            listener.bind((ADDRESS, PORT))
            startup_stage = 'listen'
            listener.listen(ACTIVE)
            startup_stage = 'accept_timeout'
            listener.settimeout(0.5)
        except OSError as error:
            log_startup_error(log, startup_stage, error)
            raise
        log({'event':'start', 'address':ADDRESS, 'port':PORT, 'pid':__import__('os').getpid()})
        timer.start()
        for number in range(CONNECTIONS):
            connection = None
            while not cancel.event.is_set():
                try:
                    stage = 'accept'
                    connection, peer = listener.accept(); break
                except socket.timeout: continue
                except OSError:
                    if cancel.event.is_set(): break
                    raise
            if connection is None: break
            log_accepted(log, number, peer)
            if peer[0] != ADDRESS or not permits.acquire(blocking=False):
                reason = 'peer_not_loopback' if peer[0] != ADDRESS else 'connection_limit'
                connection.close()
                log({'event':'connection_closed', 'connection':number,
                     'peer_address':peer[0], 'peer_port':peer[1], 'reason':reason,
                     'first_bytes_received':None})
                continue
            try:
                connection.settimeout(5)
                with lock: sockets.add(connection)
                stage = 'worker_start'
                thread = threading.Thread(target=worker, args=(connection, number), daemon=True)
                thread.start()
                workers.append(thread)
            except Exception as error:
                with lock: sockets.discard(connection)
                try: connection.close()
                except OSError: pass
                permits.release()
                log({'event':'connection_closed', 'connection':number,
                     'peer_address':peer[0], 'peer_port':peer[1],
                     'reason':'worker_start_error', 'first_bytes_received':None})
                log({'event':'worker_start_error', 'connection':number,
                     'error':type(error).__name__})
                raise
        else:
            accept_budget_exhausted = True
            log({'event':'accept_budget_exhausted', 'limit':CONNECTIONS})
        # Let accepted work finish, still subject to the hard timer.
        stage = 'worker_join'
        for thread in workers: thread.join(max(0, deadline-time.monotonic()))
    except BaseException as error:
        if stop_reason[0] is None:
            log({'event':'server_error', 'stage':stage,
                 'error':type(error).__name__, 'errno':getattr(error, 'errno', None)})
            stop('server_error')
        raise
    finally:
        default_reason = 'connection_budget' if accept_budget_exhausted else 'runner_exit'
        stop('log_cap' if log.limit_reached else default_reason); timer.cancel()
        cleanup_deadline = time.monotonic() + 5
        for thread in workers: thread.join(max(0, cleanup_deadline-time.monotonic()))
        log({'event':'stop', 'reason':stop_reason[0]}); log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serve', action='store_true')
    parser.add_argument('--log', type=Path)
    args = parser.parse_args()
    if not args.serve:
        print(json.dumps({'address':ADDRESS, 'port':PORT, 'lifetime':LIFETIME,
                          'connections':CONNECTIONS, 'active':ACTIVE, 'requests_per_connection':REQUESTS,
                          'log_bytes':LOG_CAP, 'listener_started':False})); return
    if args.log is None: parser.error('--log is required; the log must not already exist')
    serve(args.log)

if __name__ == '__main__': main()
