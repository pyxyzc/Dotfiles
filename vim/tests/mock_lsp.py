#!/usr/bin/env python3
"""Small stdio LSP peer for offline integration tests; no editor implementation."""

import argparse
import json
from pathlib import Path
import sys


def send(message):
    payload = json.dumps({'jsonrpc': '2.0', **message}, ensure_ascii=False).encode()
    sys.stdout.buffer.write(f'Content-Length: {len(payload)}\r\n\r\n'.encode() + payload)
    sys.stdout.buffer.flush()


def offset(text, position):
    lines = text.splitlines(keepends=True)
    row, column = position['line'], position['character']
    prefix = ''.join(lines[:row])
    line = lines[row] if row < len(lines) else ''
    return len(prefix) + len(line.encode('utf-16-le')[:column * 2].decode('utf-16-le'))


def location(uri, text):
    index = text.index('target')
    prefix = text[:index]
    start = {'line': prefix.count('\n'),
             'character': len(prefix.rsplit('\n', 1)[-1].encode('utf-16-le')) // 2}
    return {'uri': uri, 'range': {'start': start,
            'end': {**start, 'character': start['character'] + len('target')}}}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--target', type=Path, required=True)
    args, extra = parser.parse_known_args()
    documents = {}
    target_uri = args.target.resolve().as_uri()
    with args.log.open('a', encoding='utf-8') as log:
        def record(message):
            log.write(json.dumps(message, ensure_ascii=False) + '\n')
            log.flush()

        record({'method': '_start', 'argv': sys.argv[1:], 'extra': extra})
        while True:
            headers = {}
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    return
                if line in (b'\r\n', b'\n'):
                    break
                key, value = line.decode().split(':', 1)
                headers[key.lower()] = value.strip()
            message = json.loads(sys.stdin.buffer.read(int(headers['content-length'])))
            record(message)
            method = message.get('method')
            params = message.get('params', {})
            result = None
            if method == 'initialize':
                result = {'capabilities': {
                    'textDocumentSync': {'openClose': True, 'change': 2},
                    'definitionProvider': True, 'referencesProvider': True,
                    'hoverProvider': True, 'completionProvider': {},
                }}
            elif method == 'textDocument/didOpen':
                document = params['textDocument']
                documents[document['uri']] = document['text']
                send({'method': 'textDocument/publishDiagnostics', 'params': {
                    'uri': document['uri'], 'diagnostics': [{
                        'range': {'start': {'line': 0, 'character': 0},
                                  'end': {'line': 0, 'character': 1}},
                        'severity': 1, 'message': 'mock diagnostic should stay hidden',
                    }],
                }})
            elif method == 'textDocument/didChange':
                uri = params['textDocument']['uri']
                text = documents[uri]
                for change in params['contentChanges']:
                    if 'range' in change:
                        start = offset(text, change['range']['start'])
                        end = offset(text, change['range']['end'])
                        text = text[:start] + change['text'] + text[end:]
                    else:
                        text = change['text']
                documents[uri] = text
                record({'method': '_snapshot', 'uri': uri, 'text': text})
            elif method in ('textDocument/definition', 'textDocument/references'):
                uri = params['textDocument']['uri']
                text = documents.get(uri, '')
                target = location(target_uri, args.target.read_text())
                result = [target]
                if method.endswith('/references') or 'multiple' in text:
                    result.append(location(uri, text))
            elif method == 'textDocument/hover':
                result = {'contents': {'kind': 'plaintext', 'value': 'target: int'}}
            elif method == 'textDocument/completion':
                result = [{'label': 'target', 'kind': 6, 'insertText': 'target'}]
            elif method == 'exit':
                return
            if 'id' in message:
                send({'id': message['id'], 'result': result})


if __name__ == '__main__':
    main()
