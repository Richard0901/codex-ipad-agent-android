# App Store 审核元数据

## 目标

这份文档用于 App Store Connect 提交前自查，避免再次触发 Apple 产品名、第三方品牌或中国大陆合规相关拒审。

当前审核结论来自 App Review：

- 最新拒审：`Guideline 5.2.5 - Legal - Intellectual Property - Apple Products`
- 点名问题：Subtitle 中不当使用 `Mac`
- 历史风险：中国大陆可用时，公开元数据中出现 `OpenAI` / `ChatGPT` 相关引用

## 方案

首发公开元数据采用低风险描述：

- 不在 App Name、Subtitle、Promotional Text、Description、Keywords、截图标题里使用 `Mac`。
- 不在公开元数据里使用 `OpenAI`、`ChatGPT` 或官方产品名。
- 用 `本地开发环境`、`agentd`、`本机项目`、`结构化 agent 协议` 描述真实能力。
- 中国大陆继续保持不可用，除非后续明确拿到合规依据。

## 实现

### 中文元数据

App Name：

```text
咪咪 Console
```

Subtitle：

```text
连接你的本地开发环境
```

Promotional Text：

```text
在 iPad 上连接自己的开发环境，查看项目、会话、日志、diff 和审批。
```

Keywords：

```text
开发者,iPad,控制台,agent,自动化,日志,diff,审批,Tailscale,终端
```

Description：

```text
咪咪 Console 是一个面向开发者的 iPad 原生客户端，用来连接你自己运行的 agentd。

你可以通过 Homebrew 安装 agentd，然后在 iPad 上扫码连接，选择本机项目，并通过结构化 agent 协议远程使用你的本机开发环境。

主要特点：
- 原生 iPad 体验
- 通过二维码连接 agentd
- 支持项目列表、历史会话和新会话
- 支持结构化消息、日志、diff 和审批
- 开发凭证保留在你的本机环境
- 支持图片上下文、语音草稿和运行选项

注意：
本 App 需要配合 agentd 使用。推荐通过局域网或 Tailscale 连接，不建议把 agentd 暴露到公网。

本 App 是独立开发的第三方客户端，不隶属于任何平台厂商，也不代表官方产品。
```

### Review Notes

Review Notes 可以比公开元数据更具体，但仍应避免放大品牌风险。建议使用：

```text
Mimi Remote is a companion iPad client for a user-owned development environment running agentd.

The iPad app does not execute code on iPad and does not download executable code. It connects to the user's own local agent service over a private network or Tailscale.

Setup steps:
1. Install and sign in to the required local CLI tool.
2. Run: brew update
3. Run: brew install gaixianggeng/tap/mimi-remote
4. Run: agentd setup
5. Run: agentd doctor --check-port
6. Run: agentd start
7. Open the iPad app and scan the pairing QR code.

Security notes:
- Developer credentials remain on the user's own computer.
- The iPad app stores only the agentd endpoint and outer access token.
- The app-server upstream token is stored only on the desktop side and is never returned to iPad.
- The recommended network path is local network or Tailscale. Public internet exposure is not recommended.

China mainland availability:
China mainland is not selected for this version.
```

## 风险与优化

- `Mac` 可以在技术文档中描述运行环境，但不要放进 App Store subtitle、promotional text、keywords 或截图标题。
- 如果必须向审核解释依赖的本地 CLI，可以放在 Review Notes，并保持“用户自有环境、独立第三方客户端”的边界。
- 如果后续恢复中国大陆可用，需要重新清理公开元数据和截图，并确认相关功能满足当地要求。
