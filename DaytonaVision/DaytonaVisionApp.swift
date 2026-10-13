import SwiftUI

@main
struct DaytonaVisionApp: App {
    @State private var model = AppModel()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup(id: LauncherView.windowID) {
            LauncherView()
                .environment(model)
        }
        .windowStyle(.volumetric)
        .defaultSize(
            width: Double(LauncherView.size.x),
            height: Double(LauncherView.size.y),
            depth: Double(LauncherView.size.z),
            in: .meters
        )
        // Launches always open here, never to a window left open last time.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)

        // The flat screen (the Screen mode): a plain window, the monitor's shape.
        WindowGroup(id: ScreenWindow.windowID, for: String.self) { _ in
            ScreenWindow()
                .environment(model)
        }
        .defaultSize(width: ScreenWindow.defaultHeight * model.screenShape.aspect, height: ScreenWindow.defaultHeight)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        WindowGroup(id: SettingsView.windowID) {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { _, _ in WindowPlacement(.utilityPanel) }

        WindowGroup(id: RomSettingsView.windowID) {
            RomSettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        WindowGroup(id: HelpView.windowID) {
            HelpView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { _, _ in WindowPlacement(.utilityPanel) }

        ImmersiveSpace(id: AppModel.cabSpaceID) {
            CabImmersiveView()
                .environment(model)
        }
        .immersionStyle(selection: Binding(
            get: { model.fullImmersion ? FullImmersionStyle.full as any ImmersionStyle : MixedImmersionStyle.mixed },
            set: { model.fullImmersion = $0 is FullImmersionStyle }
        ), in: .mixed, .full)
        .upperLimbVisibility(.visible)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.pauseGame() }
        }
    }
}
