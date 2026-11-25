import AppKit
import Combine
import CoreAudio
import SwiftUI

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Where the "Buy me a coffee" buttons go.
enum Support {
    static let url = URL(string: "https://buymeacoffee.com/cablebay")!
    static func open() { NSWorkspace.shared.open(url) }
}

/// Tells the Settings window to redraw only when something it shows changes (apps, devices, the stream device),
/// not on every fader move or meter tick, which made the window flicker.
final class SettingsMixerWatch: ObservableObject {
    private var cancellables = Set<AnyCancellable>()

    init(mixer: MixerModel, devices: DeviceManager) {
        let changes: [AnyPublisher<Void, Never>] = [
            mixer.$appChannels.map { _ in () }.eraseToAnyPublisher(),
            mixer.$streamDeviceInstalled.map { _ in () }.eraseToAnyPublisher(),
            mixer.$micEnabled.map { _ in () }.eraseToAnyPublisher(),
            mixer.$mixInputUIDs.map { _ in () }.eraseToAnyPublisher(),
            devices.$outputs.map { _ in () }.eraseToAnyPublisher(),
            devices.$inputs.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}

final class SettingsUIState: ObservableObject {
    @Published var driverMessage: String?
    @Published var uninstallMessage: String?
    @Published var working = false
}

struct SettingsView: View {
    static let size = CGSize(width: 480, height: 640)
    /// Room for a legacy (always visible) scroll bar beside the content, so it isn't cut off.
    static let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    static var windowSize: CGSize { CGSize(width: size.width + scrollerWidth, height: size.height) }

    @ObservedObject var settings: AppSettings
    let mixer: MixerModel
    @ObservedObject var watch: SettingsMixerWatch
    @ObservedObject var ui: SettingsUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(label: Text("General")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    Toggle("Open mixer panel when Cablebay starts", isOn: $settings.openPanelAtLaunch)
                    Toggle("Show mixer panel", isOn: $settings.panelVisible)
                    Toggle("Keep mixer panel above other windows", isOn: $settings.panelOnTop)
                    HStack {
                        Text("Scroll wheel speed")
                        Text("Slow").font(.system(size: 11)).foregroundColor(.secondary)
                        Slider(value: $settings.scrollSpeed, in: 0.2...3)
                            .frame(width: 180)
                        Text("Fast").font(.system(size: 11)).foregroundColor(.secondary)
                        Text(String(format: "%.1f%% per notch", settings.scrollSpeed))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Mixer size")
                        Picker("", selection: $settings.panelSize) {
                            Text("Small").tag(0)
                            Text("Medium").tag(1)
                            Text("Large").tag(2)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("Mixer")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Remember each channel's levels", isOn: $settings.rememberVolumes)
                    Toggle("Show apps that aren't playing right now", isOn: $settings.showIdleApps)
                    Button("Reset all channels") { mixer.resetAll() }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("Inputs")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tick every input you want as its own channel, each with its own levels and mute — for example your Mac's mic and your AirPods mic at the same time.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(mixer.inputDevices) { d in
                        Toggle(d.name, isOn: Binding(get: { mixer.isMixing(d.uid) },
                                                     set: { on in if on != mixer.isMixing(d.uid) { mixer.toggleMixInput(d.uid) } }))
                    }
                    Text("Using the AirPods mic switches AirPods to call-quality sound while it's in use. That's a Bluetooth limit of AirPods, not of Cablebay.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("Devices in the patch bay")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose which outputs and inputs appear in the floating panel and in the menu bar. Hidden devices keep working — they're just not shown. You can also use “Show…” under each patch bay.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                        GridRow {
                            Text("Outputs").font(.system(size: 11, weight: .semibold))
                            Text("Panel").font(.system(size: 10)).foregroundColor(.secondary)
                            Text("Menu bar").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        ForEach(mixer.allOutputs) { d in
                            visibilityRow(d.uid == MixerModel.streamDeviceUID ? "Mixer Stream" : d.name, d.uid)
                        }
                        GridRow {
                            Text("Inputs").font(.system(size: 11, weight: .semibold)).padding(.top, 6)
                        }
                        ForEach(mixer.inputDevices) { d in visibilityRow(d.name, d.uid) }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("Devices")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Keep my output and input when a new device connects", isOn: $settings.holdDevices)
                    Text("macOS switches sound to headphones, AirPods or a USB device as soon as it connects. With this on, Cablebay switches straight back to the output and input you picked. Your mix only plays on the outputs you pick.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("Per-app outputs")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Normally every app plays where the All apps channel is plugged in. Send an app somewhere else here (or in the patch bay).")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if mixer.appChannels.isEmpty {
                        Text("No apps playing right now.").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    ForEach(mixer.appChannels) { ch in
                        AppOutputRow(ch: ch, mixer: mixer)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("Stream device")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(mixer.streamDeviceInstalled ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(mixer.streamDeviceInstalled ? "“Mixer Stream” is installed"
                             : DriverInstaller.isInstalled ? "Installed — waiting for Core Audio" : "Not installed")
                    }
                    Text("“Mixer Stream” is a virtual audio device. Everything in the stream mix plays into it, and other apps (OBS, Zoom, Discord…) can pick “Mixer Stream” as their microphone. Installing asks for your Mac password and briefly restarts audio.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if DriverInstaller.isInstalled {
                            Button("Reinstall…") { run(DriverInstaller.install) }
                            Button("Uninstall…") { run(DriverInstaller.uninstall) }
                        } else {
                            Button("Install Mixer Stream…") { run(DriverInstaller.install) }
                        }
                        if ui.working { ProgressView().controlSize(.small) }
                    }
                    .disabled(ui.working)
                    if let message = ui.driverMessage {
                        Text(message).font(.system(size: 11)).foregroundColor(.orange)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("Permissions")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mixing apps uses macOS audio taps, so macOS asks once to let Cablebay record system audio. Mixing inputs also needs microphone access.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy Settings…") {
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
                        NSWorkspace.shared.open(url)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("Support Cablebay")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cablebay is free. If it's useful, a coffee helps fund updates.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: Support.open) {
                        Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color(red: 1.0, green: 0.867, blue: 0.0)))
                    }
                    .buttonStyle(.plain)
                    .help(Support.url.absoluteString)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("Uninstall")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Removes Cablebay from this Mac: the app, the Mixer Stream device, your settings, the login item, caches and the permissions macOS stored for it. Nothing is left behind.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Uninstall Cablebay…", action: uninstallEverything)
                            .foregroundColor(.red)
                        if ui.working { ProgressView().controlSize(.small) }
                    }
                    .disabled(ui.working)
                    if let message = ui.uninstallMessage {
                        Text(message).font(.system(size: 11)).foregroundColor(.orange)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Cablebay \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · Made by Nima Sarabi · © 2026")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(width: SettingsView.size.width)
        .wrappedInScroll(SettingsView.windowSize)
    }

    private func visibilityRow(_ name: String, _ uid: String) -> some View {
        GridRow {
            Text(name).lineLimit(1).frame(width: 220, alignment: .leading)
            Toggle("", isOn: Binding(get: { settings.isShown(uid, panel: true) },
                                     set: { settings.setShown($0, uid, panel: true) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            Toggle("", isOn: Binding(get: { settings.isShown(uid, panel: false) },
                                     set: { settings.setShown($0, uid, panel: false) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
        }
    }

    private func uninstallEverything() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Cablebay?"
        alert.informativeText = "This deletes the Cablebay app, the Mixer Stream audio device, your settings, the login item, caches and the permissions macOS stored for it. It can't be undone.\n\nmacOS asks for your password, and audio restarts for a moment."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        ui.working = true
        ui.uninstallMessage = nil
        mixer.leaveStreamDevice()
        DispatchQueue.global(qos: .userInitiated).async {
            let error = Uninstaller.removeAppAndDriver()
            DispatchQueue.main.async {
                ui.working = false
                if let error = error {
                    ui.uninstallMessage = error
                    return
                }
                mixer.shutdown()
                Uninstaller.removeUserDataAfterQuit()
                NSApp.terminate(nil)
            }
        }
    }

    private func run(_ action: @escaping () -> String?) {
        ui.working = true
        ui.driverMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let error = action()
            DispatchQueue.main.async {
                ui.working = false
                if let error = error {
                    ui.driverMessage = error
                } else {
                    mixer.shutdown()
                    DriverInstaller.relaunch()
                }
            }
        }
    }
}


struct AppOutputRow: View {
    @ObservedObject var ch: Channel
    let mixer: MixerModel

    var body: some View {
        HStack {
            Image(nsImage: ch.icon).resizable().frame(width: 16, height: 16)
            Text(ch.name).frame(width: 140, alignment: .leading).lineLimit(1)
            Picker("", selection: Binding(get: { ch.outputOverride?.first ?? "" },
                                          set: { $0.isEmpty ? mixer.followHeadphones(ch) : mixer.setOutputs(ch, [$0]) })) {
                Text("Same as All apps").tag("")
                ForEach(mixer.outputDevices) { Text($0.name).tag($0.uid) }
            }
            .labelsHidden()
            .frame(width: 240)
        }
    }
}

extension View {
    func wrappedInScroll(_ size: CGSize) -> some View {
        ScrollView { self }.frame(width: size.width, height: size.height)
    }
}
