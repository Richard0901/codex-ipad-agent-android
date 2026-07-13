#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/ios/MimiRemote/Resources/Info.plist"

plutil -lint "$INFO_PLIST" >/dev/null

# ATS 是发布安全边界：允许本机/Tailscale 私网连接，但不能重新打开全局 HTTP。
# 用系统 Ruby 解析 plutil JSON，避免 CI 额外安装依赖。
plutil -convert json -o - "$INFO_PLIST" | ruby -rjson -e '
  info = JSON.parse(STDIN.read)
  ats = info.fetch("NSAppTransportSecurity")

  abort "禁止启用 NSAllowsArbitraryLoads；公网连接必须使用 HTTPS" if ats["NSAllowsArbitraryLoads"] == true
  abort "必须声明 NSAllowsLocalNetworking，供本机和 Tailscale IP 连接使用" unless ats["NSAllowsLocalNetworking"] == true

  domains = ats.fetch("NSExceptionDomains", {})
  insecure_domains = domains.each_with_object([]) do |(name, settings), result|
    result << name if settings.is_a?(Hash) && settings["NSExceptionAllowsInsecureHTTPLoads"] == true
  end
  unexpected = insecure_domains - ["ts.net"]
  abort "发现未批准的 HTTP ATS 例外：#{unexpected.join(", ")}" unless unexpected.empty?
'

echo "iOS ATS 配置检查通过：仅允许本地网络和批准的 Tailscale 例外"
