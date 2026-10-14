import AppKit
import PeakModdedCore
import SwiftUI

/// Sidebar material, like Finder/System Settings sidebars.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

struct AppIconView: View {
    var size: CGFloat = 64
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Small transient banner (update installed, diagnostics copied…).
struct NoticeBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let n = model.notice {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundColor(.accentColor)
                Text(n).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { model.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
            .transition(.opacity)
        }
    }
}

struct LocationBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let w = model.locationWarning {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "folder.badge.questionmark").foregroundColor(.orange)
                Text(w).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if !AppLocation.isTranslocated(Bundle.main.bundlePath) {
                    Button("Move to Applications") { model.moveToApplications() }.controlSize(.small)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
        }
    }
}

/// Determinate when the fraction is known, else indeterminate; detail text with tabular digits.
struct ActivityBlock: View {
    let activity: Activity
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = activity.progress {
                ProgressView(value: p).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if !activity.detail.isEmpty {
                Text(activity.detail).font(.callout).foregroundColor(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Plain error presentation: heading, next step, buttons, technical details on request.
struct ProblemView: View {
    @EnvironmentObject var model: AppModel
    let problem: FriendError
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.yellow)
                    .symbolRenderingMode(.multicolor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(problem.heading).font(.title3.weight(.semibold))
                    Text(problem.advice).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !problem.details.isEmpty {
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    ScrollView {
                        Text(problem.details)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                }
                .font(.callout)
            }
            HStack {
                Button("Copy Diagnostics") { model.copyDiagnostics() }
                Spacer()
                ForEach(Array(problem.actions.enumerated()), id: \.offset) { idx, action in
                    if idx == 0 {
                        Button(label(action)) { model.perform(action) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(label(action)) { model.perform(action) }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    func label(_ a: FriendError.Action) -> String {
        switch a {
        case .retry: return "Try Again"
        case .repair: return "Repair"
        case .openSteam: return "Open Steam"
        case .getSteam: return "Get Steam"
        case .openSoftwareUpdate: return "Open Software Update"
        case .installRosetta: return "Install Rosetta"
        case .playWithInstalledMods: return "Play with the Mods I Have"
        case .playNormal: return "Play Normal PEAK"
        case .openLogs: return "Show Logs"
        case .moveToApplications: return "Move to Applications"
        case .checkForUpdates: return "Check Again"
        case .cancel: return "Close"
        }
    }
}

struct BulletRow: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundColor(.accentColor).frame(width: 18)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
