import SwiftUI

/// Settings → 服务器: what happens when an assistant asks for a password or a key. Nothing to set:
/// it says what Shion does with what you type, and what it never does (AppStore+Secrets.swift).
struct SecretSettings: View {
    var body: some View {
        Section {
            Text("终端要 sudo 密码、技能要密钥（比如 NOTION_API_KEY）时，那个助手的对话里和「等你确认」里会出现一张卡片：谁要、拿去做什么、要的是哪个变量。你填的只经这条连接发给这个服务器，只发一次，发完输入框就清空。sudo 密码交给那条命令，Hermes 在这次对话里记在内存中，下次 sudo 不再问；密钥存进那个助手 profile 的 .env，助手和对话记录都看不到它。拒绝就是不给，那一步会失败。Hermes 等 2 分钟，没回答就过期，这一轮结束了也算过期。")
                .font(.t12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("secret-settings")
            Text("Shion 不显示、不保存、不记录你填的值：不进对话，不写进钥匙串、偏好设置或这台 Mac 上的任何文件。通知只写谁要一个密码或密钥，不能在通知里填。输入框不接自动填充，「密码」App 不会替你填，也不会提出保存；存在「密码」里的，复制过来粘贴。")
                .font(.t12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("助手要密码或密钥时")
        }
    }
}
