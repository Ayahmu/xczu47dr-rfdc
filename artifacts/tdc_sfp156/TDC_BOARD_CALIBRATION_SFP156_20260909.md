# TDC Board Calibration: SFP156 Bitstream

Board: `yk@10.86.149.91`, UID `51ec34c000002001`  
Bitstream SHA256: `dae2d467ec8fa45bd54df448024b595dcc7f1a10583bc51abaf66273de05a183`

The final bitstream uses the existing XXV Ethernet TX user clock as an independent calibration-edge source. The TDC capture decoder selects the highest falling boundary in each carry group and keeps hard-invalid thermometer cases rejected.

The 30-second board calibration completed successfully:

- Samples: `126,690,554`
- Invalid: `0`
- Overflow: `0`
- Bad code: `0`
- Largest code-density bin: `44.52 ps`
- Occupied bins: `788`
- Calibration table: monotonic, `0..500` in 10 ps units
- Compensation commit: revision `1`, then revision `3` after the load-and-enable regression

The histogram covers 788 of 2048 tap bins, with gaps up to 8 bins. This is a valid board calibration for the observed code range and passes the current software checks, but it is not evidence that every physical carry tap has been independently excited. Full analog jitter acceptance still requires an external Trigger and oscilloscope measurement; no external Trigger was active during this run, so accepted playback events were `0`.
