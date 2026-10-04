"""Local synthetic Messages provider; no credentials or request bodies are logged."""
import http.server
import json
import threading


class MockMessages(http.server.ThreadingHTTPServer):
    def __init__(self):
        super().__init__(('127.0.0.1', 0), Handler)
        self.requests = 0
        self.advertised = False
        self.actual_result = False
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=5)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        state = self.server
        state.requests += 1
        names = [tool.get('name') for tool in data.get('tools', [])]
        native = 'ipad_hello' in names
        ptc = 'run_code' in names and 'ipad_hello' in json.dumps(data.get('system', []))
        advertised = native or ptc
        state.advertised |= advertised
        messages = json.dumps(data.get('messages', []), ensure_ascii=False)
        returned = 'tool_result' in messages and '你好，来自 iPad 自制插件！' in messages
        state.actual_result |= returned
        # Title requests have no tools. Never force an unadvertised call or loop
        # indefinitely when a plugin fails to enter the actual model surface.
        settled = returned or not advertised or state.requests > 6
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()

        def event(kind, payload):
            wire = {'type': kind, **payload}
            self.wfile.write(('event: ' + kind + '\ndata: ' + json.dumps(wire) + '\n\n').encode())
            self.wfile.flush()

        event('message_start', {'message': {
            'id': 'acceptance-message', 'type': 'message', 'role': 'assistant',
            'model': data.get('model', 'acceptance'), 'content': [],
            'stop_reason': None, 'stop_sequence': None,
            'usage': {'input_tokens': 8, 'output_tokens': 0},
        }})
        if settled:
            event('content_block_start', {'index': 0, 'content_block': {'type': 'text', 'text': ''}})
            event('content_block_delta', {'index': 0, 'delta': {
                'type': 'text_delta', 'text': 'MOCK_PLUGIN_OK' if returned else 'MOCK_NO_TOOL_CALL',
            }})
        else:
            event('content_block_start', {'index': 0, 'content_block': {
                'type': 'tool_use', 'id': 'acceptance-hello',
                'name': 'ipad_hello' if native else 'run_code', 'input': {},
            }})
            arguments = {} if native else {
                'code': 'return await tools.ipad_hello({});', 'description': 'Run isolated hello plugin',
            }
            event('content_block_delta', {'index': 0, 'delta': {
                'type': 'input_json_delta', 'partial_json': json.dumps(arguments),
            }})
        event('content_block_stop', {'index': 0})
        event('message_delta', {'delta': {
            'stop_reason': 'end_turn' if settled else 'tool_use', 'stop_sequence': None,
        }, 'usage': {'output_tokens': 10}})
        event('message_stop', {})
