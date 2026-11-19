"""Verify installed copies do not depend on the source checkout."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallTests(unittest.TestCase):
    def test_standalone_config_and_launcher(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            bindir = home / '.local/bin'
            bindir.mkdir(parents=True)
            legacy_source = home / 'legacy-source.py'
            legacy_source.write_text('DO NOT OVERWRITE\n')
            (bindir / 'pi-nvim').symlink_to(legacy_source)
            env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'),
                       NVIM_APPNAME='nvim', PI_NVIM_STATE=str(home / 'state'))
            subprocess.run(['sh', str(ROOT / 'install.sh')], env=env, check=True, capture_output=True)
            self.assertEqual(legacy_source.read_text(), 'DO NOT OVERWRITE\n')
            self.assertFalse((bindir / 'pi-nvim').is_symlink())
            result = subprocess.run([str(bindir / 'pi-nvim'), 'history'], env=env,
                                    capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout), [])
            probe = home / 'probe.lua'
            probe.write_text('''
vim.opt.runtimepath:prepend(vim.fn.stdpath 'config')
dofile(vim.fn.stdpath 'config' .. '/lua/custom/plugins/pi-nvim.lua')
assert(vim.fn.exists ':PiRun' == 2)
local source = debug.getinfo(require('pi_nvim').open).source
assert(source:find(vim.fn.stdpath 'config' .. '/lua/pi_nvim/init.lua', 1, true))
vim.cmd 'qa!'
''')
            subprocess.run(['nvim', '--headless', '-u', 'NONE', '-i', 'NONE', '-l', str(probe)],
                           env=env, cwd=directory, capture_output=True, check=True, timeout=15)


if __name__ == '__main__':
    unittest.main()
