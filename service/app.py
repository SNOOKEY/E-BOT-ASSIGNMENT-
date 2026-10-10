import json
import os
import signal
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
# ConfigMap is mounted here in Kubernetes. Mounted files are refreshed by the
# kubelet when the ConfigMap changes, so values follow a patch without a
# restart. Env vars remain the primary source (docker run -e, no mount).
CONFIG_DIR = os.environ.get("CONFIG_DIR", "/etc/app-config")


def setting(name, default=""):
    try:
        with open(os.path.join(CONFIG_DIR, name)) as f:
            return f.read().strip()
    except OSError:
        return os.environ.get(name, default)


class Handler(BaseHTTPRequestHandler):
    server_version = "demo"

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            # Read per request; never hardcoded.
            self._send(200, {
                "app": setting("APP_NAME"),
                "version": setting("VERSION"),
                "pod": socket.gethostname(),
            })
        elif path == "/healthz":
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stdout.flush()


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    # Graceful shutdown on SIGTERM (what Kubernetes sends).
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()