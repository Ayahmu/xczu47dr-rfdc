"""兼容入口：正式脚本已迁移到 :mod:`dr47.examples`。"""

from .examples.hardware_slave_bypass_software_trigger_test import run


if __name__ == "__main__":
    raise SystemExit(run())
