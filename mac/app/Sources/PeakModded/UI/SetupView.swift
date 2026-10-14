import AppKit
import PeakModdedCore
import SwiftUI

/// First-run assistant: steps in a sidebar, the current step on the right, buttons in a bottom bar.
struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            StepSidebar()
                .frame(width: 220)
                .background(VisualEffect(material: .sidebar))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LocationBanner()
                        NoticeBanner()
                        content
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 36)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder var content: some View {
        if let p = model.problem {
            if let s = model.activeStep { StepHeader(step: s) }
            ProblemView(problem: p)
        } else if model.waiting == .welcome {
            WelcomeContent()
        } else if model.setupFinished && model.activeStep == nil && model.activity == nil {
            DoneContent()
        } else if let s = model.activeStep {
            StepHeader(step: s)
            StepBody(step: s)
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder var bottomBar: some View {
        HStack {
            Button("Copy Diagnostics") { model.copyDiagnostics() }
                .help("Copies a short technical report you can send to \(model.hostName)")
            Spacer()
            if model.waiting == .welcome {
                Button("Set Up PEAK") { model.beginSetup() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            } else if model.setupFinished && model.activeStep == nil && model.problem == nil && !model.isBusy {
                Button("Play PEAK") { model.quitWhenGameEnds = false; model.play() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            } else if model.isBusy && model.problem == nil {
                Button("Stop") { model.cancelCurrent() }
            }
        }
    }
}

struct StepSidebar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppIconView(size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("PEAK (Modded)").font(.headline)
                    Text("Setup").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 20)
            .padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SetupStep.allCases) { step in
                    StepRow(step: step, state: model.stepStates[step] ?? .pending, isCurrent: model.activeStep == step)
                }
            }
            .padding(.horizontal, 8)
            Spacer()
            Text("Version \(AppInfo.version)").font(.caption2).foregroundColor(.secondary).padding(16)
        }
    }
}

struct StepRow: View {
    let step: SetupStep
    let state: StepUIState
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                switch state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                case .active: ProgressView().controlSize(.small).scaleEffect(0.8)
                case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
                case .blocked: Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                case .pending: Image(systemName: "circle").foregroundColor(.secondary.opacity(0.6))
                }
            }
            .frame(width: 18, height: 18)
            Text(step.title)
                .font(.callout.weight(isCurrent ? .semibold : .regular))
                .foregroundColor(state == .pending ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent ? Color.accentColor.opacity(0.14) : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(stateText))
    }

    var stateText: String {
        switch state {
        case .done: return "done"
        case .active: return "in progress"
        case .failed: return "needs attention"
        case .blocked: return "not possible on this Mac"
        case .pending: return "to do"
        }
    }
}

struct StepHeader: View {
    let step: SetupStep
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: step.symbol).font(.system(size: 26, weight: .regular)).foregroundColor(.accentColor).frame(width: 34)
            Text(step.title).font(.title2.weight(.semibold))
        }
    }
}

struct WelcomeContent: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                AppIconView(size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up PEAK for Mac").font(.largeTitle.weight(.semibold))
                    Text("Play PEAK with \(model.hostName)'s mods on this Mac.").foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("What happens").font(.headline)
                BulletRow(symbol: "shippingbox", text: "The app downloads what PEAK needs to run on a Mac and prepares it.")
                BulletRow(symbol: "arrow.down.circle", text: "Steam downloads PEAK's Windows files with your own Steam account. You'll paste one line into Steam.")
                BulletRow(symbol: "puzzlepiece.extension", text: "\(model.hostName)'s mods are installed, exactly like on his PC.")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("You'll need").font(.headline)
                BulletRow(symbol: "person.crop.circle", text: "Steam for Mac, signed in with the account that owns PEAK.")
                BulletRow(symbol: "internaldrive", text: "About 6 GB of free space and an internet connection.")
                BulletRow(symbol: "clock", text: "About 10–20 minutes, mostly downloading.")
            }
        }
    }
}

struct DoneContent: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundColor(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("All set").font(.largeTitle.weight(.semibold))
                    Text("PEAK and \(model.hostName)'s mods are ready.").foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                BulletRow(symbol: "dock.rectangle", text: "Keep PEAK (Modded) in your Dock: right-click its icon → Options → Keep in Dock.")
                BulletRow(symbol: "play.circle", text: "From now on, just click it. It updates the mods and starts PEAK.")
                BulletRow(symbol: "option", text: "Hold Option while opening it for more choices, like normal PEAK, Show FPS and Repair.")
                BulletRow(symbol: "mic", text: "The first time you play, macOS asks about the microphone. Click Allow for voice chat.")
            }
        }
    }
}

/// The body of each step while it runs or waits for the friend.
struct StepBody: View {
    @EnvironmentObject var model: AppModel
    let step: SetupStep

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case .rosetta:
                Text("PEAK's Windows version runs through Rosetta, Apple's translator for Intel apps. macOS shows its own window: click **Install** and follow the steps.")
                    .fixedSize(horizontal: false, vertical: true)
                if model.waiting == .rosetta {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for Rosetta…").foregroundColor(.secondary)
                        Spacer()
                        Button("Show the Rosetta Window Again") { model.perform(.installRosetta) }
                    }
                }
            case .steam:
                SteamStepBody()
            case .game:
                ConsoleGuideView()
            default:
                if let a = model.activity {
                    Text(a.title).font(.headline)
                    ActivityBlock(activity: a)
                }
                if model.waiting == .adoptConfirm {
                    AdoptConfirm()
                }
            }
        }
    }
}

struct SteamStepBody: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.waiting == .steamInstall {
                Text("PEAK (Modded) uses the normal Steam app for Mac, signed in with your own account. Steam isn't installed yet.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Get Steam for Mac") { model.perform(.getSteam) }.keyboardShortcut(.defaultAction)
                    Spacer()
                }
                Text("Install it, open it once, and sign in. This window continues by itself.").font(.callout).foregroundColor(.secondary)
            } else {
                Text("Open Steam and sign in with the account that owns PEAK. Your password only ever goes into Steam itself.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Steam") { model.perform(.openSteam) }.keyboardShortcut(.defaultAction)
                    Spacer()
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Steam to start…").font(.callout).foregroundColor(.secondary)
                }
            }
        }
    }
}

struct AdoptConfirm: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PEAK's folder already has another mod setup").font(.headline)
            Text("PeakPack can take it over so \(model.hostName)'s mods work. Your saves aren't affected.")
                .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.choose(.cancel) }
                Button("Use \(model.hostName)'s Mods") { model.choose(.proceed) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
