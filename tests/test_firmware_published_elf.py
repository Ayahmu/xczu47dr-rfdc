"""The ELF files handed out in artifacts/ carry no symbols, debug data or build paths.

Debug sections name every source file and the directory the build ran in.  The
unstripped application stays in the Vitis workspace for debugging.
"""

import struct
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = REPO_ROOT / "artifacts"
PUBLISHED = ("custom_xczu47dr_waveform.elf", "custom_xczu47dr_waveform_fsbl.elf")


def section_names(data: bytes) -> list[str]:
    """Section names of a little-endian ELF64 file."""
    assert data[:6] == b"\x7fELF\x02\x01", "not a little-endian ELF64 file"
    shoff, = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    headers = [struct.unpack_from("<IIQQQQ", data, shoff + i * shentsize) for i in range(shnum)]
    strings = data[headers[shstrndx][4]:headers[shstrndx][4] + headers[shstrndx][5]]
    return [strings[h[0]:strings.index(b"\0", h[0])].decode() for h in headers]


class PublishedElfTests(unittest.TestCase):
    def test_published_elfs_are_stripped(self):
        for name in PUBLISHED:
            with self.subTest(name=name):
                data = (ARTIFACTS / name).read_bytes()
                leaking = [s for s in section_names(data) if s.startswith(".debug") or s in (".symtab", ".strtab")]
                self.assertEqual(leaking, [])
                self.assertNotIn(b"/home/", data)
                self.assertNotIn(b"/workspace/", data)

    def test_boot_image_carries_no_build_paths(self):
        data = (ARTIFACTS / "BOOT.BIN").read_bytes()
        self.assertNotIn(b"/home/", data)
        self.assertNotIn(b"/workspace/", data)

    def test_build_script_strips_what_it_publishes(self):
        script = (REPO_ROOT / "firmware" / "build.sh").read_text(encoding="utf-8")
        publish = script.split("install_stripped_elf() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("aarch64-none-elf-strip", publish)
        for call in ('install_stripped_elf "${WORKSPACE_DIR}/${APP_NAME}/Debug/${APP_NAME}.elf" "${ELF_FILE}"',
                     'install_stripped_elf "${WORKSPACE_FSBL}" "${FSBL_FILE}"'):
            self.assertIn(call, script)


if __name__ == "__main__":
    unittest.main()
