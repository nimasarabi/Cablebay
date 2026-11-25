import AppKit
import CoreAudio
import SwiftUI

// The patch bay, laid out like a studio desk: CHANNELS along the top (All apps, every app, and any
// microphone you've turned on), the LINE IN and LINE OUT jacks along the bottom, and cables between them.
// Pick a channel (tap it), then tap a LINE OUT to plug it in or pull it out — or drag a cable from the
// channel down to an output. Blue cables use the channel's YOU fader, dashed purple ones go to Mixer Stream
// and use its STREAM fader, yellow ones carry a LINE IN up to its channel.

enum RouteStyle {
    static let inputTint = HW.ledYellow
}

/// Which channel the patch bay is editing, and a cable being dragged. One per place it's shown.
final class RoutingSelection: ObservableObject {
    struct Drag { let sourceID: String; let point: CGPoint }
    static let panel = RoutingSelection()
    static let menu = RoutingSelection()
    @Published var sourceID: String? = MixerModel.allAppsID
    @Published var drag: Drag?
}

/// Marks a control so pressing it never drags the floating panel (no-op outside the panel).
struct PanelHit: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id = id { content.panelControl(id) } else { content }
    }
}

// MARK: - Layout

/// Positions of every tile and socket, worked out from the counts, so cables land exactly.
struct PatchLayout {
    static let baseTile = CGSize(width: 66, height: 68)
    static let gap: CGFloat = 8
    static let groupGap: CGFloat = 26
    static let labelHeight: CGFloat = 18
    static let cableHeight: CGFloat = 78

    /// Tiles per group: top = [All apps + apps, input channels], bottom = [line ins + "add", line outs].
    let top: [Int]
    let bottom: [Int]
    var scale: CGFloat = 1

    var tileW: CGFloat { PatchLayout.baseTile.width * scale }
    var tileH: CGFloat { PatchLayout.baseTile.height * scale }
    var gap: CGFloat { PatchLayout.gap * scale }
    var groupGap: CGFloat { PatchLayout.groupGap * scale }

    func width(of groups: [Int]) -> CGFloat {
        let used = groups.filter { $0 > 0 }
        let tiles = used.reduce(0, +)
        guard tiles > 0 else { return 0 }
        return CGFloat(tiles) * tileW + CGFloat(tiles - used.count) * gap + CGFloat(used.count - 1) * groupGap
    }

    var contentWidth: CGFloat { max(width(of: top), width(of: bottom)) }
    /// Room under the jacks for a hanging tag like "MUTED".
    static let bottomRoom: CGFloat = 10
    var height: CGFloat { PatchLayout.labelHeight * 2 + tileH * 2 + PatchLayout.cableHeight + PatchLayout.bottomRoom }
    var topY: CGFloat { PatchLayout.labelHeight }
    var bottomLabelY: CGFloat { topY + tileH + PatchLayout.cableHeight }
    var bottomY: CGFloat { bottomLabelY + PatchLayout.labelHeight }

    /// Left edge of every tile, group by group, centred in `width`.
    func xs(_ groups: [Int], in width: CGFloat) -> [[CGFloat]] {
        var x = ((width - self.width(of: groups)) / 2).rounded()
        var started = false
        var result: [[CGFloat]] = []
        for n in groups {
            var g: [CGFloat] = []
            if n > 0 {
                if started { x += groupGap - gap }
                started = true
            }
            for _ in 0..<n {
                g.append(x)
                x += tileW + gap
            }
            result.append(g)
        }
        return result
    }

    /// The layout for the model's current channels and the devices shown here,
    /// shrunk (down to 80%) to fit `available`.
    static func make(_ model: MixerModel, hidden: Set<String>, available: CGFloat? = nil) -> PatchLayout {
        let lineIns = model.inputChannels.filter { !hidden.contains($0.deviceUID ?? "") }.count
        let outs = model.outputDevices.filter { !hidden.contains($0.uid) }.count
            + (hidden.contains(MixerModel.streamDeviceUID) ? 0 : 1)
        let top = [1 + model.appChannels.count, model.inputChannels.count]
        let bottom = [lineIns + 1, outs]
        var layout = PatchLayout(top: top, bottom: bottom)
        if let available = available, layout.contentWidth > available {
            layout.scale = max(0.8, available / layout.contentWidth)
        }
        return layout
    }
}

