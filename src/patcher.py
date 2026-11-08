#!/usr/bin/env python3
"""
patcher.py — Typora macOS 授权绕过的二进制补丁

对 Mach-O 做两类「等长替换」，保证文件大小与结构完全不变：

  1. 授权标志字符串
     "File.option.hasLicense = false"      -> "File.option.hasLicense = true "
     "window._options.hasLicense=false; …" -> "window._options.hasLicense=true ; …"

  2. 未激活角标注入脚本
     原生层把一段 UTF-16LE 的 JS 模板注入 WebView，模板结尾是
         docReady(unfillLicense);1;
     这段 JS 会无条件把 hasLicense 置 false 并插入「未激活 ×」角标，
     且用 !important 锁死显示。把结尾换成等长空操作即可让它永不执行：
         void 0;（剩余位置用空格补齐）

Universal Mach-O 的 arm64 / x86_64 两个切片都会被处理（字符串搜索天然覆盖两片）。

用法：
    python3 patcher.py /path/to/Typora.app/Contents/MacOS/Typora
    python3 patcher.py --verify /path/to/binary     # 只检查，不写入
"""
from __future__ import annotations

import hashlib
import sys

# ---- 补丁表 ---------------------------------------------------------------
# 每项: (说明, 原始字节, 替换字节)
PATCHES: list[tuple[str, bytes, bytes]] = [
    (
        "UI 授权标志 (File.option)",
        b"File.option.hasLicense = false",
        b"File.option.hasLicense = true ",
    ),
    (
        "UI 授权标志 (_options)",
        b"window._options.hasLicense=false; window.forceReload();",
        b"window._options.hasLicense=true ; window.forceReload();",
    ),
    (
        "未激活角标注入 (UTF-16LE)",
        "docReady(unfillLicense);1;".encode("utf-16-le"),
        "void 0;".ljust(26).encode("utf-16-le"),
    ),
]


def check_lengths() -> None:
    for name, old, new in PATCHES:
        if len(old) != len(new):
            raise SystemExit(f"[!] {name}: 长度不一致 {len(old)} != {len(new)}")


def scan(data: bytes) -> dict[str, int]:
    return {name: data.count(old) for name, old, _ in PATCHES}


def apply(data: bytearray) -> dict[str, int]:
    counts: dict[str, int] = {}
    for name, old, new in PATCHES:
        n = 0
        pos = 0
        while True:
            pos = data.find(old, pos)
            if pos == -1:
                break
            data[pos:pos + len(new)] = new
            n += 1
            pos += len(new)
        counts[name] = n
    return counts


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2

    verify_only = "--verify" in argv
    path = argv[-1]

    check_lengths()

    with open(path, "rb") as f:
        original = f.read()

    print(f"目标: {path}")
    print(f"SHA-256: {hashlib.sha256(original).hexdigest()[:16]}…")
    print(f"大小:   {len(original):,} 字节\n")

    pre = scan(original)
    print("补丁点检查:")
    for name, old, new in PATCHES:
        n = pre[name]
        installed = original.count(new)
        mark = "✓" if n or installed else "✗"
        print(f"  {mark} {name}: 待处理 {n} 处，已应用 {installed} 处")

    missing = [name for name, old, new in PATCHES
               if old not in original and new not in original]
    if missing:
        print(f"\n[!] 缺少可识别的补丁特征，拒绝写入: {missing}")
        return 1

    if not any(pre.values()):
        print("\n已应用全部前端补丁，无需重复写入")
        return 0

    if verify_only:
        print("\n(--verify 模式，未写入)")
        return 0

    data = bytearray(original)
    counts = apply(data)

    if len(data) != len(original):
        print("[!] 内部错误：大小发生了变化，放弃写入")
        return 1

    with open(path, "wb") as f:
        f.write(data)

    print("\n已写入:")
    for name, n in counts.items():
        print(f"  {name}: 替换 {n} 处")

    post = scan(data)
    leftover = {k: v for k, v in post.items() if v}
    if leftover:
        print(f"\n[!] 仍有残留: {leftover}")
        return 1

    print(f"\n完成。SHA-256: {hashlib.sha256(data).hexdigest()[:16]}…")
    print(f"大小不变: {len(data):,} 字节")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
