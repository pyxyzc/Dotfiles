"""Reconstruct documents from fallback diffs across Unicode and block boundaries."""

import json
import random

from mock_lsp import offset
from test_vim import VimSession, quoted


class LspDiffTests(VimSession):
    def check_changes(self, cases):
        source = self.work / 'documents.json'
        report = self.work / 'changes.json'
        source.write_text(json.dumps([[old.split('\n'), new.split('\n')]
                                      for old, new in cases], ensure_ascii=False))
        self.vim('let cases = json_decode(join(readfile(' + quoted(source) + '), "\\n"))\n' + r'''
let changes = []
for documents in cases
  let saved = deepcopy(documents)
  call add(changes, lsp#utils#diff#compute(documents[0], documents[1]))
  call assert_equal(saved, documents, 'diff mutated input documents')
endfor
''' + f'call writefile([json_encode(changes)], {quoted(report)}, "S")\n')
        changes = json.loads(report.read_text())
        self.assertEqual(len(cases), len(changes))
        for (old, new), change in zip(cases, changes):
            with self.subTest(old=old[:80], new=new[:80]):
                for position in change['range'].values():
                    self.assertGreaterEqual(position['line'], 0)
                    self.assertGreaterEqual(position['character'], 0)
                start = offset(old, change['range']['start'])
                end = offset(old, change['range']['end'])
                self.assertLessEqual(0, start)
                self.assertLessEqual(start, end)
                self.assertLessEqual(end, len(old))
                self.assertEqual(len(old[start:end].encode('utf-16-le')) // 2, change['rangeLength'])
                self.assertEqual(new, old[:start] + change['text'] + old[end:])

    def test_random_unicode_edits_and_eof(self):
        rng = random.Random(192837)
        alphabet = ['a', 'b', '中', '🙂', '𝄞', '́', '\u200d', '️', '\n', '\t']
        cases = [('', ''), ('', '🙂\n'), ('🙂\n', ''), ('a\n', 'a'), ('a', 'a\n')]
        for _ in range(1000):
            old = ''.join(rng.choices(alphabet, k=rng.randrange(100)))
            first = rng.randrange(len(old) + 1)
            last = rng.randrange(first, len(old) + 1)
            replacement = ''.join(rng.choices(alphabet, k=rng.randrange(30)))
            cases.append((old, old[:first] + replacement + old[last:]))
        self.check_changes(cases)

    def test_line_block_boundaries_and_long_shared_prefix_suffix(self):
        cases = []
        for count in [0, 1, 255, 256, 257, 511, 512, 513]:
            prefix = ''.join(f'prefix {index}\n' for index in range(count))
            suffix = ''.join(f'\nsuffix {index}' for index in range(count))
            long = '中🙂é' * 5000
            for old, new in [(long, long + 'X'), (long, 'X' + long),
                             (long + 'A' + long, long + 'B' + long),
                             ('🙂old\n𝄞', '🙂new'), ('', '\n'), ('\n', '')]:
                cases.append((prefix + old + suffix, prefix + new + suffix))
        self.check_changes(cases)
