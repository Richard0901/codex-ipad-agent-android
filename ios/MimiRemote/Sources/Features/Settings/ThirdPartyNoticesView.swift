import SwiftUI

struct ThirdPartyNoticesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    private let blocks: [MarkdownBlock]

    init() {
        // 许可文件本身就是 Markdown；直接复用会话中已经验证过的解析与表格渲染，
        // 避免把 #、反引号和表格分隔符作为源码暴露给用户。
        blocks = MarkdownParser.shared.parse(Self.loadNotices()).blocks
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let style = MarkdownStyle.make(
            role: .assistant,
            colorScheme: colorScheme,
            fontScale: themeStore.fontScale,
            tokens: tokens
        )

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(blocks) { block in
                    MarkdownBlockView(block: block, style: style)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .textSelection(.enabled)
        }
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func loadNotices() -> String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") else {
            return "未找到第三方许可文件。请通过项目 GitHub 仓库查看 THIRD_PARTY_NOTICES.md。"
        }

        // 许可正文随 App 本地打包，查看时不依赖网络，也不会把设备信息发送给外部服务。
        return (try? String(contentsOf: url, encoding: .utf8))
            ?? "第三方许可文件读取失败。请通过项目 GitHub 仓库查看 THIRD_PARTY_NOTICES.md。"
    }
}
