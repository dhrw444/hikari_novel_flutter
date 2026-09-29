#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""根据 git 提交记录自动生成 Release 的中文更新说明（本次更新了什么）。

用法: python3 gen_release_body.py <本次tag> <owner/repo> [输出文件]
上一版本 tag 自动按 sort -V 版本序推算；可用环境变量 PREV_TAG_OVERRIDE 手动指定。
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

# 按 conventional commit 前缀分组，顺序即输出顺序
GROUPS = [
    ("feat", "✨ 新功能"),
    ("fix", "🐛 问题修复"),
    ("perf", "⚡ 性能优化"),
    ("refactor", "♻️ 代码重构"),
    ("style", "💄 样式与格式"),
    ("docs", "📝 文档"),
    ("test", "✅ 测试"),
    ("build", "📦 依赖与构建"),
    ("ci", "🔧 构建与 CI"),
    ("chore", "🧹 其它杂项"),
    ("other", "📌 其它改动"),
]
TITLE = dict(GROUPS)
ORDER = [k for k, _ in GROUPS]
MAX_ITEMS = 40  # 最多逐条列出的提交数

TAG_RE = re.compile(r"^\d+\.\d+\.\d+")
# 无信息量的维护类提交：只改 CI/Gradle 配置、或纯版本号提交
NOISE_RES = [
    re.compile(r"^Update\s+\S+\.(?:ya?ml|kts|gradle|properties|xml|json)\s*$", re.I),
    re.compile(r"^(?:Rename|Modify|Create|Add|Delete)\s+\S+\.(?:ya?ml|kts|gradle|properties|xml|json)\s*$", re.I),
    re.compile(r"^\d+\.\d+\.\d+([-+].*)?$"),
]


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout


def is_noise(subject: str) -> bool:
    return any(r.match(subject) for r in NOISE_RES)


def pick_prev(new_tag: str) -> str:
    """按版本序找出比 new_tag 小的最大版本 tag（排除 v 前缀、laoda 等杂 tag）。"""
    override = os.environ.get("PREV_TAG_OVERRIDE", "").strip()
    if override:
        return override
    tags = [t for t in git("tag").splitlines() if TAG_RE.match(t)]
    if not tags:
        return ""
    ordered = subprocess.run(
        ["sort", "-V"], input="\n".join(sorted(set(tags + [new_tag]))),
        capture_output=True, text=True,
    ).stdout.split()
    if new_tag not in ordered:
        return ""
    i = ordered.index(new_tag)
    return ordered[i - 1] if i > 0 else ""


def collect(rev_range: str):
    out = git("log", rev_range, "--no-merges", "--pretty=format:%h\x1f%s")
    items, noise = [], 0
    for line in out.splitlines():
        if "\x1f" not in line:
            continue
        sha, subject = line.split("\x1f", 1)
        subject = subject.strip()
        if not subject:
            continue
        if is_noise(subject):
            noise += 1
            continue
        m = re.match(r"^([a-zA-Z]+)(?:\([^)]*\))?!?:\s*(.+)$", subject)
        if m and m.group(1).lower() in TITLE and m.group(1).lower() != "other":
            kind, desc = m.group(1).lower(), m.group(2).strip()
        elif re.search(r"\.ya?ml\b|workflow|\bci\b|signing|keystore|jdk|gradle|flutter sdk", subject, re.I):
            kind, desc = "ci", subject
        else:
            kind, desc = "other", subject
        items.append((kind, desc, sha))
    return items, noise


def main() -> int:
    new = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
    repo = (sys.argv[2] if len(sys.argv) > 2 else "").strip()
    outfile = sys.argv[3] if len(sys.argv) > 3 else "/tmp/release_body.md"

    prev = pick_prev(new)
    if prev:
        rev_range = f"{prev}..HEAD"
        compare = f"https://github.com/{repo}/compare/{prev}...{new}" if repo else ""
    else:
        rev_range = "HEAD"
        compare = f"https://github.com/{repo}/releases/tag/{new}" if repo else ""
    print(f"[changelog] 上一版本 tag: {prev or '（无，按全部历史统计）'}", file=sys.stderr)

    try:
        items, noise = collect(rev_range)
    except subprocess.CalledProcessError:
        items, noise = collect("HEAD")

    buckets = {k: [] for k in ORDER}
    seen = set()
    for kind, desc, sha in items:
        if (desc, sha) in seen:
            continue
        seen.add((desc, sha))
        buckets[kind].append((desc, sha))

    total = sum(len(v) for v in buckets.values())
    shown = [(k, e) for k in ORDER for e in buckets[k]]
    truncated = len(shown) > MAX_ITEMS
    shown = shown[:MAX_ITEMS]

    lines = ["## 📦 本次更新", ""]
    scope = f"`{prev}` → `{new}`" if prev else f"`{new}`（全部历史）"
    lines.append(f"> 自动汇总 {scope} 之间的代码改动，共 {total} 条。")
    lines.append("")

    if total == 0:
        lines.append("本次构建没有新的代码改动（仅重新构建）。")
        lines.append("")
    else:
        for kind, _ in GROUPS:
            entries = [e for k, e in shown if k == kind]
            if not entries:
                continue
            lines.append(f"### {TITLE[kind]}")
            for desc, sha in entries:
                lines.append(f"- {desc} (`{sha}`)")
            lines.append("")
        if truncated:
            lines.append(f"> 提交较多，仅列出前 {MAX_ITEMS} 条，完整列表见下方对比链接。")
            lines.append("")

    if noise:
        lines.append(f"*（另有 {noise} 条 CI/配置文件维护类提交未逐条列出。）*")
        lines.append("")

    if compare:
        lines.append("---")
        lines.append(f"**完整改动对比**：{compare}")
        lines.append("")

    lines.append("### 📲 安装")
    lines.append(
        f"下载下方 `hikari_novel_{new}.apk`，与本仓库其他版本签名一致，直接覆盖安装即可，无需卸载。"
    )
    lines.append("")

    body = "\n".join(lines)
    with open(outfile, "w", encoding="utf-8") as f:
        f.write(body)
    print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
