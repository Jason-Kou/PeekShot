import AppKit
import SwiftUI

struct RecommendedApp: Identifiable {
    let name: String
    let summary: String
    let symbol: String
    let url: URL
    var id: String { name }
}

/// Everything shown on the About tab, kept in one place so links are easy to update.
enum AboutInfo {
    static let author = "Jason Kou"
    static let homepage = URL(string: "https://jasonkou.com")!
    static let repository = URL(string: "https://github.com/Jason-Kou/PeekShot")!

    static let apps: [RecommendedApp] = [
        RecommendedApp(name: "BatFrame", summary: "Baseball swing replay for iPhone and iPad",
                       symbol: "figure.baseball",
                       url: URL(string: "https://apps.apple.com/us/app/batframe-baseball-replay/id6833773422")!),
        RecommendedApp(name: "ZhiYin", summary: "Fast, fully offline voice input for macOS",
                       symbol: "waveform",
                       url: URL(string: "https://github.com/Jason-Kou/zhiyin")!),
        RecommendedApp(name: "WordLeaf", summary: "English reading companion for iPhone and iPad",
                       symbol: "leaf",
                       url: URL(string: "https://apps.apple.com/us/app/wordleaf-reading-companion/id6811483658")!),
        RecommendedApp(name: "ExpoSnap", summary: "Collect and manage contacts at trade shows",
                       symbol: "person.crop.rectangle.stack",
                       url: URL(string: "https://apps.apple.com/us/app/exposnap/id6752795586")!),
    ]

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PeekShot").font(.title2.weight(.semibold))
                        Text("Version \(AboutInfo.version)").foregroundStyle(.secondary)
                        Text("A free, open-source alternative to CleanShot X.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                LinkRow(title: "Source Code", detail: "github.com/Jason-Kou/PeekShot · MIT License",
                        symbol: "chevron.left.forwardslash.chevron.right", url: AboutInfo.repository)
                LinkRow(title: "Made by \(AboutInfo.author)", detail: "jasonkou.com",
                        symbol: "person.crop.circle", url: AboutInfo.homepage)
            }
            Section("More Apps by the Author") {
                ForEach(AboutInfo.apps) { app in
                    LinkRow(title: app.name, detail: app.summary, symbol: app.symbol, url: app.url)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A full-width row that opens a link in the browser.
private struct LinkRow: View {
    let title: String
    let detail: String
    let symbol: String
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
