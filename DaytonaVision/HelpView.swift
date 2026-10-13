import SwiftUI

/// How to drive, opened from settings in the cab, or from the toolbar on the
/// flat screen (controller only).
struct HelpView: View {
    static let windowID = "help"

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("How to drive").font(.title2.bold())

            if model.screenOpen {
                item("gamecontroller", "Controller",
                     "Left stick steers, the triggers are gas and brake, the shoulders shift. A, B, X and Y are the view buttons.")
                item("dollarsign.circle", "Starting a race",
                     "Options puts in a coin, Menu is Start. Settings has the operator buttons.")
                item("aspectratio", "Toolbar",
                     "Under the screen: reset the game, the screen's shape (the original or widescreen), this help, and settings. Close the window to go back to the start.")
            } else {
                item("hand.raised", "Hands",
                     "Grab the wheel's rim and turn it. Pinch your right thumb and index finger for gas, your left for brake.")
                item("gamecontroller", "Controller",
                     "Left stick steers, the triggers are gas and brake, the shoulders shift. A, B, X and Y are the view buttons; Options is a coin, Menu is Start.")
                item("dollarsign.circle", "Starting a race",
                     "Tap the coin slot, then START on the dash. Settings has the operator buttons.")
                item("hand.tap", "Toolbar",
                     "Pinch the screen (with your hands off the wheel) to show or hide the toolbar: back to the menu, reset the game, move the cab, go into or out of the arcade room, and settings (where this help is).")
            }
        }
        .padding(32)
        .frame(width: 460)
        .onAppear { model.showHelp = true }
        .onDisappear { model.showHelp = false }
    }

    private func item(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
