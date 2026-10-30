"""JSON lines over stdin/stdout (CONTRACT.md §7). Requests run one at a time, in order; only `cancel` is answered at
once, while another request runs (CONTRACT.md amendment "Export and import files")."""
import io
import json
import os
import queue
import sys
import threading
import traceback

from . import EngineError, api


class _Progress:
    """A request's progress callback, which also says whether the app asked to cancel the request (a method that
    can stop part way, as archive_write, asks progress.cancelled() as it goes)."""

    def __init__(self, send, rid, stop):
        self.send, self.rid, self.stop = send, rid, stop

    def __call__(self, message):
        self.send({"event": "progress", "id": self.rid, "message": message})

    def cancelled(self):
        return _key(self.rid) in self.stop


def _key(rid):
    return json.dumps(rid, sort_keys=True)


def main():
    # stdout carries protocol lines only: keep a private copy of it and send everything else
    # written to stdout (Python or C, e.g. MuPDF messages) to stderr.
    proto = io.open(os.dup(1), "w", encoding="utf-8", newline="\n")
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    lock = threading.Lock()

    def send(obj):
        with lock:
            proto.write(json.dumps(obj, ensure_ascii=False) + "\n")
            proto.flush()

    lines, waiting, stop = queue.Queue(), set(), set()

    def read():
        """Read requests as they come: `cancel` {"id": request id} is answered here, at once (cancelling: whether
        that request was waiting or running), every other line goes to the queue."""
        for raw in sys.stdin.buffer:
            line = raw.decode("utf-8", "replace").strip()
            try:
                request = json.loads(line) if line else None
            except ValueError:
                request = None
            if isinstance(request, dict) and request.get("method") == "cancel":
                target = (request.get("params") or {}).get("id") if isinstance(request.get("params"), dict) else None
                cancelling = _key(target) in waiting
                if cancelling:
                    stop.add(_key(target))
                send({"id": request.get("id"), "result": {"cancelling": cancelling}})
                continue
            if isinstance(request, dict):
                waiting.add(_key(request.get("id")))
            lines.put(line)
        lines.put(None)

    threading.Thread(target=read, daemon=True).start()
    while True:
        line = lines.get()
        if line is None:
            break
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError as e:
            send({"id": None, "error": {"message": "The request is not valid JSON: {}".format(e)}})
            continue
        rid = request.get("id") if isinstance(request, dict) else None
        try:
            if not isinstance(request, dict):
                raise EngineError("A request must be a JSON object.")
            fn = api.METHODS.get(request.get("method"))
            if fn is None:
                raise EngineError("Unknown method {!r}.".format(request.get("method")))
            params = request.get("params") or {}
            if not isinstance(params, dict):
                raise EngineError("params must be a JSON object.")
            result = fn(params, _Progress(send, rid, stop))
            send({"id": rid, "result": result})
        except EngineError as e:
            send({"id": rid, "error": {"message": str(e)}})
        except Exception as e:
            traceback.print_exc(file=sys.stderr)
            send({"id": rid, "error": {"message": "Internal error: {}: {}".format(type(e).__name__, e)}})
        finally:
            waiting.discard(_key(rid))
            stop.discard(_key(rid))
    return 0
