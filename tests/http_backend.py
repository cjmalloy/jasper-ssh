from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class HeaderHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        names = (
            "Authorization",
            "Local-Origin",
            "Read-Access",
            "Tag-Read-Access",
            "Tag-Write-Access",
            "User-Role",
            "User-Tag",
            "Write-Access",
        )
        body = "".join(f"{name}: {self.headers.get(name, '')}\n" for name in names)
        encoded_body = body.encode()

        self.send_response(200)
        self.send_header("Content-Length", str(len(encoded_body)))
        self.end_headers()
        self.wfile.write(encoded_body)

    def log_message(self, format, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), HeaderHandler).serve_forever()
