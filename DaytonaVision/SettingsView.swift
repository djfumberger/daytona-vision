import SwiftUI
import UniformTypeIdentifiers

/// The in-game settings window, opened from the cab's or the screen window's
/// toolbar: the display
/// (the room and the screen's look, with the CRT tuning one push in) and the
/// controls, with the operator buttons. The ROM set is chosen out of the game, in `RomSettingsView`.
struct SettingsView: View {
    static let windowID = "settings"

    enum Tab: String, CaseIterable { case display = "Display", controls = "Controls" }

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// Playing on the flat screen: the cab's settings (the room, 3D, the wheel
    /// and pinching for gas) don't apply there, so they are left out, as is
    /// help (the screen window's toolbar has it).
    private var onScreen: Bool { model.screenOpen }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Picker("Section", selection: $model.settingsTab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                switch model.settingsTab {
                case .display:
                    Section {
                        if !onScreen { Toggle("Arcade room", isOn: $model.fullImmersion) }
                        Picker("CRT", selection: $model.crtTube) {
                            ForEach(CRTSettings.Tube.allCases, id: \.self) { Text($0.title) }
                        }
                        .pickerStyle(.menu)
                    }

                    if !onScreen {
                        Section {
                            Toggle("3D", isOn: $model.stereo3D)
                            if model.stereo3D {
                                VStack(alignment: .leading) {
                                    LabeledContent("Depth", value: "\(Int(model.stereoDepth))")
                                    Slider(value: $model.stereoDepth, in: AppModel.stereoDepthRange, step: 1)
                                }
                            }
                        }

                        Section {
                            Button { openWindow(id: HelpView.windowID) } label: {
                                Label("Help", systemImage: "questionmark.circle")
                            }
                        }
                    }

                    Section {
                        NavigationLink {
                            CRTDebugPanel().navigationTitle("Debug")
                        } label: {
                            Label("Debug", systemImage: "slider.horizontal.3")
                        }
                    }

                case .controls:
                    Section {
                        if onScreen {
                            Toggle("Auto gas", isOn: $model.autoGas)
                        } else {
                            Picker("Gas", selection: $model.autoGas) {
                                Text("Pinch").tag(false)
                                Text("Auto").tag(true)
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    Section(onScreen ? "Controller" : "Wheel") {
                        if !onScreen {
                            VStack(alignment: .leading) {
                                LabeledContent("Turn to full lock", value: "\(Int(model.wheelLockDegrees))°")
                                Slider(value: $model.wheelLockDegrees, in: 45...180, step: 5)
                            }
                        }

                        VStack(alignment: .leading) {
                            LabeledContent("Stick sensitivity", value: "\(Int(model.stickSensitivity * 100))%")
                            Slider(value: $model.stickSensitivity, in: 0...1)
                        }
                    }

                    Section("Sound") {
                        VStack(alignment: .leading) {
                            Text("Volume")
                            Slider(value: $model.volume, in: 0...1)
                        }
                    }

                    Section {
                        HStack(spacing: 12) {
                            Button("Test") { model.tap(UInt32(DT_BTN_TEST)) }
                            Button("Service") { model.tap(UInt32(DT_BTN_SERVICE)) }
                        }
                    } header: {
                        Text("Operator")
                    } footer: {
                        Text("Test opens the game's operator menu; Service adds a credit.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
        }
        .frame(width: 480, height: 600)
        .onAppear { model.showSettings = true }
        .onDisappear { model.showSettings = false }
    }
}

/// The out-of-game settings, opened from the start volume: the ROM set, and a
/// link to Scanline.
struct RomSettingsView: View {
    static let windowID = "romSettings"

    @Environment(AppModel.self) private var model

    @State private var picking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Game") { game }
                if let error = model.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section("More from us") {
                    Link(destination: URL(string: "https://playscanline.com")!) {
                        LabeledContent("Scanline", value: "Retro emulator for Apple Vision Pro")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
        }
        .frame(width: 480, height: 440)
        .fileImporter(isPresented: $picking, allowedContentTypes: Self.romTypes) { result in
            if case .success(let url) = result { model.importROM(from: url) }
        }
    }

    static let romTypes: [UTType] = [.zip] + [UTType(filenameExtension: "7z")].compactMap { $0 }

    /// The ROM set: its name, a cross if it failed its check (with why), and
    /// the way to choose another.
    @ViewBuilder private var game: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(model.romReady ? GameSession.romSetName : "None")
                if model.romReady, model.romOK {
                    Menu {
                        Button("Choose a Different ROM Set…", systemImage: "folder") { picking = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .buttonStyle(.borderless)
                    .buttonBorderShape(.circle)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text("ROM set")
                if model.romReady, !model.romOK {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
        }

        if model.romReady, !model.romOK {
            if let problem = model.romProblem {
                Text(problem).foregroundStyle(.red)
            }
            Button("Choose a different ROM set…") { picking = true }
        }

        if !model.romReady {
            Text("Choose your own \(GameSession.romSetName).zip (or .7z). It is checked and copied into the app.")
                .foregroundStyle(.secondary)
            Button("Choose ROM set…") { picking = true }
        }
    }
}
