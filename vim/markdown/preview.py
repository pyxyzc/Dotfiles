#!/usr/bin/env python3
"""Loopback Markdown preview. Vim streams unsaved text over a private stdin pipe."""

import json
import mimetypes
from pathlib import Path
import secrets
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit


ASSETS = Path(__file__).resolve().parent
IMAGE_TYPES = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.avif', '.bmp', '.ico'}


class PreviewServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(('127.0.0.1', 0), PreviewHandler)
        self.token = secrets.token_urlsafe(24)
        self.lock = threading.Lock()
        self.state = {'text': '', 'name': 'Untitled.md', 'line': 1, 'revision': 0,
                      'document': 0, 'base': ''}
        self.root = Path.cwd()

    def update(self, payload):
        with self.lock:
            if 'text' in payload:
                root = Path(payload.get('root', '.')).resolve()
                path = Path(payload.get('path') or root / 'Untitled.md').absolute()
                try:
                    base = str(path.parent.relative_to(root))
                except ValueError:
                    # Files outside the project can still preview their own local images.
                    root, base = path.parent.resolve(), ''
                self.root = root
                self.state.update(text=str(payload['text']), name=str(payload['name']),
                                  base='' if base == '.' else base)
                self.state['document'] += 1
            self.state['line'] = max(1, int(payload.get('line', self.state['line'])))
            self.state['revision'] += 1


class PreviewHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, data, content_type, status=200):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy',
                         "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
                         "font-src 'self'; img-src 'self' data: https: http:; "
                         "connect-src 'self'; frame-ancestors 'none'; base-uri 'self'")
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        port = self.server.server_port
        if self.headers.get('Host') not in {f'127.0.0.1:{port}', f'localhost:{port}'}:
            self.send(b'Invalid host', 'text/plain', 403)
            return
        prefix = '/' + self.server.token + '/'
        path = unquote(urlsplit(self.path).path)
        if not path.startswith(prefix):
            self.send(b'Not found', 'text/plain', 404)
            return
        relative = path[len(prefix):]
        if relative == 'state':
            query = parse_qs(urlsplit(self.path).query)
            with self.server.lock:
                state = self.server.state.copy()
            if query.get('revision') == [str(state['revision'])]:
                self.send(b'', 'application/json', 204)
                return
            if query.get('document') == [str(state['document'])]:
                state.pop('text')
            data = json.dumps(state, ensure_ascii=False).encode('utf-8')
            self.send(data, 'application/json; charset=utf-8')
            return
        if relative.startswith('media/'):
            with self.server.lock:
                root = self.server.root
            candidate = (root / relative[6:]).resolve()
            if root not in candidate.parents or candidate.suffix.lower() not in IMAGE_TYPES:
                self.send(b'Not found', 'text/plain', 404)
                return
        else:
            candidate = (ASSETS / (relative or 'index.html')).resolve()
            if ASSETS not in candidate.parents or candidate.suffix not in {'.html', '.css', '.js', '.woff2'}:
                self.send(b'Not found', 'text/plain', 404)
                return
        try:
            data = candidate.read_bytes()
        except (OSError, ValueError):
            self.send(b'Not found', 'text/plain', 404)
            return
        mime = mimetypes.guess_type(candidate)[0] or 'application/octet-stream'
        if candidate.suffix in {'.html', '.css', '.js'}:
            mime += '; charset=utf-8'
        self.send(data, mime)


def main():
    server = PreviewServer()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    print(json.dumps({'url': f'http://127.0.0.1:{server.server_port}/{server.token}/'}), flush=True)
    try:
        for line in sys.stdin:
            try:
                server.update(json.loads(line))
            except (ValueError, TypeError, KeyError) as error:
                print(f'Invalid preview update: {error}', file=sys.stderr, flush=True)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
