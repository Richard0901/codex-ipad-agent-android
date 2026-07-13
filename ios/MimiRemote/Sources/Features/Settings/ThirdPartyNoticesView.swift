import SwiftUI

struct ThirdPartyNoticesView: View {
    private let notices = Self.loadNotices()

    var body: some View {
        ScrollView {
            Text(notices)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
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
