# Mimi Remote Android

这是 Mimi Remote 的 Android 平板前端首版骨架，目标是通过 Tailscale 远程操控运行在 Mac 上的 Codex，不在 Android 设备本地运行 Codex。

## 当前实现

- Kotlin + Jetpack Compose 原生 Android 工程；
- Android 10/API 29 起步，平板横屏双栏工作台；
- Endpoint 安全策略：允许 loopback、局域网、Tailscale IP、`.ts.net` 和 HTTPS，拒绝公网 HTTP；
- Android Keystore 加密保存访问码的 `TokenStore`；
- `/api/app-server/ws` Bearer 鉴权 WebSocket；
- `initialize` / `initialized`、`thread/list`、`thread/read`、`turn/start` 的核心请求路径；
- 会话列表、结构化事件的基础流式文本显示、消息发送；
- `mimiremote://pair` 与 `mimiremote://connect` Deep Link 入口；
- EndpointPolicy 单元测试。

当前仍是 MVP，不应视为生产发布版本。二维码相机扫描、完整配对票据兑换、审批响应卡、断线指数退避、Git/Worktree、通知、语音和 Claude bridge 尚未完成。

## 构建

需要 Android Studio、JDK 17、Android SDK 35 和 Gradle。用 Android Studio 打开
`android/` 后执行 Gradle Sync；如果本地已经生成 Gradle wrapper，可运行：

```bash
./gradlew :app:testDebugUnitTest
./gradlew :app:assembleDebug
```

当前提交没有提交 Gradle wrapper JAR，首次构建建议由 Android Studio 生成 wrapper
或使用本机 Gradle。当前工作区没有可用的 Android SDK/Gradle toolchain，
因此只能完成源码和静态检查，无法在当前环境执行 Android 构建。

## 安全边界

- Android 端只保存外侧 `agentd` 访问码，不保存 Mac 上游 app-server Token；
- 不提供任意远程 shell；
- 公网 HTTP Endpoint 在客户端层拒绝；
- 生产连接仍应优先使用 Tailscale/MagicDNS + HTTPS；
- 发布修改版本时继续遵守仓库根目录 GPLv3、Google Play 分发例外和第三方声明。
