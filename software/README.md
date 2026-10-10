# 主机软件

本目录提供 Python 驱动 `dr47` 及其测试脚本。版本、安装和 API 概览见
[软件版本说明](../docs/软件版本说明.md)，完整签名和示例见
[API 接口参考](../docs/API参考.md)。

## 安装

~~~bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r software/requirements.txt
python -m pip install -e software/dr47
~~~

## 内容

- `dr47/`：可安装的驱动包。发波、板上测速、网络发现和模拟器脚本都在 `dr47/examples/`，
  清单见 [dr47/README.md](dr47/README.md)。安装后还提供 `dr47-network` 命令，用于发现、
  配置和查询板卡。
- `bump_driver_version.py`、`build_driver_release.py`：修改驱动版本号、生成 SDK 发布包
  （对应 `make driver-bump` 和 `make driver-release`）。
