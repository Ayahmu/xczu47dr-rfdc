"""Test configuration.

``DR47_TEST_INSTALLED=1`` runs the driver tests against the installed ``dr47``
distribution (a binary wheel) instead of the source tree.  The test modules
put ``software/`` on ``sys.path`` themselves; importing the installed package
here, before any of them is collected, makes every later ``import dr47...``
resolve inside it.
"""

import os
from pathlib import Path

if os.environ.get("DR47_TEST_INSTALLED") == "1":
    import dr47

    _source_tree = Path(__file__).resolve().parents[1] / "software"
    if _source_tree in Path(dr47.__file__).resolve().parents:
        raise RuntimeError(f"DR47_TEST_INSTALLED=1 but dr47 was imported from the source tree: {dr47.__file__}")
