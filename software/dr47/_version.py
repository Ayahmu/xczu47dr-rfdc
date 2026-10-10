"""Single source of the driver version.

Change it with ``make driver-bump VERSION=x.y.z`` (or ``PART=patch|minor|major``), or run
``python software/bump_driver_version.py``.  ``pyproject.toml`` reads this value when the wheel
is built and ``dr47.__version__`` re-exports it, so the two cannot drift apart.
"""

__version__ = "0.2.0"