// MARK: - Patch bay

struct RoutingBoard: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var devices: DeviceManager
    @ObservedObject var selection: RoutingSelection
    @ObservedObject var settings: AppSettings
    /// True in the floating panel, false in the menu bar dropdown (each has its own list of shown devices).
    let inPanel: Bool
    var openSettings: () -> Void

    private var panelID: String? { inPanel ? "panel.route" : nil }
    private var hidden: Set<String> { Set(inPanel ? settings.hiddenInPanel : settings.hiddenInMenu) }

    var body: some View {
        let hidden = self.hidden
        let height = PatchLayout.make(model, hidden: hidden).height
        let selected = selectedChannel
        return VStack(alignment: .leading, spacing: 8) {
            Text("Tap a channel, then tap an output to plug it in or pull it out — or drag a cable from a channel down to an output.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                let layout = PatchLayout.make(model, hidden: hidden, available: geo.size.width)
                let width = max(geo.size.width, layout.contentWidth)
                ScrollView(.horizontal, showsIndicators: layout.contentWidth > geo.size.width) {
                    PatchCanvas(model: model, devices: devices, selection: selection, layout: layout, width: width,
                                hidden: hidden, panelID: panelID, openSettings: openSettings)
                        .frame(width: width, height: layout.height)
                }
            }
            .frame(height: height)
            if let ch = selected, ch.kind == .app, ch.outputOverride != nil {
                Button(action: { model.followHeadphones(ch) }) {
                    Label("\(ch.name) has its own outputs — follow All apps again", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .modifier(PanelHit(id: panelID.map { "\($0).reset" }))
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    MacDeviceRow(model: model, devices: devices, output: true, hidden: hidden, panelID: panelID)
                    MacDeviceRow(model: model, devices: devices, output: false, hidden: hidden, panelID: panelID)
                }
                Button(action: showDevicesMenu) {
                    Label("Show…", systemImage: "eye")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Choose which outputs and inputs appear here")
                .modifier(PanelHit(id: panelID.map { "\($0).show" }))
            }
        }
    }

    /// Tick the devices to show in this patch bay.
    private func showDevicesMenu() {
        var items: [PopupMenu.Item] = [.header(inPanel ? "Show in the floating panel" : "Show in the menu bar"), .header("Outputs")]
        for d in model.allOutputs {
            let name = d.uid == MixerModel.streamDeviceUID ? "Mixer Stream" : d.name
            items.append(.item(name, checked: settings.isShown(d.uid, panel: inPanel)) {
                settings.setShown(!settings.isShown(d.uid, panel: inPanel), d.uid, panel: inPanel)
            })
        }
        items.append(.separator)
        items.append(.header("Inputs"))
        for d in model.inputDevices {
            items.append(.item(d.name, checked: settings.isShown(d.uid, panel: inPanel)) {
                settings.setShown(!settings.isShown(d.uid, panel: inPanel), d.uid, panel: inPanel)
            })
        }
        PopupMenu.show(items)
    }

    private var selectedChannel: Channel? {
        return (model.appChannels + model.inputChannels).first { $0.id == selection.sourceID }
    }
}

/// The drawing: labels, cables, then tiles, at a known width.
private struct PatchCanvas: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var devices: DeviceManager
    @ObservedObject var selection: RoutingSelection
    let layout: PatchLayout
    let width: CGFloat
    let hidden: Set<String>
    let panelID: String?
    let openSettings: () -> Void

    private var apps: [Channel] { model.appChannels }
    private var inputChannels: [Channel] { model.inputChannels }
    private var outputs: [AudioDevice] { model.outputDevices.filter { !hidden.contains($0.uid) } }
    private var showStream: Bool { !hidden.contains(MixerModel.streamDeviceUID) }
    /// Input channels whose LINE IN jack is shown here.
    private var lineIns: [Channel] { inputChannels.filter { !hidden.contains($0.deviceUID ?? "") } }
    private var topXs: [[CGFloat]] { layout.xs(layout.top, in: width) }
    private var bottomXs: [[CGFloat]] { layout.xs(layout.bottom, in: width) }

    /// The channel being edited: All apps, an app, or an input channel.
    private var selectedID: String {
        let ids = [MixerModel.allAppsID] + apps.map { $0.id } + inputChannels.map { $0.id }
        return ids.contains(selection.sourceID ?? "") ? selection.sourceID! : MixerModel.allAppsID
    }

    // Sockets: bottom centre of a channel tile, top centre of a jack tile.
    private func channelSocket(_ x: CGFloat) -> CGPoint { CGPoint(x: x + layout.tileW / 2, y: layout.topY + layout.tileH) }
    private func jackSocket(_ x: CGFloat) -> CGPoint { CGPoint(x: x + layout.tileW / 2, y: layout.bottomY) }
    private var outputXs: [CGFloat] { bottomXs[1] }           // devices, then Mixer Stream last
    private var streamSocket: CGPoint? { showStream ? jackSocket(outputXs[outputs.count]) : nil }

    var body: some View {
        ZStack(alignment: .topLeading) {
            labels
            cables
            dragCable
            channelTiles
            lineInTiles
            lineOutTiles
        }
        .coordinateSpace(name: "patchbay")
    }

    // MARK: Labels

    private var labels: some View {
        let t = topXs, b = bottomXs
        return ZStack(alignment: .topLeading) {
            groupLabel("CHANNELS").padding(.leading, t[0].first ?? 0)
            if let x = t[1].first { groupLabel("MIC CHANNELS").padding(.leading, x) }
            groupLabel("LINE IN").padding(.leading, b[0].first ?? 0).padding(.top, layout.bottomLabelY)
            if let x = b[1].first { groupLabel("LINE OUT").padding(.leading, x).padding(.top, layout.bottomLabelY) }
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.8)
            .foregroundColor(.secondary)
            .fixedSize()
            .frame(height: PatchLayout.labelHeight, alignment: .top)
    }

    // MARK: Cables

    private func outputSockets(_ ch: Channel) -> [CGPoint] {
        var points: [CGPoint] = []
        for uid in model.monitorUIDs(for: ch) {
            if let k = outputs.firstIndex(where: { $0.uid == uid }) { points.append(jackSocket(outputXs[k])) }
        }
        return points
    }

    private var cables: some View {
        let youMaster = !model.monitorMasterMuted
        let streamMaster = !model.streamMasterMuted
        let stream: CGPoint? = model.streamDeviceInstalled ? streamSocket : nil
        let selected = selectedID
        let t = topXs
        let jackXs = bottomXs[0]
        let shownLineIns = lineIns
        return ZStack(alignment: .topLeading) {
            // LINE IN up to its channel.
            ForEach(shownLineIns.indices, id: \.self) { j in
                if let c = inputChannels.firstIndex(where: { $0.id == shownLineIns[j].id }) {
                    Cable(from: jackSocket(jackXs[j]),
                          to: CGPoint(x: t[1][c] + layout.tileW * 0.3, y: layout.topY + layout.tileH),
                          color: RouteStyle.inputTint, opacity: shownLineIns[j].id == selected ? 0.95 : 0.55,
                          width: 2, dashed: false)
                }
            }
            // Channels down to their outputs.
            ForEach(apps.indices, id: \.self) { i in
                SourceCables(ch: apps[i], from: channelSocket(t[0][i + 1]), youTo: outputSockets(apps[i]),
                             streamTo: stream, youMaster: youMaster, streamMaster: streamMaster,
                             highlighted: selected == apps[i].id || selected == MixerModel.allAppsID)
            }
            ForEach(inputChannels.indices, id: \.self) { j in
                SourceCables(ch: inputChannels[j], from: channelSocket(t[1][j]), youTo: outputSockets(inputChannels[j]),
                             streamTo: stream, youMaster: youMaster, streamMaster: streamMaster,
                             highlighted: selected == inputChannels[j].id)
            }
        }
        .allowsHitTesting(false)
    }

    /// The cable that follows the pointer while you drag from a channel.
    @ViewBuilder private var dragCable: some View {
        if let drag = selection.drag, let from = socketFor(drag.sourceID) {
            Cable(from: from, to: drag.point, color: .primary, opacity: 0.8, width: 2.5, dashed: false)
                .allowsHitTesting(false)
        }
    }

    private func socketFor(_ id: String) -> CGPoint? {
        let t = topXs
        if id == MixerModel.allAppsID { return channelSocket(t[0][0]) }
        if let i = apps.firstIndex(where: { $0.id == id }) { return channelSocket(t[0][i + 1]) }
        if let j = inputChannels.firstIndex(where: { $0.id == id }) { return channelSocket(t[1][j]) }
        return nil
    }

    // MARK: Channel tiles

    private var channelTiles: some View {
        let t = topXs
        let selected = selectedID
        return ZStack(alignment: .topLeading) {
            channelTile(id: MixerModel.allAppsID, selected: selected == MixerModel.allAppsID) {
                PatchTile(icon: .symbol("square.grid.2x2.fill", HW.you), name: "All apps", scale: layout.scale,
                          style: selected == MixerModel.allAppsID ? .selected : .normal, socket: .bottom,
                          badge: nil, level: nil)
            }
            .help("All apps at once — outputs you plug in here apply to every app, and to new apps")
            .padding(.leading, t[0][0]).padding(.top, layout.topY)

            ForEach(apps.indices, id: \.self) { i in
                channelTile(id: apps[i].id, selected: selected == apps[i].id) {
                    AppPatchTile(ch: apps[i], scale: layout.scale, selected: selected == apps[i].id)
                }
                .padding(.leading, t[0][i + 1]).padding(.top, layout.topY)
            }
            ForEach(inputChannels.indices, id: \.self) { j in
                channelTile(id: inputChannels[j].id, selected: selected == inputChannels[j].id) {
                    PatchTile(icon: .symbol(symbolFor(inputChannels[j]), RouteStyle.inputTint), name: inputChannels[j].name,
                              scale: layout.scale, style: selected == inputChannels[j].id ? .selected : .normal,
                              socket: .bottom, badge: nil, level: inputChannels[j].level)
                }
                .padding(.leading, t[1][j]).padding(.top, layout.topY)
            }
        }
    }

    private func symbolFor(_ ch: Channel) -> String {
        return devices.inputs.first { $0.uid == ch.deviceUID }?.symbol(input: true) ?? "mic.fill"
    }

    /// Tap to edit this channel; drag to pull a cable from it.
    private func channelTile<Content: View>(id: String, selected: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .contentShape(Rectangle())
            .onTapGesture { selection.sourceID = id }
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named("patchbay"))
                    .onChanged { v in
                        if selection.sourceID != id { selection.sourceID = id }
                        selection.drag = RoutingSelection.Drag(sourceID: id, point: v.location)
                    }
                    .onEnded { v in
                        selection.drag = nil
                        dropCable(from: id, at: v.location)
                    }
            )
            .modifier(PanelHit(id: panelID.map { "\($0).ch.\(id)" }))
    }

    private func dropCable(from id: String, at point: CGPoint) {
        var targets: [(String, CGRect)] = outputs.enumerated().map { k, dev in
            (dev.uid, CGRect(x: outputXs[k], y: layout.bottomY, width: layout.tileW, height: layout.tileH))
        }
        if model.streamDeviceInstalled && showStream {
            targets.append((MixerModel.streamDeviceUID,
                            CGRect(x: outputXs[outputs.count], y: layout.bottomY, width: layout.tileW, height: layout.tileH)))
        }
        guard let uid = targets.first(where: { $0.1.insetBy(dx: -4, dy: -14).contains(point) })?.0 else { return }
        if id == MixerModel.allAppsID {
            model.toggleAllApps(uid, connectOnly: true)
        } else if let ch = (apps + inputChannels).first(where: { $0.id == id }) {
            model.connect(ch, uid)
        }
    }

    // MARK: LINE IN tiles

    private var lineInTiles: some View {
        let xs = bottomXs[0]
        let selected = selectedID
        let shown = lineIns
        let available = model.inputDevices.filter { d in
            !hidden.contains(d.uid) && !inputChannels.contains { $0.deviceUID == d.uid }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(shown.indices, id: \.self) { j in
                let ch = shown[j]
                PatchTile(icon: .symbol(symbolFor(ch), RouteStyle.inputTint), name: ch.name, scale: layout.scale,
                          style: .on(RouteStyle.inputTint), socket: .top,
                          badge: .remove { if let uid = ch.deviceUID { model.toggleMixInput(uid) } },
                          level: ch.level, mac: ch.deviceUID == model.macInputUID)
                    .contentShape(Rectangle())
                    .onTapGesture { selection.sourceID = ch.id }
                    .help("\(ch.name) is on — it feeds the \(ch.name) channel above. Click × to turn it off.")
                    .modifier(PanelHit(id: panelID.map { "\($0).in.\(ch.id)" }))
                    .padding(.leading, xs[j]).padding(.top, layout.bottomY)
                    .opacity(selected == ch.id || selected == MixerModel.allAppsID ? 1 : 0.85)
            }
            Button(action: {
                var items: [PopupMenu.Item] = [.header("Turn on an input")]
                for d in available {
                    items.append(.item(d.name, checked: false) {
                        model.toggleMixInput(d.uid)
                        selection.sourceID = "__mic__:" + d.uid
                    })
                }
                if available.isEmpty { items.append(.disabled("Every input shown here is already on")) }
                PopupMenu.show(items)
            }) {
                PatchTile(icon: .symbol("plus", .secondary), name: "Add input", scale: layout.scale,
                          style: .dashed, socket: .none, badge: nil, level: nil)
            }
            .buttonStyle(.plain)
            .help("Turn on a microphone or other input — it gets its own channel")
            .modifier(PanelHit(id: panelID.map { "\($0).in.add" }))
            .padding(.leading, xs[shown.count]).padding(.top, layout.bottomY)
        }
    }

    // MARK: LINE OUT tiles

    private var lineOutTiles: some View {
        let xs = outputXs
        return ZStack(alignment: .topLeading) {
            ForEach(outputs.indices, id: \.self) { k in
                outputTile(outputs[k])
                    .padding(.leading, xs[k]).padding(.top, layout.bottomY)
            }
            if showStream {
                streamTile
                    .padding(.leading, xs[outputs.count]).padding(.top, layout.bottomY)
            }
        }
    }

    /// How the selected channel is plugged into an output.
    private func plug(_ uid: String) -> PatchTile.Badge {
        if selectedID == MixerModel.allAppsID {
            let (n, total) = model.allAppsConnection(uid)
            if total == 0 {
                let on = uid == MixerModel.streamDeviceUID ? model.allAppsToStream : model.monitorDestinationUIDs.contains(uid)
                return on ? .plugged : .unplugged
            }
            return n == total ? .plugged : (n == 0 ? .unplugged : .partly)
        }
        guard let ch = (apps + inputChannels).first(where: { $0.id == selectedID }) else { return .unplugged }
        return model.isConnected(ch, uid) ? .plugged : .unplugged
    }

    private func tap(_ uid: String) {
        if selectedID == MixerModel.allAppsID {
            model.toggleAllApps(uid)
        } else if let ch = (apps + inputChannels).first(where: { $0.id == selectedID }) {
            model.toggleConnection(ch, uid)
        }
    }

    private var selectedName: String {
        if selectedID == MixerModel.allAppsID { return "All apps" }
        return (apps + inputChannels).first { $0.id == selectedID }?.name ?? ""
    }

    private func outputTile(_ dev: AudioDevice) -> some View {
        let badge = plug(dev.uid)
        let plugged = badge == .plugged || badge == .partly
        return Button(action: { tap(dev.uid) }) {
            PatchTile(icon: .symbol(dev.symbol(input: false), HW.you), name: dev.name, scale: layout.scale,
                      style: plugged ? .on(HW.you) : .normal, socket: .top, badge: badge, level: nil,
                      mac: dev.uid == model.macOutputUID)
        }
        .buttonStyle(.plain)
        .help(badge == .plugged ? "\(selectedName) plays on \(dev.name) — click to pull the cable out"
                                : "Click to plug \(selectedName) into \(dev.name)")
        .modifier(PanelHit(id: panelID.map { "\($0).out.\(dev.uid)" }))
    }

    @ViewBuilder private var streamTile: some View {
        if model.streamDeviceInstalled {
            let uid = MixerModel.streamDeviceUID
            let badge = plug(uid)
            let plugged = badge == .plugged || badge == .partly
            Button(action: { tap(uid) }) {
                PatchTile(icon: .symbol("dot.radiowaves.left.and.right", HW.stream), name: "Mixer Stream",
                          scale: layout.scale, style: plugged ? .on(HW.stream) : .normal, socket: .top,
                          badge: badge, level: nil, note: model.streamMasterMuted ? "MUTED" : nil,
                          mac: uid == model.macOutputUID)
            }
            .buttonStyle(.plain)
            .help((badge == .plugged ? "\(selectedName) goes into your stream — click to pull the cable out"
                                     : "Click to send \(selectedName) into your stream (OBS, Zoom, Clubdeck…)")
                  + (model.streamMasterMuted ? "\nThe STREAM master fader is muted." : ""))
            .modifier(PanelHit(id: panelID.map { "\($0).stream" }))
        } else {
            Button(action: openSettings) {
                PatchTile(icon: .symbol("exclamationmark.triangle.fill", HW.ledOrange), name: "Install stream",
                          scale: layout.scale, style: .dashed, socket: .top, badge: nil, level: nil)
            }
            .buttonStyle(.plain)
            .help("Mixer Stream isn't installed — click to open Setup and install it")
            .modifier(PanelHit(id: panelID.map { "\($0).stream" }))
        }
    }
}

