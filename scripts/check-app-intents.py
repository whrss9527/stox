#!/usr/bin/env python3
"""验证实际打包的两个快捷指令及自动快捷指令元数据，缺失时停止打包。"""
import json
from pathlib import Path
import sys


def check(app):
    metadata = app / "Contents/Resources/Metadata.appintents"
    data = json.loads((metadata / "extract.actionsdata").read_text())
    json.loads((metadata / "version.json").read_text())
    expected = {"QueryStockPriceIntent", "OpenStoxPanelIntent"}
    actions = data["actions"]
    if not expected <= actions.keys():
        raise ValueError("缺少证券价格查询或打开面板的Intent")
    if actions["OpenStoxPanelIntent"].get("openAppWhenRun") is not True:
        raise ValueError("打开面板必须前台启动App")
    parameters = actions["QueryStockPriceIntent"].get("parameters", [])
    if not any(p.get("name") == "code" and p.get("isOptional") is False for p in parameters):
        raise ValueError("价格查询缺少必填证券代码")
    shortcuts = {item["actionIdentifier"] for item in data.get("autoShortcuts", []) if item.get("phraseTemplates")}
    if not expected <= shortcuts:
        raise ValueError("缺少两个可发现的AppShortcuts")
    print("AppIntents元数据通过：QueryStockPriceIntent / OpenStoxPanelIntent")


if __name__ == "__main__":
    try:
        check(Path(sys.argv[1]))
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        sys.exit("AppIntents元数据验证失败：" + str(error))
