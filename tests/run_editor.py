"""Run the editor integration test with private, disposable data."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('runner', ROOT / 'pi_nvim.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    runner.STATE = root / 'state'
    file = root / 'test.md'
    file.write_text('# Before\n')
    common = dict(workspace=str(root), file=str(file), kind='markdown', instruction='Test request', created=runner.stamp())
    runner.save(dict(common, id=uuid.uuid4().hex, status='needs_clarification', reason='Test clarification'))
    proposed = dict(common, id=uuid.uuid4().hex, status='proposed', reason='Test proposal',
                    before='# Before\n', after='# After\n', diff='-# Before\n+# After\n')
    runner.save(proposed)
    # A deterministic model substitute; exercise the actual CLI/process boundary.
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    fake = bin_dir / 'pi'
    fake.write_text('''#!/usr/bin/env python3
import json, sys, time
request = json.load(sys.stdin)
if request['instruction'].startswith('Slow'):
    time.sleep(1.2)
if request['instruction'].startswith('Fail'):
    print('invalid model response')
    sys.exit(0)
if request['instruction'].startswith('Clarify'):
    print(json.dumps(dict(status='needs_clarification', reason='Which output format?')))
    sys.exit(0)
if request.get('mode') == 'ask':
    print(json.dumps(dict(status='answered', reason='Explanation', answer='This explains the selected text without changing it.')))
    sys.exit(0)
replacement = 'REVISED' if request.get('previous') else 'EDITED'
print(json.dumps(dict(status='proposed', reason='Test edit', content=replacement)))
''')
    fake.chmod(0o700)
    env = dict(os.environ, PI_NVIM_STATE=str(runner.STATE), PI_NVIM_TEST_FILE=str(file),
               PI_NVIM_TEST_RUN=proposed['id'], PATH=str(bin_dir) + os.pathsep + os.environ['PATH'])
    for script in ('tests/buffer.lua', 'tests/editor.lua'):
        subprocess.run(['nvim', '--headless', '-u', 'NONE', '-i', 'NONE', '-l', script],
                       cwd=ROOT, env=env, check=True, timeout=20)