// MARK: - Cables

/// A cable hanging between two sockets.
struct Cable: View {
    let from: CGPoint
    let to: CGPoint
    let color: Color
    let opacity: Double
    let width: CGFloat
    let dashed: Bool

    var body: some View {
        Path { p in
            p.move(to: from)
            let dy = abs(to.y - from.y) * 0.55 + 10
            let down: CGFloat = to.y >= from.y ? 1 : -1
            p.addCurve(to: to, control1: CGPoint(x: from.x, y: from.y + dy * down),
                       control2: CGPoint(x: to.x, y: to.y - dy * down))
        }
        .stroke(color.opacity(opacity), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dashed ? [5, 4] : []))
    }
}

/// One channel's cables to its outputs. Observes the channel, so cables follow faders, mutes and patching live.
/// A cable that is plugged in but silent right now (muted, fader at zero, master muted) stays drawn, faint.
struct SourceCables: View {
    @ObservedObject var ch: Channel
    let from: CGPoint
    let youTo: [CGPoint]
    let streamTo: CGPoint?
    let youMaster: Bool
    let streamMaster: Bool
    let highlighted: Bool

    var body: some View {
        let youAudible = youMaster && !ch.monitorMuted && ch.monitorLevel > 0.005
        let streamAudible = streamMaster && !ch.streamMuted && ch.streamLevel > 0.005
        let toStream = ch.toStream ? streamTo : nil
        let dim = highlighted ? 1.0 : 0.35
        ZStack(alignment: .topLeading) {
            ForEach(Array(youTo.enumerated()), id: \.offset) { _, to in
                Cable(from: from, to: to, color: HW.you, opacity: strength(youAudible, ch.monitorLevel) * dim,
                      width: youAudible ? 2.2 : 1.3, dashed: false)
                plugDot(to, HW.you.opacity(dim))
            }
            if let to = toStream {
                Cable(from: from, to: to, color: HW.stream, opacity: strength(streamAudible, ch.streamLevel) * dim,
                      width: streamAudible ? 2.2 : 1.3, dashed: true)
                plugDot(to, HW.stream.opacity(dim))
            }
        }
    }

