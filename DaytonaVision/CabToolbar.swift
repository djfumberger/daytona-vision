import SwiftUI

/// The toolbar under the screen, shown and hidden by pinching the screen:
/// back to the main menu, reset the game, move the cab, into or out of the
/// arcade room, and the settings window (help is in settings). While placing it is just a Done button.
struct CabToolbar: View {
    let onDone: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if model.placing {
                Button(action: onDone) {
                    Text("Done")
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent)
            } else {
                buttons
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassBackgroundEffect(in: .capsule)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    if !model.launcherOpen { openWindow(id: LauncherView.windowID) }
                    await dismissImmersiveSpace()
                }
            } label: {
                Label("Menu", systemImage: "xmark")
            }
            .help("Menu")

            Button { model.resetGame() } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .help("Reset")

            Button { model.placing = true } label: {
                Label("Move", systemImage: "move.3d")
            }
            .help("Move")

            Button { model.fullImmersion.toggle() } label: {
                if model.fullImmersion {
                    Label("Leave the Arcade", systemImage: "arrow.down.right.and.arrow.up.left")
                } else {
                    Label("Arcade", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            .help(model.fullImmersion ? "Leave the Arcade" : "Arcade")

            WindowToggle(title: "Settings", symbol: "gearshape", id: SettingsView.windowID, isOpen: model.showSettings)
        }
        .labelStyle(.iconOnly)
    }
}

/// A button that opens or closes one of the app's windows, lit while it is open.
struct WindowToggle: View {
    let title: String
    let symbol: String
    let id: String
    let isOpen: Bool

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Toggle(isOn: Binding(
            get: { isOpen },
            set: { $0 ? openWindow(id: id) : dismissWindow(id: id) }
        )) {
            Label(title, systemImage: symbol)
        }
        .toggleStyle(.button)
        .help(title)
    }
}
