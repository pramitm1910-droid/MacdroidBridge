# Synthetic read-only WebDAV core

This is a Python standard-library protocol prototype, not a file-manager application. It imports no MTP/USB implementation. `webdav.py` has a transport-independent handler and connection loop. `runner.py` is a separately gated future loopback launcher; **do not run `--serve` without new authorization**. Default invocation prints limits and exits without creating sockets.

Run only the offline verification now:

```sh
python3 macos/WebDAVPrototype/verify.py
```

The verifier runs socket-guarded unit tests, compiles Python modules, builds an unsigned executable zipapp, runs its non-serving default, and exercises separate client/oracle processes over captured HTTP bytes. Evidence is saved under `mtp-storage-investigation/webdav-prototype-01/`.

`MetadataProvider` is the future integration seam for `MTPFolderBrowser` / `MTPMetadataSource`: map snapshot generation and namespace plus storage and handle into `Identity`; map complete directory results and explicit empty success to `Listing`; map partial, unavailable, disconnected, failed or cancelled sources to refusal. The provider must preserve parent-child scope, thread safety, identity validity and known sizes. No Swift/Python transport or live MTP adapter is implemented here. Never implement `ContentProvider` by fabricating bytes from metadata. Content delivery additionally requires a separately verified read backend; the shipped byte oracle is synthetic only.

Every path resolution uses bounded immediate-child enumeration, with no metadata cache. Paths are decoded once and checked for traversal; duplicates receive storage/handle suffixes. Each request resolves at most 16 components, each listing at most 128 entries. Incomplete collections cannot be published, even at Depth 0. Directory XML is capped at 256 KiB; known synthetic bodies at 8 MiB; content reads at 64 KiB. Unknown-size or metadata-only nodes have no downloadable representation (GET/HEAD 503).

OPTIONS returns 200, `DAV: 1` for the read-only basic DAV interface, the exact permitted methods, zero Content-Length and persistent HTTP/1.1 framing. No locking/class 2/class 3 or Microsoft authoring capability is advertised. Mutations are denied by read-only policy with 403; other unsupported methods receive 405. PROPFIND handles allprop, propname and requested properties (unknown properties 404 within 207), UTF-8/UTF-16 XML and Depth 0/1. Infinity, including omitted Depth, is refused with the DAV finite-depth condition. This is a tested minimum profile, not a comprehensive RFC certification or evidence of Finder compatibility.

Response bodies use Content-Length, never Transfer-Encoding. HEAD has the full GET length but no body; single byte ranges support suffix/open-ended/clamped bounds. Invalid, unsatisfiable or multiple ranges receive 416 under the single-range policy. If-Range is conservatively served as a full response. HTTP request parsing caps line/header/body/chunk counts, rejects ambiguous framing and duplicate headers, supports bounded chunked bodies, and refuses Expect with 417. Chunk extensions/trailers are not supported. The future runner requires the exact Host authority `127.0.0.1:18765`.

Each content chunk is checked against a trusted synthetic digest and exact length before emission. A first-chunk failure produces an error before success headers. Later failure, cancellation, invalidation or sink error aborts the connection without a second response or success publication. Synchronous bounded writes provide backpressure. The server's `complete` field means its sink accepted the expected bytes, **not** that the client saved the correct file.

`receive.py` uses Python's independent HTTP parser; its deliberately unchecked chunk-reading mode demonstrates silent truncation. `oracle.py` independently checks byte count and SHA-256 using a different fixture construction. Same-length wire corruption also bypasses HTTP length checks. Both client-integrity gaps are explicitly retained in evidence. Always verify received files independently; real Android reads remain disconnected.

