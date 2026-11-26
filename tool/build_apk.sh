#!/usr/bin/env bash
# 发版打包的唯一入口：固定带 --split-per-abi，打完顺手核对三个包的 versionCode。
#
# 为什么不让人直接敲 flutter build apk：
# 不带 --split-per-abi 时 Flutter 不给 versionCode 加 ABI 前缀，出来的是底数本身
# （20xx）；split 出来的 arm64 包则是底数 + 2000（40xx）。同一个版本两套号，
# 先装 40xx 再装 20xx 会被系统判降级，覆盖安装直接失败。
set -euo pipefail

cd "$(dirname "$0")/.."

flutter build apk --release --split-per-abi "$@"

# 核对产物版本号：三个包应当共用 pubspec 的底数，各自加 ABI 前缀
AAPT=""
for candidate in "${LOCALAPPDATA:-}/Android/Sdk/build-tools"/*/aapt2.exe \
                 "${HOME:-}/Android/Sdk/build-tools"/*/aapt2; do
    if [ -x "$candidate" ]; then
        AAPT="$candidate"
    fi
done
if [ -z "$AAPT" ]; then
    echo "找不到 aapt2，跳过版本核对"
    exit 0
fi

echo
for apk in build/app/outputs/flutter-apk/app-*-release.apk; do
    printf '%-32s %s\n' "$(basename "$apk")" \
        "$("$AAPT" dump badging "$apk" | head -1 | grep -oE "versionCode='[0-9]+'")"
done
