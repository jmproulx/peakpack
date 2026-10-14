import AppKit
import PeakModdedCore
import SwiftUI

/// The options window (Option-click / Dock click while running / after setup): play choices and tools.
struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                AppIconView(size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("PEAK (Modded)").font(.largeTitle.weight(.semibold))
                    Label(model.statusLine, systemImage: "checkmark.circle.fill")
                        .foregroundColor(.secondary)
                        .labelStyle(StatusLabelStyle())
                }
                Spacer()
            }
            .padding(.top, 12)
            LocationBanner()
            NoticeBanner()
            if let p = model.problem { ProblemView(problem: p) }
            if let c = model.updateCandidate {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.app.fill").font(.title2).foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version \(c.version.description) is available").font(.headline)
                        Text("You have \(AppInfo.version). The update takes a few seconds.").font(.callout).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Update Now") { model.installAppUpdate() }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
            }
            HStack(spacing: 12) {
                BigChoice(title: "Play with Mods", subtitle: "Updates \(model.hostName)'s mods, then starts PEAK.",
                          symbol: "play.fill", prominent: true) { model.play() }
                    .keyboardShortcut(.defaultAction)
                BigChoice(title: "Play Normal PEAK", subtitle: "No mods. Same game, same saves.",
                          symbol: "gamecontroller", prominent: false) { model.play(vanilla: true) }
            }
            .disabled(model.isBusy)
            Toggle(isOn: Binding(get: { model.showFPS }, set: { _ in model.toggleFPS() })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show FPS")
                    Text("Apple's performance overlay in the corner of the game.").font(.caption).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            Divider()
            HStack(spacing: 16) {
                Button { model.openLogs() } label: { Label("Logs", systemImage: "doc.text.magnifyingglass") }
                Button { model.copyDiagnostics() } label: { Label("Copy Diagnostics", systemImage: "doc.on.clipboard") }
                Menu {
                    Button("Check for Updates") { model.checkForAppUpdate(userInitiated: true) }
                    Button("Re-download PEAK") { model.updateGame() }
                        .help("Use this if PEAK updated and the app didn't notice")
                } label: { Label("More", systemImage: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                Spacer(minLength: 12)
                Button { (NSApp.delegate as? AppDelegate)?.repair() } label: { Label("Repair…", systemImage: "wrench.and.screwdriver") }
                Button(role: .destructive) { (NSApp.delegate as? AppDelegate)?.uninstall() } label: { Label("Uninstall…", systemImage: "trash") }
            }
            .buttonStyle(.borderless)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(model.isBusy)
        }
        .padding(28)
    }
}

struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundColor(.green)
            configuration.title
        }
    }
}

/// A large two-line choice, like a command link.
struct BigChoice: View {
    let title: String
    let subtitle: String
    let symbol: String
    let prominent: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).frame(width: 30)
                    .foregroundColor(prominent ? .white : .accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundColor(prominent ? .white : .primary)
                    Text(subtitle).font(.caption).foregroundColor(prominent ? .white.opacity(0.85) : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(prominent ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: prominent ? 0 : 0.5))
            .brightness(hover ? (prominent ? 0.05 : -0.02) : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(subtitle))
    }
}

/// Starting / running PEAK (and repair / update progress).
struct LaunchView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            AppIconView(size: 96)
            if let p = model.problem {
                ProblemView(problem: p).frame(maxWidth: 560)
            } else if case .gameUpdateOffer(let reason)? = model.waiting {
                VStack(spacing: 10) {
                    Text("PEAK has an update").font(.title2.weight(.semibold))
                    Text("It looks like \(reason). Without the update you may not be able to join \(model.hostName).")
                        .foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                    HStack(spacing: 12) {
                        Button("Play Without Updating") { model.choose(.alternative) }.controlSize(.large)
                        Button("Update PEAK") { model.choose(.proceed) }.keyboardShortcut(.defaultAction).controlSize(.large)
                    }
                    .padding(.top, 4)
                }
            } else if model.screen == .playing {
                Text("PEAK is running").font(.title2.weight(.semibold))
                Text("Have fun! This window tucks itself away. Join \(model.hostName) with a room code or from your Steam friends list.")
                    .foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                Button("Hide") { NSApp.keyWindow?.orderOut(nil) }
            } else if let a = model.activity {
                Text(a.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                ActivityBlock(activity: a).frame(maxWidth: 420)
            } else {
                ProgressView()
            }
            Spacer()
            HStack {
                NoticeBanner()
                Spacer()
                if model.isBusy && model.problem == nil && model.screen == .launching {
                    Button("Cancel") { model.cancelCurrent() }
                }
            }
        }
        .padding(28)
    }
}
