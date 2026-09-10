"""示例模块必须能在不连接硬件的情况下正常导入。"""

import importlib
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SOFTWARE_DIR = REPO_ROOT / "software"
EXAMPLES_DIR = SOFTWARE_DIR / "dr47" / "examples"


def _module_names() -> list[str]:
    return sorted(
        f"dr47.examples.{path.stem}"
        for path in EXAMPLES_DIR.glob("*.py")
        if path.name != "__init__.py"
    )


class ExampleImportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._added = str(SOFTWARE_DIR) not in sys.path
        if cls._added:
            sys.path.insert(0, str(SOFTWARE_DIR))

    @classmethod
    def tearDownClass(cls):
        if cls._added:
            sys.path.remove(str(SOFTWARE_DIR))

    def test_examples_directory_is_not_empty(self):
        """防止 glob 写错导致这个测试静默通过。"""
        self.assertTrue(_module_names(), "no example modules found")

    def test_every_example_module_imports(self):
        """任何一个 import 断链都必须在这里失败，而不是在板子上失败。"""
        for name in _module_names():
            with self.subTest(module=name):
                try:
                    importlib.import_module(name)
                except Exception as exc:  # noqa: BLE001 - 报告真实原因
                    self.fail(f"{name} failed to import: {type(exc).__name__}: {exc}")

    def test_no_example_imports_a_missing_sibling(self):
        """示例之间的相对 import 必须指向真实存在的同级模块。"""
        available = {path.stem for path in EXAMPLES_DIR.glob("*.py")}
        offenders = []
        for path in sorted(EXAMPLES_DIR.glob("*.py")):
            for number, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(), start=1
            ):
                stripped = line.strip()
                if not stripped.startswith("from ."):
                    continue
                target = stripped.split()[1]
                # 只看同级（单个点），".." 是上层包
                if not target.startswith(".") or target.startswith(".."):
                    continue
                sibling = target[1:].split(".")[0]
                if sibling and sibling not in available:
                    offenders.append(f"{path.name}:{number} -> {sibling}")
        self.assertEqual(offenders, [], "example imports a module that does not exist")


if __name__ == "__main__":
    unittest.main()