    private func strength(_ audible: Bool, _ level: Double) -> Double {
        return audible ? 0.5 + 0.5 * level : 0.28
    }

    private func plugDot(_ at: CGPoint, _ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7).offset(x: at.x - 3.5, y: at.y - 3.5)
    }
}

/// Explains the cable colours.
struct RoutingLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            item(dashed: false, color: HW.you, text: "you hear")
            item(dashed: true, color: HW.stream, text: "stream")
            item(dashed: false, color: RouteStyle.inputTint, text: "line in")
        }
    }

    private func item(dashed: Bool, color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 1))
                p.addLine(to: CGPoint(x: 14, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [4, 3] : []))
            .frame(width: 14, height: 2)
            Text(text)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Tiles

/// A square patch-bay tile: big icon, name underneath, a socket where cables plug in.
struct PatchTile: View {
    enum Icon { case symbol(String, Color), image(NSImage) }
    enum Style: Equatable { case normal, selected, on(Color), dashed }
    enum Socket { case top, bottom, none }
    enum Badge: Equatable {
        case plugged, partly, unplugged
        case remove(() -> Void)
        static func == (a: Badge, b: Badge) -> Bool {
            switch (a, b) {
            case (.plugged, .plugged), (.partly, .partly), (.unplugged, .unplugged), (.remove, .remove): return true
            default: return false
            }
        }
    }

