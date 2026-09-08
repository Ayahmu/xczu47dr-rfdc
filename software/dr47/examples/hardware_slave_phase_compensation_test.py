"""Compatibility entry point for the calibrated external-trigger experiment.

The historical Scheme B script did not implement a compensation loop and
used a removed driver class. The supported experiment now lives in
hardware_external_tdc_trigger_test; use --help for calibration and bit inputs.
"""
from .hardware_external_tdc_trigger_test import main


if __name__ == "__main__":
    raise SystemExit(main())
