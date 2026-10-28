# -*- coding: utf-8 -*-
"""v1.84: 注册 Meters 10 个新文件到 pbxproj + 版本号 1.83/70 → 1.84/71"""
import re, io

P = r"/home/user/Doubao/chats/38448577444166402/AgentTool.xcodeproj/project.pbxproj"
src = io.open(P, encoding="utf-8").read()

files = [
    "MeterModels.swift",
    "MeterStore.swift",
    "MeterQueryService.swift",
    "MeterWebViewProvider.swift",
    "MeterBoardView.swift",
    "MeterExportSheet.swift",
    "MeterManageView.swift",
    "MeterRecordView.swift",
    "MeterSettingsDetailView.swift",
    "QuickActionEditSheet.swift",
]

# 1) PBXBuildFile 条目（追加在 GlobalAlertCenter build file 后）
build_entries = "\n".join(
    "\t\tA10000010000000000000{0} /* {1} in Sources */ = {{isa = PBXBuildFile; fileRef = B10000010000000000000{0} /* {1} */; }};".format(202 + i, f)
    for i, f in enumerate(files)
)
anchor_build = "\t\tA10000010000000000000150 /* GlobalAlertCenter.swift in Sources */ = {isa = PBXBuildFile; fileRef = B10000010000000000000150 /* GlobalAlertCenter.swift */; };"
assert anchor_build in src, "anchor build not found"
src = src.replace(anchor_build, anchor_build + "\n" + build_entries, 1)

# 2) PBXFileReference 条目（追加在 GlobalAlertCenter file ref 后）
ref_entries = "\n".join(
    "\t\tB10000010000000000000{0} /* {1} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {1}; sourceTree = \"<group>\"; }};".format(202 + i, f)
    for i, f in enumerate(files)
)
anchor_ref = "\t\tB10000010000000000000150 /* GlobalAlertCenter.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = GlobalAlertCenter.swift; sourceTree = \"<group>\"; };"
assert anchor_ref in src, "anchor ref not found"
src = src.replace(anchor_ref, anchor_ref + "\n" + ref_entries, 1)

# 3) Meters group 定义 + HouseKeeper group children 加入
meters_group = """\t\tD10000010000000000000012 /* Meters */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
""" + "\n".join(
    "\t\t\t\tB10000010000000000000{0} /* {1} */,".format(202 + i, f)
    for i, f in enumerate(files)
) + """
\t\t\t);
\t\t\tpath = Meters;
\t\t\tsourceTree = "<group>";
\t\t};"""
anchor_hk = """\t\tD10000010000000000000008 /* HouseKeeper */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\tD10000010000000000000009 /* Models */,
\t\t\t\tD10000010000000000000010 /* Services */,
\t\t\t\tD10000010000000000000011 /* Views */,
\t\t\t);"""
assert anchor_hk in src, "anchor hk not found"
src = src.replace(anchor_hk, anchor_hk.replace(
    "\t\t\t\tD10000010000000000000011 /* Views */,",
    "\t\t\t\tD10000010000000000000011 /* Views */,\n\t\t\t\tD10000010000000000000012 /* Meters */,"), 1)
# Meters group 定义插入到 HouseKeeper Views group 定义之后（找 Views group 的结束 "};" 后第一个 "\t\tD10000010000000000000011" 的位置）
# 简化：插到 /* End PBXGroup section */ 之前
anchor_end_group = "/* End PBXGroup section */"
assert anchor_end_group in src
src = src.replace(anchor_end_group, meters_group + "\n" + anchor_end_group, 1)

# 4) Sources build phase 追加
src_entries = "\n".join(
    "\t\t\t\tA10000010000000000000{0} /* {1} in Sources */,".format(202 + i, f)
    for i, f in enumerate(files)
)
anchor_src = "\t\t\t\tA10000010000000000000140 /* MediaPendingView.swift in Sources */,"
assert anchor_src in src
src = src.replace(anchor_src, anchor_src + "\n" + src_entries, 1)

# 5) 版本号
assert src.count("MARKETING_VERSION = 1.83;") == 4
assert src.count("CURRENT_PROJECT_VERSION = 70;") == 4
src = src.replace("MARKETING_VERSION = 1.83;", "MARKETING_VERSION = 1.84;")
src = src.replace("CURRENT_PROJECT_VERSION = 70;", "CURRENT_PROJECT_VERSION = 71;")

io.open(P, "w", encoding="utf-8", newline="\n").write(src)
print("OK: registered", len(files), "files, version 1.84/71")
