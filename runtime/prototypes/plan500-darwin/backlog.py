#!/usr/bin/env python3
"""Host kernel behaviour behind libslirp's hostfwd `listen(s, 1)`: N clients connect and send while
the listener is not accepting yet. XNU resets the connections that overflow the accept queue;
Linux keeps them pending and they all succeed once accept() runs. No VM, no network beyond loopback."""
import collections
import json
import platform
import socket
import threading
import time


def trial(clients, stall=0.5):
    server = socket.socket(); server.bind(('127.0.0.1', 0)); server.listen(1)
    port, results = server.getsockname()[1], collections.Counter()

    def accept():
        time.sleep(stall); server.settimeout(3)
        try:
            while True:
                conn, _ = server.accept(); conn.recv(100); conn.sendall(b'ok'); conn.close()
        except OSError: pass

    def connect():
        sock = socket.socket(); sock.settimeout(5)
        try:
            sock.connect(('127.0.0.1', port)); sock.sendall(b'x' * 50)
            results['ok' if sock.recv(10) == b'ok' else 'empty'] += 1
        except OSError as error: results[type(error).__name__] += 1
        finally: sock.close()

    threading.Thread(target=accept, daemon=True).start()
    threads = [threading.Thread(target=connect) for _ in range(clients)]
    for thread in threads: thread.start()
    for thread in threads: thread.join()
    server.close()
    return dict(results)


print(json.dumps({'system': platform.system(), 'release': platform.release(),
                  'trials': {n: trial(n) for n in (2, 3, 4, 6)}}))
