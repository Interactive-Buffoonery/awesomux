import json
import os
import pathlib
import signal
import sys
import time

signal.alarm(10)  # Independent cleanup even if Foundation creates another process group.
mode = sys.argv[1]
home = pathlib.Path(os.environ['CODEX_HOME'])
assert home.name.startswith('case-')
signal.signal(signal.SIGTERM, signal.SIG_IGN if mode != 'echo' else signal.SIG_DFL)
(home / 'pid').write_text(str(os.getpid()))
print('{"ready":true}', flush=True)
if mode == 'exit':
    sys.exit(0)
if mode == 'resist':
    while True:
        time.sleep(1)
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    if method == 'initialize':
        result = {}
    elif method == 'hooks/list':
        result = {'data': []}
    else:
        assert method == 'config/batchWrite'
        assert 'edits' in request['params'] and 'writes' not in request['params']
        assert request['params']['reloadUserConfig'] is True
        assert request['params']['edits'][0]['mergeStrategy'] == 'upsert'
        result = {}
        (home / 'received').write_text(str(len(line)))
    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
    if mode == 'backpressure':
        while True:
            time.sleep(1)
