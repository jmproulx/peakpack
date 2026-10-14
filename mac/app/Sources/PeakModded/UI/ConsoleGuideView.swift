import AppKit
import PeakModdedCore
import SwiftUI

/// The one manual step: paste `download_depot 3527290 3527291` into Mac Steam's console and press Return.
/// The picture is a drawing (not a Valve screenshot) of where the input box is.
struct ConsoleGuideView: View {
    @EnvironmentObject var model: AppModel
    @State private var copiedFlash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.game.phase {
            case .instructions:
                Text(model.game.isUpdate
                     ? "PEAK has an update. Steam downloads it with your account, the same way as the first time. Your current copy stays until the new one is ready."
                     : "Steam downloads PEAK's Windows files with your own account. You only have to paste one line into Steam.")
                    .fixedSize(horizontal: false, vertical: true)
                ConsolePicture(highlight: true, command: model.gameCommand)
                HStack(alignment: .center, spacing: 12) {
                    Button { model.openSteamConsole() } label: {
                        Label("Open Steam Console", systemImage: "terminal")
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .fixedSize()
                    Spacer(minLength: 8)
                    Menu("Other Options") {
                        Button("Use a PEAK Folder I Already Have…") { chooseFolder() }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Text("The button copies the line for you. Make sure Steam is signed in with the account that owns PEAK.")
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            case .waiting:
                stepsList
                ConsolePicture(highlight: true, command: model.gameCommand, compact: true)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Steam to start the download…").font(.callout).foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                HStack(spacing: 10) {
                    Button("Copy the Line Again") { model.copyCommandAgain(); flash() }.fixedSize()
                    Button("Show Steam Console") { model.showConsoleAgain() }.fixedSize()
                    Spacer()
                }
                if model.game.showHint { hint }
            case .downloading:
                Text(model.game.isUpdate ? "Steam is updating PEAK." : "Steam is downloading PEAK. You can keep using your Mac.")
                downloadProgress
                Text("Please keep Steam open until this finishes.").font(.callout).foregroundColor(.secondary)
            case .verifying:
                Text("Checking PEAK's files…")
                ProgressView().progressViewStyle(.linear)
            case .done:
                Label("PEAK's files are ready.", systemImage: "checkmark.circle.fill").foregroundColor(.green)
            }
            if copiedFlash {
                Text("Copied: \(model.gameCommand)").font(.caption).foregroundColor(.secondary).transition(.opacity)
            }
        }
    }

    var stepsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("In Steam's Console:").font(.headline)
            Label("Click the box at the bottom of the Console.", systemImage: "1.circle.fill")
            Label("Press ⌘V to paste.", systemImage: "2.circle.fill")
            Label("Press Return.", systemImage: "3.circle.fill")
        }
        .font(.body)
    }

    var downloadProgress: some View {
        let total = max(model.game.expected, 1)
        let gb = Double(model.game.bytes) / 1e9
        let frac = min(0.99, Double(model.game.bytes) / Double(total))
        return VStack(alignment: .leading, spacing: 6) {
            if model.game.isUpdate {
                ProgressView().progressViewStyle(.linear)
                Text(String(format: "%.2f GB checked", gb)).font(.callout).foregroundColor(.secondary).monospacedDigit()
            } else {
                ProgressView(value: frac).progressViewStyle(.linear)
                Text(String(format: "%.2f of about %.1f GB", gb, Double(total) / 1e9)).font(.callout).foregroundColor(.secondary).monospacedDigit()
            }
        }
    }

    var hint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Didn't start?", systemImage: "questionmark.circle").font(.headline)
            Text("• Paste into the box at the very bottom of Steam's Console, not the search field.\n• If the Console isn't showing, click Show Steam Console.\n• Check that Steam is signed in. If Steam printed an error, it will appear here.")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    func flash() {
        withAnimation { copiedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation { copiedFlash = false } }
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Use This Folder"
        p.message = "Choose a folder that contains PEAK's Windows files (PEAK.exe). It is copied; the original stays."
        if p.runModal() == .OK, let u = p.url { model.importGameFolder(u) }
    }
}

/// A schematic of Mac Steam's Console view: log lines, then the input box at the bottom, highlighted.
struct ConsolePicture: View {
    var highlight: Bool
    var command: String
    var compact = false
    @Environment(\.colorScheme) var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color.red.opacity(0.8)).frame(width: 9, height: 9)
                Circle().fill(Color.yellow.opacity(0.8)).frame(width: 9, height: 9)
                Circle().fill(Color.green.opacity(0.8)).frame(width: 9, height: 9)
                Text("Steam · Console").font(.caption2.weight(.medium)).foregroundColor(.white.opacity(0.6)).padding(.leading, 6)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(white: 0.16))
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<(compact ? 2 : 4), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.13))
                        .frame(width: [220, 300, 170, 260][i], height: 6)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.09)))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(highlight ? Color.accentColor : .clear, lineWidth: 2))
                    Image(systemName: "arrow.left").foregroundColor(.accentColor).font(.system(size: 13, weight: .bold))
                    Text("paste here, then Return").font(.caption.weight(.semibold)).foregroundColor(.accentColor)
                }
            }
            .padding(12)
            .frame(height: compact ? 78 : 110)
            .background(Color(white: 0.12))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(scheme == .dark ? 0.6 : 0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .accessibilityElement()
        .accessibilityLabel(Text("Steam's Console window. The input box at the bottom is where you paste \(command) and press Return."))
    }
}
