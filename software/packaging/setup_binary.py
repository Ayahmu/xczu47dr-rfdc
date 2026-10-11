"""setup.py of the binary driver wheel.

``build_driver_wheels.py`` copies this file next to a staged copy of the
package.  Every module is compiled to an extension module with Cython except
the two that stay readable: ``__init__.py`` (the import surface) and
``_version.py``.  The Python sources of the compiled modules are left out of
the wheel.  The examples are shipped as they are: users edit and run them.
"""

from pathlib import Path

from Cython.Build import cythonize
from setuptools import Extension, setup
from setuptools.command.build_py import build_py

PLAIN_MODULES = {"__init__", "_version"}
COMPILED_MODULES = sorted(
    path.stem for path in (Path(__file__).parent / "dr47").glob("*.py") if path.stem not in PLAIN_MODULES)


class build_py_without_compiled_sources(build_py):
    def find_package_modules(self, package, package_dir):
        modules = super().find_package_modules(package, package_dir)
        return [module for module in modules if not (module[0] == "dr47" and module[1] in COMPILED_MODULES)]


# No debug information: it would name every function, variable and source line.
NO_DEBUG = {"extra_compile_args": ["-g0"], "extra_link_args": ["-s"]}

extensions = cythonize(
    [Extension(f"dr47.{name}", [f"dr47/{name}.py"], **NO_DEBUG) for name in COMPILED_MODULES],
    # The modules are ordinary Python: annotations must stay hints.  With
    # annotation typing Cython would turn "x: float" into a C double and
    # reject a numpy integer where "x: int" is written.
    compiler_directives={"language_level": "3", "annotation_typing": False},
    build_dir="build/cython",
)
# The UDP sender core is plain C that dr47.bulk loads with ctypes.  Building
# it as an extension puts the shared library next to the modules.
extensions.append(Extension(
    "dr47._fastsend", ["csrc/_fastsend.c"],
    extra_compile_args=["-O2", "-g0", "-pthread"], extra_link_args=["-s", "-pthread"]))

setup(ext_modules=extensions, cmdclass={"build_py": build_py_without_compiled_sources})
