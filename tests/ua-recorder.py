#!/usr/bin/env python3
"""Records the User-Agent of every request it is sent, and answers 404.

Used by tests/apt-identity.bats to read off the wire what apt announces to an
archive it contacts, rather than reading back the configuration file that was
supposed to make it announce that (docs/traps.md, "Asserting the
configuration is not asserting the behaviour").

    ua-recorder.py LOGFILE [CERTFILE]

Listens on 127.0.0.1 on a port the kernel picks, prints that port on stdout as
one line, and then serves until it is killed. With CERTFILE (a PEM holding
both the key and the certificate) it speaks HTTPS instead of HTTP, which is
how the same verdict is taken for the https method of apt.

Every request appends one line to LOGFILE:

    METHOD<TAB>PATH<TAB>USER-AGENT

404 is a perfectly good answer here: apt only has to send the request for its
User-Agent to be on the wire, and a server with nothing in it keeps the test
free of fixtures.
"""

import http.server
import socketserver
import ssl
import sys


def main() -> int:
    if not 2 <= len(sys.argv) <= 3:
        print(__doc__, file=sys.stderr)
        return 2

    log = open(sys.argv[1], "a", buffering=1, encoding="utf-8")

    class Handler(http.server.BaseHTTPRequestHandler):
        # HTTP/1.0 so every request stands alone and nothing is held open
        protocol_version = "HTTP/1.0"

        def _record(self) -> None:
            log.write(
                "%s\t%s\t%s\n"
                % (self.command, self.path, self.headers.get("User-Agent", "-"))
            )
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

        do_GET = _record
        do_HEAD = _record

        def log_message(self, *args) -> None:
            pass  # the access log is the file above, not stderr

    socketserver.TCPServer.allow_reuse_address = True
    server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
    if len(sys.argv) == 3:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(sys.argv[2])
        server.socket = context.wrap_socket(server.socket, server_side=True)

    print(server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
