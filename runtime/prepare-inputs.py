#!/usr/bin/env python3
"""Download the exact binary inputs in inputs.lock.json, checking every digest."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import shutil
import time
import urllib.request

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--cache', type=Path)
    args = parser.parse_args()
    lock = json.loads(Path(__file__).with_name('inputs.lock.json').read_text())
    args.directory.mkdir(parents=True, exist_ok=True)

    def fetch(item):
        destination = args.directory / item['file']
        if destination.is_file() and digest(destination) == item['sha256']:
            return
        cached = args.cache / item['file'] if args.cache else None
        if cached and cached.is_file() and digest(cached) == item['sha256']:
            shutil.copyfile(cached, destination)
            return
        temporary = destination.with_suffix(destination.suffix + '.download')
        try:
            for attempt in range(3):
                try:
                    with urllib.request.urlopen(item['url'], timeout=120) as response, temporary.open('wb') as output:
                        shutil.copyfileobj(response, output)
                    if digest(temporary) != item['sha256']:
                        raise ValueError('Input digest mismatch: ' + item['file'])
                    temporary.replace(destination)
                    return
                except (OSError, ValueError):
                    if attempt == 2:
                        raise
                    time.sleep(2)
        finally:
            temporary.unlink(missing_ok=True)

    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(fetch, lock['inputs']))
    print('Verified', len(lock['inputs']), 'fixed inputs.')

if __name__ == '__main__':
    main()
