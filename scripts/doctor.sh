#!/usr/bin/env bash
set -euo pipefail

failures=0

pass() {
  printf '[OK] %s\n' "$1"
}

fail() {
  printf '[缺少] %s\n' "$1"
  failures=$((failures + 1))
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "iPad 构建需要 macOS 和完整 Xcode。"
else
  if command -v git >/dev/null 2>&1; then
    pass "$(git --version)"
  else
    fail "Git；请安装 Xcode 或 Command Line Tools。"
  fi

  if command -v swift >/dev/null 2>&1 && swift_version=$(swift --version 2>&1); then
    pass "$swift_version"
  else
    fail "Swift 工具链。"
  fi

  if command -v xcodebuild >/dev/null 2>&1 && xcode_version=$(xcodebuild -version 2>&1); then
    pass "$xcode_version"
    if sdk_path=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null); then
      pass "iPad/iPhone SDK：$sdk_path"
    else
      fail "iOS SDK；请在 Xcode 中安装所需平台。"
    fi
    if command -v xcrun >/dev/null 2>&1 && xcrun simctl list devices available >/dev/null 2>&1; then
      pass "模拟器工具 simctl 可用（运行时和设备请在 Xcode 中确认）。"
    else
      fail "模拟器工具 simctl 不可用。"
    fi
  else
    fail "完整 Xcode 尚未就绪；仅 Command Line Tools 无法构建 iPad 应用。"
  fi
fi

if command -v gh >/dev/null 2>&1; then
  pass "GitHub CLI 已安装；登录状态可通过 gh auth status 检查。"
else
  printf '[可选] 安装 GitHub CLI 可方便管理远端仓库。\n'
fi

if [[ "$failures" -gt 0 ]]; then
  printf '\n发现 %s 项环境问题，请参阅 docs/development.md。\n' "$failures"
  exit 1
fi

printf '\n工具检查通过；签名、模拟器运行时和真机连接需在 Xcode 中确认。\n'
