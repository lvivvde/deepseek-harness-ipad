"""Loopback Messages server that scripts one fault per scenario for #39 gates 4 and 3 (macOS host only).

The prompt carries a tag such as [[gate4:rate]]; the step is the number of tool results after it, and each
(scenario, step) counts its own attempts. Agent requests carry tools; the official title request does not and is
answered plainly. Only a fixed fake key is accepted. No network, no real credentials, no request text is kept.
"""
import json
import re
import select
import socket
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FAKE_KEY = 'sk-plan500-fault-injection-only'
PLACEHOLDER = 'plan500-native-placeholder'
TAG = re.compile(r'\[\[gate[34]:([a-z0-9-]+)\]\]')
# Requests each scenario must see: retries are visible as extra attempts, a replayed tool as an extra step.
EXPECTED = {'stream': 1, 'auth': 1, 'rate': 2, 'server': 3, 'drop-head': 2, 'drop-tool': 3, 'idle': 2, 'exhaust': 6, 'cancel': 1}


def sse(event, data):
    return f'event: {event}\ndata: {json.dumps({"type": event, **data}, ensure_ascii=False)}\n\n'.encode()


def message_start():
    return sse('message_start', {'message': {'id': 'msg_gate4', 'type': 'message', 'role': 'assistant', 'model': 'deepseek-flash',
                                             'content': [], 'stop_reason': None, 'stop_sequence': None,
                                             'usage': {'input_tokens': 12, 'output_tokens': 0}}})


def text_start(text=''):
    return message_start() + sse('content_block_start', {'index': 0, 'content_block': {'type': 'text', 'text': text}})


def text_delta(text, index=0):
    return sse('content_block_delta', {'index': index, 'delta': {'type': 'text_delta', 'text': text}})


def finish(reason, index=0):
    return (sse('content_block_stop', {'index': index})
            + sse('message_delta', {'delta': {'stop_reason': reason, 'stop_sequence': None}, 'usage': {'output_tokens': 8}})
            + sse('message_stop', {}))


def tool_use(index, call_id, name, arguments):
    return (sse('content_block_start', {'index': index, 'content_block': {'type': 'tool_use', 'id': call_id, 'name': name, 'input': {}}})
            + sse('content_block_delta', {'index': index, 'delta': {'type': 'input_json_delta', 'partial_json': json.dumps(arguments, ensure_ascii=False)}}))


def locate(body):
    """Scenario of the latest tagged user text, and how many tool results followed it."""
    scenario, step = None, 0
    for message in body.get('messages', []):
        content = message.get('content')
        blocks = [{'type': 'text', 'text': content}] if isinstance(content, str) else content or []
        for block in blocks:
            if message.get('role') == 'user' and block.get('type') == 'text' and TAG.search(block.get('text', '')):
                scenario, step = TAG.search(block['text']).group(1), 0
            elif block.get('type') == 'tool_result' and scenario:
                step += 1
    return scenario, step


class FaultServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(('127.0.0.1', 0), Handler)
        self.lock = threading.Lock()
        self.attempts = {}
        self.records = []
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)

    @property
    def url(self):
        return f'http://127.0.0.1:{self.server_address[1]}/anthropic/v1/messages'

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.shutdown()
        self.server_close()

    def summary(self):
        """Redacted: counts, key checks and wire outcomes only."""
        with self.lock:
            records = list(self.records)
        agent = [r for r in records if r['kind'] == 'agent']
        counts = {name: sum(1 for r in agent if r['scenario'] == name) for name in EXPECTED}
        return {'counts': counts, 'expected': EXPECTED, 'countsMatch': counts == EXPECTED,
                'otherRequests': sum(1 for r in records if r['kind'] == 'other'),
                'fakeKeyOnEveryRequest': all(r['keyOk'] for r in records),
                'placeholderNeverSent': not any(r['placeholderSeen'] for r in records),
                'workerCredentialsDropped': not any(r['authorization'] for r in records),
                'cancelPeerClosed': any(r.get('peerClosed') for r in agent if r['scenario'] == 'cancel'),
                'cancelToolNeverSent': not any(r.get('toolSent') for r in agent if r['scenario'] == 'cancel'),
                'paths': sorted({r['path'] for r in records})}


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('content-length', 0))))
        headers = {k.lower(): v for k, v in self.headers.items()}
        record = {'path': self.path, 'keyOk': headers.get('x-api-key') == FAKE_KEY,
                  'placeholderSeen': any(PLACEHOLDER in v for v in headers.values()),
                  'authorization': 'authorization' in headers or 'cookie' in headers}
        server = self.server
        if not body.get('tools'):
            record['kind'] = 'other'
            with server.lock:
                server.records.append(record)
            return self.reply(['标题'])
        scenario, step = locate(body)
        with server.lock:
            attempt = server.attempts.get((scenario, step), 0) + 1
            server.attempts[(scenario, step)] = attempt
            record.update(kind='agent', scenario=scenario, step=step, attempt=attempt)
            server.records.append(record)
        try:
            getattr(self, 'scenario_' + str(scenario).replace('-', '_'), self.scenario_unknown)(step, attempt, record)
        except (BrokenPipeError, ConnectionResetError, OSError):
            record['writeFailed'] = True
            self.close_connection = True

    # Wire helpers.
    def head(self, status=200, extra=None):
        self.send_response(status)
        self.send_header('content-type', 'text/event-stream')
        self.send_header('transfer-encoding', 'chunked')
        self.send_header('connection', 'close')
        for name, value in (extra or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.close_connection = True

    def chunk(self, data):
        self.wfile.write(b'%x\r\n' % len(data) + data + b'\r\n')
        self.wfile.flush()

    def end(self):
        self.wfile.write(b'0\r\n\r\n')
        self.wfile.flush()

    def reply(self, parts, gap=0.0):
        self.head()
        self.chunk(text_start())
        for part in parts:
            if gap:
                time.sleep(gap)
            self.chunk(text_delta(part))
        self.chunk(finish('end_turn'))
        self.end()

    def error(self, status, kind, extra=None):
        data = json.dumps({'type': 'error', 'error': {'type': kind, 'message': 'gate4 injected ' + kind}}).encode()
        self.send_response(status)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(data)))
        self.send_header('request-id', 'gate4-' + kind)
        self.send_header('connection', 'close')
        for name, value in (extra or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()
        self.close_connection = True

    def reset(self):
        """Abort with RST, so the client sees a lost connection rather than a clean end."""
        self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
        self.close_connection = True

    def wait_for_peer_close(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.connection], [], [], 0.05)
            if ready and not self.connection.recv(1024):
                return True
        return False

    # Scenarios.
    def scenario_unknown(self, step, attempt, record):
        self.error(400, 'invalid_request_error')

    def scenario_stream(self, step, attempt, record):
        self.reply(['GATE4_OK ', '流式', '分块', '到达', '完成'], gap=0.3)

    def scenario_auth(self, step, attempt, record):
        self.error(401, 'authentication_error')

    def scenario_rate(self, step, attempt, record):
        self.error(429, 'rate_limit_error', {'retry-after': '1'}) if attempt == 1 else self.reply(['GATE4_OK 限流后完成'])

    def scenario_server(self, step, attempt, record):
        self.error(503, 'overloaded_error') if attempt <= 2 else self.reply(['GATE4_OK 服务端错误后完成'])

    def scenario_exhaust(self, step, attempt, record):
        self.error(503, 'overloaded_error')

    def scenario_drop_head(self, step, attempt, record):
        self.reset() if attempt == 1 else self.reply(['GATE4_OK 断开后完成'])

    def scenario_drop_tool(self, step, attempt, record):
        if step == 0:
            self.head()
            self.chunk(message_start() + tool_use(0, 'call_gate4_read', 'plan500_read', {'path': '笔记.txt'}))
            self.chunk(finish('tool_use'))
            self.end()
        elif attempt == 1:
            self.head()
            self.chunk(text_start('GATE4_'))
            time.sleep(0.2)
            self.reset()
        else:
            self.reply(['GATE4_OK 工具后断流重试完成'])

    def scenario_idle(self, step, attempt, record):
        if attempt == 1:
            self.head()
            self.chunk(text_start('GATE4_'))
            time.sleep(4)  # Longer than the host gateway's 2 s idle timeout.
            self.chunk(text_delta('LATE'))
        else:
            self.reply(['GATE4_OK 空闲超时后完成'])

    def tools(self, step, calls, reply):
        """One official tool call per step, then a final reply carrying the marker."""
        if step >= len(calls):
            return self.reply([reply])
        name, arguments = calls[step]
        self.head()
        self.chunk(message_start() + tool_use(0, f'call_gate3_{step}', name, arguments))
        self.chunk(finish('tool_use'))
        self.end()

    # Gate 3: a model-driven turn edits through the official tools; the change summary must see it.
    def scenario_g3_turn(self, step, attempt, record):
        self.tools(step, [('read', {'file_path': 'README.md'}),
                          ('edit', {'file_path': 'README.md', 'old_string': 'line two', 'new_string': 'line two edited'}),
                          ('write', {'file_path': '新文件.txt', 'content': '模型写入\n'})], 'GATE3_OK 已修改')

    # Gate 3: an in-process child agent writes through the same gateway.
    def scenario_g3_child(self, step, attempt, record):
        self.tools(step, [('write', {'file_path': 'child.txt', 'content': '子代理写入\n'})], 'GATE3_OK 子代理完成')

    def scenario_cancel(self, step, attempt, record):
        self.head()
        self.chunk(text_start('GATE4_partial '))
        record['peerClosed'] = self.wait_for_peer_close(10)
        if record['peerClosed']:
            return
        # Not cancelled: finish with a tool call, which the Worker would then run and the check would catch.
        self.chunk(sse('content_block_stop', {'index': 0}) + tool_use(1, 'call_gate4_late', 'plan500_read', {'path': '笔记.txt'}))
        self.chunk(finish('tool_use', 1))
        self.end()
        record['toolSent'] = True
