# 主机软件

本目录提供 Python 驱动 `dr47` 及其测试脚本。面向用户的版本、安装和 API 概览见
[软件使用说明](../docs/软件版本说明.md)，完整签名和示例见
[API 接口参考](../docs/API参考.md)。本页是开发和发布用的说明，不随 SDK 交付。

## 开发环境

~~~bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r software/requirements.txt
python -m pip install -e software/dr47
python -m pytest tests -q          # 或 make test；RTL 仿真需要 Vivado 在 PATH 中，否则自动跳过
~~~

源码树里的 100G 发送核心 `dr47/_fastsend.c` 在首次使用时用系统 C 编译器编译到
`~/.cache/dr47/`；没有编译器时退回纯 Python 发送。

## 对外发布：二进制 wheel 和 SDK 包

交付给用户的驱动不带 Python 源码。`make driver-release` 需要 Docker 和网络：

~~~bash
make driver-wheel       # 在 manylinux 容器里编译、安装并测试，每个 Python 版本一个 wheel -> dist/
make driver-release     # 先做 driver-wheel，再打出 dist/47dr-driver-sdk-<版本>.zip
~~~

- `build_driver_wheels.py` 把 `dr47/` 复制到临时目录，用 Cython 把除 `__init__.py`、
  `_version.py` 以外的模块编成扩展模块（`packaging/setup_binary.py`），`_fastsend.c` 预编译成
  同目录的共享库，示例脚本保持 `.py`。研发用的 `dr47/tdc.py` 不进包。
- 构建在 `quay.io/pypa/manylinux_2_28_x86_64` 容器里进行（`packaging/build_in_container.sh`），
  产物可在 glibc 2.17 及以上的 x86-64 Linux 上加载。每个 wheel 都在容器里装进干净环境，
  运行模拟器示例和 `WHEEL_TESTS` 列出的驱动测试。
- wheel 落到 `dist/` 之前逐个检查：不含模块源码、C 源码和被排除的模块，编译模块齐全，
  元数据里没有仓库地址。`build_driver_release.py` 只接受通过检查的 wheel。
- 编译后的模块里仍然可以读到函数名、文档字符串、报错文本和 `dr47/<模块>.py` 形式的文件名
  （用于异常回溯）；读不到的是代码本身和注释。
- 针对已安装的 wheel 运行驱动测试：`DR47_TEST_INSTALLED=1 python -m pytest tests/<文件>`
  （见 `tests/conftest.py`）。

支持的 Python 版本是 `build_driver_wheels.PYTHON_TAGS`；增减版本时同步修改
`dr47/pyproject.toml` 的 classifiers。

## 修改驱动版本号

版本号只有一个来源：`software/dr47/_version.py`。`pyproject.toml` 在打包时读取它，
`dr47.__version__` 也从它导入，发布脚本据此查找 wheel，因此不会不同步。修改方法：

~~~bash
make driver-bump PART=patch           # X.Y.Z -> X.Y.(Z+1)；也可用 minor、major
make driver-bump VERSION=0.3.0        # 指定版本（X.Y.Z，可带 aN/bN/rcN、.postN、.devN）
make driver-version                   # 查看源码版本和已安装版本
~~~

`driver-bump` 会同时重装 editable 安装（`pip install -e software/dr47`），否则 pip 记录的
版本号停留在安装时的数值。每次对外可见的驱动改动都应修改版本号：相同版本号的旧安装
会被 pip 当作最新版本，导致过期代码继续生效。

## 内容

- `dr47/`：驱动包。发波、板上测速、网络发现和模拟器脚本都在 `dr47/examples/`，
  清单见 [dr47/README.md](dr47/README.md)。安装后还提供 `dr47-network` 命令，用于发现、
  配置和查询板卡。
- `build_driver_wheels.py`、`packaging/`：构建二进制 wheel。
- `build_driver_release.py`：把 wheel、文档和示例打成 SDK 包。
- `bump_driver_version.py`：修改驱动版本号。