    let icon: Icon
    let name: String
    let scale: CGFloat
    let style: Style
    let socket: Socket
    let badge: Badge?
    let level: ChannelLevel?
    var note: String? = nil
    var mac = false

    private var tint: Color {
        switch style {
        case .on(let c): return c
        case .selected: return .primary
        default: return .secondary
        }
    }

    var body: some View {
        let w = PatchLayout.baseTile.width * scale
        let h = PatchLayout.baseTile.height * scale
        return ZStack {
            background(w: w, h: h)
            VStack(spacing: 4 * scale) {
                iconView.frame(width: 28 * scale, height: 28 * scale)
                Text(name)
                    .font(.system(size: max(8, 9 * scale), weight: .semibold))
                    .foregroundColor(style == .normal || style == .dashed ? .secondary : .primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(width: w - 8, height: 22 * scale, alignment: .top)
            }
            .padding(.top, 4 * scale)
            corners(w: w, h: h)
            socketView(w: w, h: h)
        }
        .frame(width: w, height: h)
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.system(size: 20 * scale, weight: .semibold))
                .foregroundColor(style == .normal || style == .dashed ? color.opacity(0.7) : color)
        case .image(let image):
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        }
    }

    @ViewBuilder private func background(w: CGFloat, h: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11 * scale, style: .continuous)
        switch style {
        case .dashed:
            shape.fill(Color.primary.opacity(0.03))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        case .selected:
            shape.fill(Color.primary.opacity(0.14)).overlay(shape.strokeBorder(Color.primary.opacity(0.9), lineWidth: 2))
        case .on(let c):
            shape.fill(c.opacity(0.16)).overlay(shape.strokeBorder(c.opacity(0.8), lineWidth: 1.5))
        case .normal:
            shape.fill(Color.primary.opacity(0.06)).overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        }
    }

    private func corners(w: CGFloat, h: CGFloat) -> some View {
        VStack {
            HStack(alignment: .top) {
                if mac {
                    Text("MAC")
                        .font(.system(size: 6.5, weight: .heavy))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                        .help("The Mac's default device")
                } else if let level = level {
                    LevelDot(level: level, color: tint == .secondary ? HW.you : tint).padding(2)
                }
                Spacer(minLength: 0)
                badgeView
            }
            Spacer(minLength: 0)
        }
        .padding(4 * scale)
        .frame(width: w, height: h)
        .overlay(alignment: .bottom) {
            if let note = note {
                Text(note)
                    .font(.system(size: 7, weight: .heavy))
                    .tracking(0.4)
                    .foregroundColor(.black)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(HW.ledOrange))
                    .offset(y: 6)
            }
        }
    }

    @ViewBuilder private var badgeView: some View {
        switch badge {
        case .plugged?:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 10 * scale, weight: .bold)).foregroundColor(tint)
        case .partly?:
            Image(systemName: "minus.circle.fill").font(.system(size: 10 * scale, weight: .bold)).foregroundColor(tint)
                .help("Some apps are plugged in here")
        case .unplugged?:
            Image(systemName: "circle").font(.system(size: 10 * scale, weight: .semibold)).foregroundColor(Color.secondary.opacity(0.5))
        case .remove(let action)?:
            Button(action: action) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 10 * scale, weight: .bold)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Turn this input off")
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private func socketView(w: CGFloat, h: CGFloat) -> some View {
        if socket != .none {
            Circle()
                .fill(Color.black.opacity(0.85))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.2))
                .frame(width: 9, height: 9)
                .offset(y: socket == .top ? -h / 2 : h / 2)
        }
    }
}

