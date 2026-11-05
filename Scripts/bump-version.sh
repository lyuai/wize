#!/bin/bash
# 递增版本号并刷新发布日期，然后重新生成工程。
# 用法：Scripts/bump-version.sh 0.2.1
set -euo pipefail

cd "$(dirname "$0")/.."

if [ $# -ne 1 ]; then
    echo "用法：Scripts/bump-version.sh <marketing-version>（例如 0.2.1）"
    exit 1
fi

VERSION="$1"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "版本号格式应为 x.y.z"
    exit 1
fi

CURRENT_BUILD=$(sed -nE "s/.*CURRENT_PROJECT_VERSION: '?([0-9]+)'?.*/\1/p" project.yml | head -1)
if [ -z "$CURRENT_BUILD" ]; then
    echo "未在 project.yml 中找到 CURRENT_PROJECT_VERSION"
    exit 1
fi
NEXT_BUILD=$((CURRENT_BUILD + 1))
TODAY=$(date +%Y-%m-%d)

python3 - "$VERSION" "$NEXT_BUILD" "$TODAY" <<'PY'
import re
import sys

version, build, today = sys.argv[1], sys.argv[2], sys.argv[3]
path = "project.yml"
source = open(path, encoding="utf-8").read()
source = re.sub(r"MARKETING_VERSION: '[^']*'", f"MARKETING_VERSION: '{version}'", source, count=1)
source = re.sub(r"CURRENT_PROJECT_VERSION: '[^']*'", f"CURRENT_PROJECT_VERSION: '{build}'", source, count=1)
source = re.sub(r"WIZE_RELEASE_DATE: '[^']*'", f"WIZE_RELEASE_DATE: '{today}'", source, count=1)
open(path, "w", encoding="utf-8").write(source)
PY

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate >/dev/null
else
    echo "未找到 xcodegen，请手动运行 xcodegen generate"
    exit 1
fi

echo "版本已更新：${VERSION}（构建 ${NEXT_BUILD}），发布日期 ${TODAY}"
