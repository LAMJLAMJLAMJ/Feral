#if canImport(SwiftUI) && os(macOS)
import FeralControl
import SwiftUI

extension AudioDeviceSummary {
    /// "MADIface XT · 196 in / 198 out · 48 kHz".
    var menuLabel: String {
        "\(name) · \(inputChannels) in / \(outputChannels) out · \(Int(sampleRate / 1000)) kHz"
            + (isAggregate ? " · aggregate (refused)" : "")
    }
}

/// The toolbar's sound card pop-up: the engine's one device, for its inputs and outputs. Choosing
/// another asks first, since the audio stops for a moment while it switches.
struct SoundCardPicker: View {
    @ObservedObject var model: EngineModel

    var body: some View {
        Menu {
            DeviceChoices(model: model)
        } label: {
            Label(model.currentDevice?.name ?? (model.selectedDevice ?? "Sound card"), systemImage: "hifispeaker.and.homepod")
        }
        .help("The engine's sound card, for its inputs and outputs: " + (model.currentDevice?.menuLabel ?? "none"))
        .disabled(!model.connected)
    }
}

/// The device list, as a pop-up's or the Audio menu's items.
struct DeviceChoices: View {
    @ObservedObject var model: EngineModel

    var body: some View {
        if model.devices.isEmpty {
            Text(model.connected ? "No audio devices" : "Not connected to the engine")
        }
        ForEach(model.devices) { d in
            Button {
                if !d.matches(model.selectedDevice) { model.pendingDevice = d }
            } label: {
                if d.matches(model.selectedDevice) {
                    Label(d.menuLabel, systemImage: "checkmark")
                } else {
                    Text(d.menuLabel)
                }
            }
            .disabled(d.isAggregate)
        }
        Divider()
        Button("Refresh the list") { model.refreshDevices() }
    }
}

/// The menu bar's Audio menu.
struct AudioMenu: View {
    @ObservedObject var model: EngineModel

    var body: some View {
        Section("Sound card (inputs and outputs)") {
            DeviceChoices(model: model)
        }
    }
}

/// Asks before switching the engine to another device.
struct DeviceSwitchConfirmation: ViewModifier {
    @ObservedObject var model: EngineModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Switch the engine to \(model.pendingDevice?.name ?? "")?",
            isPresented: Binding(get: { model.pendingDevice != nil }, set: { if !$0 { model.pendingDevice = nil } }),
            titleVisibility: .visible
        ) {
            Button("Switch") {
                if let d = model.pendingDevice { model.setDevice(d) }
                model.pendingDevice = nil
            }
            Button("Cancel", role: .cancel) { model.pendingDevice = nil }
        } message: {
            Text("The audio stops for a moment while the engine reopens on it. It is used for both inputs and outputs, "
                 + "and saved in engine.json." + channelNote)
        }
    }

    /// Warns when the device has fewer channels than the engine's settings use.
    private var channelNote: String {
        guard let d = model.pendingDevice, let need = model.meters.channelsNeeded else { return "" }
        var lacks: [String] = []
        if d.inputChannels < need.inputs { lacks.append("\(need.inputs) inputs (it has \(d.inputChannels))") }
        if d.outputChannels < need.outputs { lacks.append("\(need.outputs) outputs (it has \(d.outputChannels))") }
        return lacks.isEmpty ? "" : "\n\nThe settings use up to " + lacks.joined(separator: " and ")
            + "; channels it does not have stay silent."
    }
}

extension MeterStore {
    /// The highest device input and output channel the engine uses, from the meters.
    var channelsNeeded: (inputs: Int, outputs: Int)? {
        guard live else { return nil }
        return (firstInputChannel + inputs.count - 1, firstOutputChannel + outputs.count - 1)
    }
}
#endif