struct AppPatchTile: View {
    @ObservedObject var ch: Channel
    let scale: CGFloat
    let selected: Bool
    var body: some View {
        PatchTile(icon: .image(ch.icon), name: ch.name, scale: scale, style: selected ? .selected : .normal,
                  socket: .bottom, badge: nil, level: ch.level)
            .help(selected ? "Editing \(ch.name) — tap an output below to plug it in or pull it out"
                           : "Click to edit where \(ch.name) plays, or drag a cable to an output")
    }
}

/// Small light that glows with the channel's level.
struct LevelDot: View {
    @ObservedObject var level: ChannelLevel
    var color: Color
    var body: some View {
        Circle()
            .fill(color.opacity(0.15 + 0.85 * meterPosition(level.meter)))
            .frame(width: 6, height: 6)
    }
}

// MARK: - Mac output and input

/// The Mac's default output or microphone, switchable right here instead of the menu bar Sound control.
/// For the microphone, pick Mixer Stream so apps like Clubdeck hear your stream mix.
struct MacDeviceRow: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var devices: DeviceManager
    let output: Bool
    var hidden: Set<String> = []
    var panelID: String?

    var body: some View {
        let current = output ? devices.defaultOutput : devices.defaultInput
        let list = (output ? model.allOutputs : model.allInputs).filter { !hidden.contains($0.uid) || $0.id == current }
        let stream = MixerModel.streamDeviceUID
        let suggestStream = !output && model.macInputUID != stream && list.contains { $0.uid == stream }
        VStack(alignment: .leading, spacing: 2) {
            row(list: list, current: current)
            if suggestStream {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9))
                        .foregroundColor(HW.stream)
                    Text("Tip: pick Mixer Stream so Clubdeck, Zoom or OBS get your mix in full quality")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.leading, 20)
            }
        }
    }

    private func row(list: [AudioDevice], current: AudioDeviceID) -> some View {
        HStack(spacing: 6) {
            Image(systemName: output ? "speaker.wave.2" : "mic")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 14)
            Text(output ? "Mac's default output:" : "Apps using the Mac's default microphone record:")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Menu {
                ForEach(list) { d in
                    Button(action: { output ? model.selectOutput(d.uid) : model.selectInput(d.uid) }) {
                        if d.id == current { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                    }
                }
            } label: {
                Text(output ? model.macOutputName : model.macInputName)
                    .font(.system(size: 10, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .modifier(PanelHit(id: panelID.map { "\($0).\(output ? "macoutput" : "macinput")" }))
            Spacer(minLength: 0)
        }
        .help(output ? "The Mac's sound output, the same as the Sound control in the menu bar"
                     : "Pick “Mixer Stream” here so apps like Clubdeck or Zoom hear your stream mix as their microphone")
    }
}

/// Pops a native menu at the pointer (works inside the borderless, non-activating panel).
final class PopupMenu: NSObject {
    enum Item {
        case header(String)
        case item(String, checked: Bool, action: () -> Void)
        case disabled(String)
        case separator
    }

    private static let shared = PopupMenu()
    private var actions: [() -> Void] = []

    static func show(_ items: [Item]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        shared.actions = []
        for item in items {
            switch item {
            case .header(let title):
                menu.addItem(NSMenuItem.sectionHeader(title: title))
            case .separator:
                menu.addItem(.separator())
            case .disabled(let title):
                let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                mi.isEnabled = false
                menu.addItem(mi)
            case .item(let title, let checked, let action):
                let mi = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
                mi.target = shared
                mi.tag = shared.actions.count
                mi.state = checked ? .on : .off
                shared.actions.append(action)
                menu.addItem(mi)
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard sender.tag < actions.count else { return }
        actions[sender.tag]()
    }
}
