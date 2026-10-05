#!/usr/bin/env python3
"""Small stdio LSP peer for offline integration tests; no editor implementation."""

import argparse
import json
from pathlib import Path
import sys
import os
import threading
import time

SEND_LOCK = threading.Lock()

def send(message):
    payload = json.dumps({'jsonrpc': '2.0', **message}, ensure_ascii=False).encode()
    with SEND_LOCK:
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
    parser.add_argument('--reference', type=Path, action='append', default=[])
    parser.add_argument('--initialize-delay-ms', type=float, default=0)
    parser.add_argument('--response-config', type=Path)
    args, extra = parser.parse_known_args()
    documents = {}
    config = json.loads(args.response_config.read_text()) if args.response_config else {}
    target_uri = args.target.resolve().as_uri()
    with args.log.open('a', encoding='utf-8') as log:
        def record(message):
            log.write(json.dumps({**message, '_pid': os.getpid()}, ensure_ascii=False) + '\n')
            log.flush()

        record({'method': '_start', 'argv': sys.argv[1:], 'extra': extra, 'pid': os.getpid()})
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
            if method is None:
                continue
            params = message.get('params', {})
            result = None
            if method in config.get('results', {}) and method != 'initialize':
                result = config['results'][method]
            elif method == 'initialize':
                time.sleep(args.initialize_delay_ms / 1000)
                result = {'capabilities': {
                    'textDocumentSync': {'openClose': True, 'change': 2},
                    'definitionProvider': True, 'referencesProvider': True,
                    'declarationProvider': True, 'typeDefinitionProvider': True,
                    'implementationProvider': True, 'workspaceSymbolProvider': True,
                    'signatureHelpProvider': {'triggerCharacters': ['(']},
                    'hoverProvider': True, 'completionProvider': {},
                    'renameProvider': True, 'codeActionProvider': True,
                    'documentFormattingProvider': True,
                    'documentRangeFormattingProvider': True, 'documentSymbolProvider': True,
                }}
                result['capabilities'].update(config.get('capabilities', {}))
            elif method == 'textDocument/didOpen':
                document = params['textDocument']
                documents[document['uri']] = document['text']
                send({'method': 'textDocument/publishDiagnostics', 'params': {
                    'uri': document['uri'], 'diagnostics': [{
                        'range': {'start': {'line': 0, 'character': 0},
                                  'end': {'line': 0, 'character': 1}},
                        'severity': 1, 'message': 'mock diagnostic',
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
            elif method in ('textDocument/definition', 'textDocument/references',
                            'textDocument/declaration', 'textDocument/typeDefinition',
                            'textDocument/implementation'):
                uri = params['textDocument']['uri']
                text = documents.get(uri, '')
                target = location(target_uri, args.target.read_text())
                result = [target]
                if method.endswith('/references') or 'multiple' in text:
                    result.append(location(uri, text))
                if method.endswith('/references'):
                    result.extend(location(path.resolve().as_uri(), path.read_text())
                                  for path in args.reference)
            elif method == 'textDocument/hover':
                result = {'contents': {'kind': 'plaintext', 'value': 'target: int'}}
            elif method == 'textDocument/signatureHelp':
                result = {'activeSignature': 0, 'activeParameter': 1, 'signatures': [{
                    'label': 'target(first: int, second: str)',
                    'parameters': [{'label': 'first: int'}, {'label': 'second: str'}]}]}
            elif method == 'workspace/symbol':
                result = [{'name': 'target', 'kind': 12,
                           'location': location(target_uri, args.target.read_text())}]
            elif method == 'textDocument/prepareRename':
                uri = params['textDocument']['uri']
                result = {'range': location(uri, documents[uri])['range'], 'placeholder': 'target'}
            elif method in ('completionItem/resolve', 'codeAction/resolve'):
                result = {**params, 'documentation': {'kind': 'markdown', 'value': 'Resolved docs'}}
            elif method == 'textDocument/rename':
                uri = params['textDocument']['uri']
                loc = location(uri, documents[uri])
                result = {'changes': {uri: [{'range': loc['range'],
                                            'newText': params['newName']}]}}
            elif method in ('textDocument/formatting', 'textDocument/rangeFormatting'):
                result = [{'range': {'start': {'line': 0, 'character': 0},
                                     'end': {'line': 0, 'character': 0}},
                           'newText': '# formatted\n'}]
            elif method == 'textDocument/documentSymbol':
                uri = params['textDocument']['uri']
                result = [{'name': 'target', 'kind': 12,
                           'location': location(uri, documents[uri])}]
            elif method == 'textDocument/codeAction':
                uri = params['textDocument']['uri']
                result = [{'title': 'Add comment', 'kind': 'quickfix', 'edit': {'changes': {
                    uri: [{'range': {'start': {'line': 0, 'character': 0},
                                     'end': {'line': 0, 'character': 0}},
                           'newText': '# action\n'}]}}}]
            elif method == 'textDocument/completion':
                text = documents.get(params['textDocument']['uri'], '')
                if 'completion-snippet' in text:
                    result = [{'label': 'target', 'kind': 3, 'insertTextFormat': 2,
                               'insertText': 'target(${1:中🙂})$0'}]
                elif 'completion-edit' in text:
                    end = params['position']
                    result = [{'label': 'target', 'kind': 6,
                               'textEdit': {'range': {'start': {**end, 'character': end['character'] - 3},
                                                      'end': end}, 'newText': 'target🙂'},
                               'additionalTextEdits': [{'range': {'start': {'line': 0, 'character': 0},
                                                                  'end': {'line': 0, 'character': 0}},
                                                        'newText': '# 𝄞\n'}]}]
                    if 'completion-edit-duplicates' in text:
                        result = [{**result[0], 'additionalTextEdits': [
                            {**result[0]['additionalTextEdits'][0], 'newText': f'# {label}\n'}]}
                            for label in ['FIRST 𝄞', 'SECOND 🙂']]
                else:
                    result = [{'label': 'target', 'kind': 6, 'insertText': 'target'}]
            elif method == 'test/notify':
                send(params)
            elif method == 'test/configure':
                config.update(params)
                result = True
            elif method == 'exit':
                return
            if 'id' in message:
                result = config.get('results', {}).get(method, result)
                response = {'id': message['id'], 'result': result}
                if method in config.get('errors', {}):
                    response = {'id': message['id'], 'error': config['errors'][method]}
                delay = config.get('delay_ms', {}).get(method, 0)
                if delay:
                    timer = threading.Timer(delay / 1000, send, args=[response])
                    timer.daemon = True
                    timer.start()
                else:
                    send(response)


if __name__ == '__main__':
    main()
