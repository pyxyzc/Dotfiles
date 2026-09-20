"""Enforce the repository's first-party Vimscript style rules."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parent.parent
SOURCES = [ROOT / ".vimrc"] + sorted(ROOT.glob("*.vim"))
COMMAND_SEPARATOR = re.compile(r"(?<!\|)\s\|\s(?!\|)")


class VimStyleTests(unittest.TestCase):
    def test_first_party_vimscript_has_consistent_layout(self):
        violations = []
        for path in SOURCES:
            text = path.read_text(encoding="utf-8")
            if not text.endswith("\n"):
                violations.append(f"{path.name}: missing final newline")
            for number, line in enumerate(text.splitlines(), 1):
                if "\t" in line:
                    violations.append(f"{path.name}:{number}: tab character")
                if line.rstrip() != line:
                    violations.append(f"{path.name}:{number}: trailing whitespace")
                if len(line) > 100:
                    violations.append(f"{path.name}:{number}: {len(line)} columns")
                indent = len(line) - len(line.lstrip(" "))
                if indent % 2:
                    violations.append(f"{path.name}:{number}: odd indentation")
                if COMMAND_SEPARATOR.search(line):
                    violations.append(f"{path.name}:{number}: command separator")
        self.assertEqual([], violations, "\n".join(violations))


if __name__ == "__main__":
    unittest.main(verbosity=2)
