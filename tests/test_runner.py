import argparse
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
import shlex
from unittest.mock import patch
from types import SimpleNamespace
import subprocess

SPEC = importlib.util.spec_from_file_location('runner', Path(__file__).parents[1] / 'pi_nvim.py')
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.file = self.root / 'note.md'
        self.file.write_text('# Notes\n\nA sends work to B.\n')
        self.state = patch.object(runner, 'STATE', self.root / 'history')
        self.state.start()
        self.addCleanup(self.state.stop)

    def args(self, **kwargs):
        values = dict(workspace=str(self.root), file=str(self.file), kind='markdown',
                      instruction='Diagram the workflow', model=None, timeout=5, parent=None, apply=False)
        values.update(kwargs)
        return argparse.Namespace(**values)

    def propose(self):
        response = dict(status='proposed', reason='The text describes A to B.',
                        content=self.file.read_text() + '\n```mermaid\nflowchart LR\n  A --> B\n```\n')
        with patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(response), '')) as proc:
            run = runner.request(self.args())
        self.assertIn('--no-tools', proc.call_args.args[0])
        self.assertIn('--no-extensions', proc.call_args.args[0])
        self.assertIn('--no-context-files', proc.call_args.args[0])
        command = proc.call_args.args[0]
        self.assertEqual(command[command.index('--model') + 1], 'openai-codex/gpt-6.1-terra')
        self.assertNotIn('mermaid', self.file.read_text())
        return run

    def test_propose_apply_rollback(self):
        run = self.propose()
        self.assertEqual(run['status'], 'proposed')
        self.assertEqual((runner.STATE / (run['id'] + '.json')).stat().st_mode & 0o777, 0o600)
        self.assertEqual(runner.change(run['id'])['status'], 'applied')
        self.assertIn('mermaid', self.file.read_text())
        self.assertEqual(runner.change(run['id'], True)['status'], 'rolled_back')
        self.assertEqual(self.file.read_text(), run['before'])

    def test_stale_apply_and_rollback(self):
        run = self.propose()
        self.file.write_text('Newer edits\n')
        with self.assertRaisesRegex(ValueError, 'changed'):
            runner.change(run['id'])
        self.file.write_text(run['before'])
        runner.change(run['id'])
        self.file.write_text('Later edits\n')
        with self.assertRaisesRegex(ValueError, 'changed'):
            runner.change(run['id'], True)

    def test_refusal_and_clarification(self):
        for status in ('rejected', 'needs_clarification'):
            with patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0,
                    json.dumps(dict(status=status, reason='Insufficient context.')), '')):
                run = runner.request(self.args())
            self.assertEqual(run['status'], status)
            self.assertNotIn('after', run)

    def test_malformed_and_timeout_saved(self):
        with patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '{}', '')):
            run = runner.request(self.args())
        self.assertEqual(run['status'], 'failed')
        with patch.object(runner.subprocess, 'run', side_effect=subprocess.TimeoutExpired('pi', 5)):
            run = runner.request(self.args())
        self.assertEqual(runner.load(run['id'])['status'], 'failed')

    def test_boundaries(self):
        outside = self.root.parent / 'outside.md'
        with self.assertRaises((ValueError, FileNotFoundError)):
            runner.target(self.root, outside, 'markdown')
        link = self.root / 'link.md'
        link.symlink_to(self.file)
        with self.assertRaisesRegex(ValueError, 'Symlink'):
            runner.target(self.root, link, 'markdown')
        with self.assertRaises(ValueError):
            runner.load('../escape')

    def test_context_skips_hidden_and_symlinks(self):
        (self.root / 'other.md').write_text('Workflow details')
        hidden = self.root / '.private'
        hidden.mkdir()
        (hidden / 'secret.md').write_text('Workflow secret')
        (self.root / 'alias.md').symlink_to(self.root / 'other.md')
        self.assertEqual([r['path'] for r in runner.context(self.root, self.file, 'workflow')], ['other.md'])

    def test_selection_and_revision_preserve_surroundings(self):
        original = 'prefix café suffix\r\nNext line\r\n'
        self.file.write_bytes(original.encode())
        start, end = len('prefix '.encode()), len('prefix café'.encode())
        args = self.args(start_byte=start, end_byte=end)
        response = dict(status='proposed', reason='Scoped edit', content='tea')
        with patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(response), '')) as proc:
            first = runner.request(args)
        self.assertEqual(first['after'], 'prefix tea suffix\r\nNext line\r\n')
        self.assertEqual(json.loads(proc.call_args.kwargs['input'])['selection']['text'], 'café')
        args.parent = first['id']
        args.instruction = 'Make it coffee instead'
        response['content'] = 'coffee'
        with patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(response), '')) as proc:
            revised = runner.request(args, first)
        self.assertEqual(revised['parent'], first['id'])
        self.assertEqual(json.loads(proc.call_args.kwargs['input'])['previous']['content'], 'tea')
        self.assertEqual(runner.load(first['id'])['after'], first['after'])
        runner.change(revised['id'])
        self.assertEqual(self.file.read_bytes(), b'prefix coffee suffix\r\nNext line\r\n')
        runner.change(revised['id'], True)
        self.assertEqual(self.file.read_bytes(), original.encode())
        self.file.write_text('Changed')
        with self.assertRaisesRegex(ValueError, 'changed'):
            runner.request(args, first)

    def test_invalid_selection_and_snapshot(self):
        self.file.write_text('café\n')
        for options in (dict(start_byte=0), dict(start_byte=0, end_byte=4),
                        dict(start_byte=-1, end_byte=3), dict(expected_sha256='outdated')):
            with patch.object(runner.subprocess, 'run') as proc:
                run = runner.request(self.args(**options))
            self.assertEqual(run['status'], 'failed')
            proc.assert_not_called()

    def test_thread_and_handoff_are_private_and_shell_quoted(self):
        first = self.propose()
        second = dict(first, id='a' * 32, parent=first['id'], instruction='Shorten the labels')
        # Deliberately hostile shell characters must remain data in the copied command.
        second['workspace'] = str(self.root / "space ' ; $(touch unsafe)")
        runner.save(second)
        self.assertEqual([r['id'] for r in runner.thread(second['id'])], [first['id'], second['id']])
        result = runner.handoff(second['id'], current_buffer='Unsaved current buffer\n')
        tokens = shlex.split(result['command'])
        self.assertEqual(tokens, ['cd', '--', second['workspace'], '&&', 'pi', '--model', runner.DEFAULT_MODEL, '--', '@' + result['context_file']])
        path = Path(result['context_file'])
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertIn('Shorten the labels', path.read_text())
        self.assertIn(first['instruction'], path.read_text())
        self.assertIn('NEW interactive Pi session', path.read_text())
        self.assertEqual(json.loads(path.read_text().split('\n\n', 1)[1])['current_buffer'], 'Unsaved current buffer\n')
        self.assertIn(first['after'], json.loads(path.read_text().split('\n\n', 1)[1])['proposed_content'])
        (runner.STATE / (first['id'] + '.json')).unlink()
        self.assertEqual(len(runner.thread(second['id'])), 1)

    def test_unsaved_buffer_source_and_acceptance_never_write_target(self):
        disk = self.file.read_bytes()
        for before, proposal, expected in [('Unsaved text\n', 'New text', 'New text\n'),
                                           ('Unsaved text', 'New text\n', 'New text')]:
            response = dict(status='proposed', reason='Buffer proposal', content=proposal)
            with patch.object(runner.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(before.encode()))), \
                 patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(response), '')) as proc:
                run = runner.request(self.args(source_stdin=True))
            self.assertEqual(run['before'], before)
            self.assertEqual(run['after'], expected)
            self.assertEqual(run['source'], 'buffer')
            self.assertEqual(json.loads(proc.call_args.kwargs['input'])['file_content'], before)
            self.assertEqual(self.file.read_bytes(), disk)
            accepted = runner.accept_buffer(run['id'])
            self.assertEqual(accepted['status'], 'accepted')
            self.assertEqual(runner.accept_buffer(run['id']), accepted)
            self.assertEqual(self.file.read_bytes(), disk)
            with self.assertRaisesRegex(ValueError, 'applied'):
                runner.change(run['id'], True)
        with patch.object(runner.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(b'Unsaved\n'))), \
             patch.object(runner.subprocess, 'run') as proc:
            blocked = runner.request(self.args(source_stdin=True, apply=True))
        self.assertEqual(blocked['status'], 'failed')
        proc.assert_not_called()
        self.assertEqual(self.file.read_bytes(), disk)

    def test_new_named_buffer_does_not_create_a_file(self):
        file = self.root / 'not-saved-yet.md'
        response = dict(status='proposed', reason='New buffer proposal', content='# New file')
        with patch.object(runner.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(b'\n'))), \
             patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(response), '')):
            run = runner.request(self.args(file=str(file), source_stdin=True))
        self.assertEqual(run['status'], 'proposed')
        self.assertEqual(run['after'], '# New file\n')
        self.assertFalse(file.exists())
        runner.accept_buffer(run['id'])
        self.assertFalse(file.exists())
        with self.assertRaises(FileNotFoundError):
            runner.target(self.root, file, 'markdown')

    def test_ask_mode_answers_without_a_proposal_and_keeps_edit_context(self):
        first = self.propose()
        disk = self.file.read_bytes()
        answer = dict(status='answered', reason='Explanation', answer='A sends work to B.')
        with patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(answer), '')) as proc:
            question = runner.request(self.args(mode='ask', parent=first['id'], instruction='Why A to B?'))
        self.assertEqual(question['status'], 'answered')
        self.assertEqual(question['answer'], answer['answer'])
        self.assertNotIn('after', question)
        self.assertEqual(self.file.read_bytes(), disk)
        payload = json.loads(proc.call_args.kwargs['input'])
        self.assertEqual(payload['last_proposal']['content'], first['after'])
        self.assertIn(runner.ASK_SYSTEM, proc.call_args.args[0])
        with self.assertRaises(ValueError):
            runner.accept_buffer(question['id'])
        edited = dict(status='proposed', reason='Revision', content='# Revised\n')
        with patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(edited), '')) as proc:
            revised = runner.request(self.args(parent=question['id'], instruction='Use shorter names'), first)
        self.assertEqual(revised['parent'], question['id'])
        conversation = json.loads(proc.call_args.kwargs['input'])['conversation']
        self.assertEqual(conversation[-1]['answer'], answer['answer'])
        self.assertEqual(self.file.read_bytes(), disk)

    def test_ask_mode_can_explain_non_markdown_text(self):
        code = self.root / 'sample.py'
        code.write_text('def add(a, b):\n    return a + b\n')
        answer = dict(status='answered', reason='Code explanation', answer='It adds two values.')
        with patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(answer), '')):
            run = runner.request(self.args(file=str(code), mode='ask'))
        self.assertEqual(run['status'], 'answered')
        self.assertNotIn('after', run)
        self.assertEqual(code.read_text(), 'def add(a, b):\n    return a + b\n')
        with self.assertRaises(ValueError):
            runner.target(self.root, code, 'markdown')

    def test_ask_mode_rejects_edit_output_and_auto_apply(self):
        disk = self.file.read_bytes()
        malformed = dict(status='proposed', reason='Wrong mode', content='Overwrite everything')
        with patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(malformed), '')):
            run = runner.request(self.args(mode='ask'))
        self.assertEqual(run['status'], 'failed')
        self.assertNotIn('after', run)
        with patch.object(runner.subprocess, 'run') as proc:
            blocked = runner.request(self.args(mode='ask', apply=True))
        self.assertEqual(blocked['status'], 'failed')
        proc.assert_not_called()
        self.assertEqual(self.file.read_bytes(), disk)

    def test_validation(self):
        with self.assertRaisesRegex(ValueError, 'Unclosed'):
            runner.validate('```mermaid\nflowchart LR\n', 'markdown')
        runner.validate('~~~mermaid\nflowchart LR\n~~~\n', 'markdown')
        runner.validate('local x = 1\n', 'config')
        with self.assertRaisesRegex(ValueError, 'Lua syntax'):
            runner.validate('local = invalid', 'config')


if __name__ == '__main__':
    unittest.main()
