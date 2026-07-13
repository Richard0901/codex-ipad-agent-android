#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -n "${IOS_TEST_DESTINATION:-}" ]]; then
  resolved_destination="$IOS_TEST_DESTINATION"
else
  # GitHub runner 和开发机安装的 Simulator 名称/OS 会变化。优先复用已启动设备，
  # 否则选择第一个可用 iPad/iPhone，避免把测试绑死到某个 beta runtime。
  simulator_id="$(xcrun simctl list devices available -j | ruby -rjson -e '
    devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
    candidates = devices.select { |item| item["isAvailable"] && item["name"].match?(/iPad|iPhone/) }
    chosen = candidates.find { |item| item["state"] == "Booted" } || candidates.first
    print chosen.fetch("udid", "") if chosen
  ')"
  if [[ -z "$simulator_id" ]]; then
    echo "没有可用的 iOS Simulator，请安装 iOS runtime 或设置 IOS_TEST_DESTINATION" >&2
    exit 1
  fi
  resolved_destination="platform=iOS Simulator,id=$simulator_id"
fi

echo "==> Go gateway conversation regressions"
go test ./internal/httpapi

echo "==> iOS conversation regressions"
# 这些测试组覆盖 Mimi Remote 对话请求链路和发布安全边界：
# - CodexAppServerProtocolTests：JSON-RPC payload、collaborationMode、目标/steer 协议。
# - ConversationDataFlowTests：Composer、SessionStore、direct app-server、断线/重试/滚动状态。
# - MarkdownRenderingTests：proposed_plan 流式和完整渲染。
# - PairingLinkTests：Endpoint allowlist、ATS 对应的 HTTP/HTTPS 传输策略。
# - DoctorDiagnosticsTests：结构化 Doctor 响应、HTTP 错误和向后兼容。
xcodebuild test -quiet \
  -project ios/MimiRemote/MimiRemote.xcodeproj \
  -scheme MimiRemote \
  -destination "$resolved_destination" \
  -only-testing:MimiRemoteTests/CodexAppServerProtocolTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests \
  -only-testing:MimiRemoteTests/MarkdownRenderingTests \
  -only-testing:MimiRemoteTests/PairingLinkTests \
  -only-testing:MimiRemoteTests/DoctorDiagnosticsTests
