import PeakModdedCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .setup: SetupView()
            case .home: HomeView()
            case .launching, .playing: LaunchView()
            case .message: MessageView()
            }
        }
        .frame(width: 720, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Final screens (uninstalled, move instructions).
struct MessageView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            AppIconView(size: 72)
            Text(model.message?.title ?? "").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text(model.message?.body ?? "").foregroundColor(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
    }
}
