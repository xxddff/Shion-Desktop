import SwiftUI

/// Each assistant's own desktop on the VPS (Hermes Bot Screen). The live picture needs the RFB
/// client; until then the screen is drawn as a stand-in.
struct DesktopView: View {
    @Environment(AppStore.self) private var store
    @State private var selected: String? = nil

    var body: some View {
        let running = store.screens.filter { $0.running }
        let current = store.screens.first { $0.botId == (selected ?? running.first?.botId) }
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                if let current, let bot = store.bot(current.botId) {
                    HStack(spacing: 10) {
                        Avatar(bot: bot, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(bot.name)的桌面").font(.t15)
                            Text(current.running ? current.activity : "未启动")
                                .font(.t12)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                        } label: {
                            Label("接管", systemImage: "hand.raised")
                        }
                    }
                    if LaunchOptions.current.snapshot { ScreenMock(screen: current) }
                    else { ContentUnavailableView("桌面画面尚未接入", systemImage: "display") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 4) {
                Text("所有桌面").font(.t12.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                ForEach(store.screens, id: \.botId) { screen in
                    Button {
                        selected = screen.botId
                    } label: {
                        ScreenListRow(screen: screen, selected: screen.botId == current?.botId)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 220, alignment: .topLeading)
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay {
            if store.screens.isEmpty {
                ContentUnavailableView("暂无可用云桌面", systemImage: "display", description: Text("桌面画面尚未接入。"))
            }
        }
        .navigationTitle("云桌面")
        .navigationSubtitle("\(running.count) 块在运行")
    }
}

struct ScreenListRow: View {
    @Environment(AppStore.self) private var store
    let screen: BotScreen
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Avatar(bot: store.bot(screen.botId), size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.bot(screen.botId)?.name ?? "").font(.t13)
                Text(screen.running ? screen.activity : "未启动")
                    .font(.t12)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? Palette.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .opacity(screen.running ? 1 : 0.6)
    }
}

/// A stand-in for the Xfce screen: panel, one browser window, the page's rough shape.
struct ScreenMock: View {
    let screen: BotScreen

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.23, green: 0.29, blue: 0.42)
            VStack(spacing: 0) {
                HStack {
                    Text("应用程序").font(.system(size: 10))
                    Spacer()
                    Text("10:52").font(.system(size: 10)).monospacedDigit()
                }
                .foregroundStyle(Color(white: 0.9))
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background(Color(red: 0.17, green: 0.18, blue: 0.21))

                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(Color(white: 0.75)).frame(width: 7, height: 7)
                        }
                        Text(screen.url)
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.4))
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                            .background(Color.white, in: Capsule())
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color(white: 0.92))

                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.12, green: 0.49, blue: 0.22)).frame(height: 26)
                        ForEach(0..<5, id: \.self) { row in
                            HStack {
                                RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.82)).frame(width: CGFloat(140 + row * 18), height: 9)
                                Spacer()
                                RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.12, green: 0.49, blue: 0.22).opacity(0.7)).frame(width: 46, height: 9)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color.white)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .padding(EdgeInsets(top: 18, leading: 26, bottom: 26, trailing: 26))
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line))
    }
}
