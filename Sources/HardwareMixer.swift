import AppKit
import SwiftUI

// A studio-style mixer with one rule: every control does one thing, says what it does in words,
// and shows its state in words. No knobs, no modes, no hidden menus on the live surface.

// MARK: - Palette

enum HW {
    static let ledBlue = Color(red: 0.12, green: 0.62, blue: 1.0)
    static let ledYellow = Color(red: 1.0, green: 0.84, blue: 0.32)
    static let ledOrange = Color(red: 1.0, green: 0.42, blue: 0.10)
    static let mutedRed = Color(red: 1.0, green: 0.32, blue: 0.28)
    /// "You" (what you hear) and "Stream" (what other apps hear) colours, used on every control of that mix.
    static let you = Color(red: 0.25, green: 0.68, blue: 1.0)
    static let stream = Color(red: 0.72, green: 0.48, blue: 1.0)
    static let label = Color(white: 0.66)
    static let dimLabel = Color(white: 0.42)
    static let tick = Color(white: 0.32)

    static let body = LinearGradient(colors: [Color(white: 0.13), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
    static let strip = LinearGradient(colors: [Color(white: 0.16), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
    static let capFill = LinearGradient(colors: [Color(white: 0.25), Color(white: 0.09)], startPoint: .top, endPoint: .bottom)
}

/// Panel dimensions from the Small / Medium / Large setting.
struct Metrics {
    let s: CGFloat

    static func of(_ size: Int) -> Metrics {
        switch size {
        case 0: return Metrics(s: 0.7)
        case 2: return Metrics(s: 1.0)
        default: return Metrics(s: 0.85)
        }
    }

    var fader: CGFloat { 190 * s }
    var faderWidth: CGFloat { 40 * s }
    var pad: CGFloat { 12 * s }
    var radius: CGFloat { 22 * s }
    func font(_ size: CGFloat) -> CGFloat { max(9, size * s) }
}

/// Peak (linear) -> 0…1 meter position on a -54…0 dBFS scale.
func meterPosition(_ peak: Float) -> Double {
    guard peak > 0 else { return 0 }
    let db = 20 * log10(Double(peak))
    return max(0, min(1, (db + 54) / 54))
}

// MARK: - Interaction helpers

/// Where each drag started (SwiftUI @State needs a macro plugin the Command Line Tools don't ship).
enum DragTracker {
    static var starts: [String: Double] = [:]
}

/// The panel can be dragged from anywhere except its controls. Controls register their frames here;
/// the drag itself is handled at the window level (AppDelegate), which SwiftUI can't block.
enum PanelWindow {
    static weak var window: NSWindow?
    static var controls: [String: CGRect] = [:]

    static func isOverControl(_ point: CGPoint) -> Bool {
        let scope = ControlScope.panel + ":"
        return controls.contains { $0.key.hasPrefix(scope) && $0.value.insetBy(dx: -2, dy: -2).contains(point) }
            || ScrollTargets.targets.contains { $0.key.hasPrefix(scope) && $0.value.frame.contains(point) }
    }
}

/// The same mixer view is shown in the floating panel and in the menu bar dropdown. Each window registers its
/// controls under its own scope, so the two copies never overwrite each other's frames.
enum ControlScope {
    static let panel = "panel"
    static let menu = "menu"
}

private struct ControlScopeKey: EnvironmentKey {
    static let defaultValue = ControlScope.panel
}

extension EnvironmentValues {
    var controlScope: String {
        get { self[ControlScopeKey.self] }
        set { self[ControlScopeKey.self] = newValue }
    }
}

/// A control's frame, cut down to the part a scrolling row actually shows (nil when it's scrolled out of view).
func visibleFrame(_ frame: CGRect, clip: CGRect?) -> CGRect? {
    guard let clip = clip else { return frame }
    let f = frame.intersection(clip)
    return f.isNull || f.isEmpty ? nil : f
}

private struct PanelControlModifier: ViewModifier {
    let id: String
    @Environment(\.controlScope) private var scope
    @Environment(\.controlClip) private var clip

    func body(content: Content) -> some View {
        let key = scope + ":" + id
        let clip = self.clip
        return content.background(
            GeometryReader { g in
                Color.clear
                    .onAppear { PanelWindow.controls[key] = visibleFrame(g.frame(in: .global), clip: clip) }
                    .onChange(of: g.frame(in: .global)) { _, f in PanelWindow.controls[key] = visibleFrame(f, clip: clip) }
                    .onChange(of: clip) { _, c in PanelWindow.controls[key] = visibleFrame(g.frame(in: .global), clip: c) }
                    .onDisappear { PanelWindow.controls[key] = nil }
            }
        )
    }
}

extension View {
    /// Marks a button or chip so pressing on it never drags the panel.
    func panelControl(_ id: String) -> some View {
        modifier(PanelControlModifier(id: id))
    }
}

/// Stacks views vertically and gives every row the natural width of the mixer deck (the middle row),
/// so the top bar and the bottom row never stick out past it or leave empty space beside it.
/// A row that needs more room (the routing drawer) widens all rows, and the deck is centred.
struct DeckWidthStack: Layout {
    var spacing: CGFloat
    var deckIndex = 1

    private func sizes(_ subviews: Subviews) -> (width: CGFloat, deckWidth: CGFloat, heights: [CGFloat]) {
        guard subviews.indices.contains(deckIndex) else { return (0, 0, []) }
        let deck = subviews[deckIndex].sizeThatFits(.unspecified)
        var width = deck.width
        for i in subviews.indices where i != deckIndex {
            width = max(width, subviews[i].sizeThatFits(ProposedViewSize(width: 0, height: nil)).width)
        }
        let heights = subviews.indices.map { i in
            i == deckIndex ? deck.height : subviews[i].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        return (width, deck.width, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (width, _, heights) = sizes(subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (width, deckWidth, heights) = sizes(subviews)
        var y = bounds.minY
        for i in subviews.indices {
            if i == deckIndex {
                subviews[i].place(at: CGPoint(x: bounds.minX + ((width - deckWidth) / 2).rounded(), y: y),
                                  proposal: .unspecified)
            } else {
                subviews[i].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: width, height: heights[i]))
            }
            y += heights[i] + spacing
        }
    }
}

/// Mouse wheel / trackpad over a slider adjusts it — gently, and eased over a few frames so it glides.
enum ScrollTargets {
    static var targets: [String: (frame: CGRect, adjust: (Double) -> Void)] = [:]
    private static var pending: [String: Double] = [:]
    private static var timer: Timer?

    /// Returns true when the event was used. `scope` is the window's ControlScope.
    static func handle(_ point: CGPoint, _ event: NSEvent, scope: String) -> Bool {
        let prefix = scope + ":"
        guard let (id, _) = targets.first(where: { $0.key.hasPrefix(prefix) && $0.value.frame.contains(point) }) else { return false }
        // A sideways swipe (or Shift + wheel) scrolls the channel row instead of moving a fader.
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift) { return false }
        var dy = Double(event.scrollingDeltaY)
        if event.isDirectionInvertedFromDevice { dy = -dy } // wheel up = louder, whatever the scroll setting
        let speed = AppSettings.shared.scrollSpeed
        // Wheel: 1% per notch at speed 1. Trackpad: about 1% per 15 points of swipe.
        let step = event.hasPreciseScrollingDeltas ? dy / 1500 * speed : dy * 0.01 * speed
        guard step != 0 else { return true }
        pending[id, default: 0] += step
        startTimer()
        return true
    }

    private static func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func tick() {
        for (id, remaining) in pending {
            let part = abs(remaining) < 0.0008 ? remaining : remaining * 0.28
            targets[id]?.adjust(part)
            let left = remaining - part
            pending[id] = abs(left) < 0.00001 ? nil : left
        }
        if pending.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}

private struct ScrollAdjustModifier: ViewModifier {
    let id: String
    let value: Binding<Double>
    let onChange: () -> Void
    @Environment(\.controlScope) private var scope
    @Environment(\.controlClip) private var clip

    func body(content: Content) -> some View {
        let key = scope + ":" + id
        let value = self.value, onChange = self.onChange, clip = self.clip
        let adjust: (Double) -> Void = { delta in
            value.wrappedValue = min(1, max(0, value.wrappedValue + delta))
            onChange()
        }
        func register(_ frame: CGRect, _ clip: CGRect?) {
            ScrollTargets.targets[key] = visibleFrame(frame, clip: clip).map { ($0, adjust) }
        }
        return content.background(
            GeometryReader { g in
                Color.clear
                    .onAppear { register(g.frame(in: .global), clip) }
                    .onChange(of: g.frame(in: .global)) { _, frame in register(frame, clip) }
                    .onChange(of: clip) { _, c in register(g.frame(in: .global), c) }
                    .onDisappear { ScrollTargets.targets[key] = nil }
            }
        )
    }
}

extension View {
    func scrollAdjusts(id: String, value: Binding<Double>, onChange: @escaping () -> Void) -> some View {
        modifier(ScrollAdjustModifier(id: id, value: value, onChange: onChange))
    }
}

// MARK: - Controls

/// A tiny take-away cup with yellow coffee in it, for the "Buy me a coffee" button.
struct CoffeeCupIcon: View {
    var outline: Color = Color(white: 0.85)
    var coffee: Color = HW.ledYellow

    var body: some View {
        Canvas { ctx, size in
            let u = min(size.width, size.height) / 24 // drawn on a 24×24 grid
            let ox = (size.width - 24 * u) / 2, oy = (size.height - 24 * u) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * u, y: oy + y * u) }
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: ox + x * u, y: oy + y * u, width: w * u, height: h * u) }

            var liquid = Path()
            liquid.move(to: p(7.3, 12.4))
            liquid.addQuadCurve(to: p(16.7, 11.6), control: p(12, 10.4))
            liquid.addLine(to: p(16.0, 18.6))
            liquid.addLine(to: p(8.0, 18.6))
            liquid.closeSubpath()
            ctx.fill(liquid, with: .color(coffee))

            var cup = Path()
            cup.addRoundedRect(in: r(7, 2, 10, 3.6), cornerSize: CGSize(width: 1.8 * u, height: 1.8 * u))
            cup.addRoundedRect(in: r(4.6, 5.6, 14.8, 3.8), cornerSize: CGSize(width: 1.9 * u, height: 1.9 * u))
            cup.move(to: p(6.4, 9.4))
            cup.addLine(to: p(7.8, 21.0))
            cup.addQuadCurve(to: p(9.2, 22.2), control: p(7.95, 22.2))
            cup.addLine(to: p(14.8, 22.2))
            cup.addQuadCurve(to: p(16.2, 21.0), control: p(16.05, 22.2))
            cup.addLine(to: p(17.6, 9.4))
            ctx.stroke(cup, with: .color(outline), style: StrokeStyle(lineWidth: 1.7 * u, lineCap: .round, lineJoin: .round))
        }
    }
}

struct LEDMeter: View {
    var level: Float
    var height: CGFloat
    var width: CGFloat = 6
    var segments = 18

    var body: some View {
        let lit = meterPosition(level)
        let segHeight: CGFloat = max(2, height / CGFloat(segments) * 0.5)
        let spacing = (height - segHeight * CGFloat(segments)) / CGFloat(segments - 1)
        VStack(spacing: spacing) {
            ForEach((0..<segments).reversed(), id: \.self) { i in
                let on = lit > Double(i) / Double(segments)
                let color = i >= segments - 3 ? HW.ledOrange : (i >= segments - 7 ? HW.ledYellow : HW.ledBlue)
                RoundedRectangle(cornerRadius: 1)
                    .fill(color.opacity(on ? 1 : 0.12))
                    .frame(width: width, height: segHeight)
            }
        }
        .frame(height: height)
    }
}

struct FaderCap: View {
    var stripe: Color
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(HW.capFill)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color(white: 0.38), Color(white: 0.02)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
            Rectangle().fill(stripe).frame(height: 2.5).padding(.horizontal, 4)
        }
        .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 3)
    }
}

/// A vertical studio fader. Drag, scroll, or double-click for 100%.
struct Fader: View {
    @Binding var value: Double
    var onChange: () -> Void
    var height: CGFloat
    var width: CGFloat
    var dragID: String
    var stripe: Color = .white
    var dimmed = false

    var body: some View {
        let capHeight = max(18, min(30, height * 0.15))
        let travel = height - capHeight
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                ticks(.trailing)
                Spacer(minLength: 0)
                ticks(.leading)
            }
            .padding(.vertical, capHeight / 2)

            Capsule()
                .fill(Color.black)
                .frame(width: 5, height: height - 8)
                .padding(.top, 4)
            // Coloured fill below the cap shows the level at a glance.
            Capsule()
                .fill(stripe.opacity(dimmed ? 0.2 : 0.55))
                .frame(width: 3, height: max(0, travel * CGFloat(value)))
                .offset(y: capHeight / 2 + travel * CGFloat(1 - value))

            FaderCap(stripe: dimmed ? Color(white: 0.45) : stripe)
                .frame(width: width * 0.78, height: capHeight)
                .offset(y: travel * CGFloat(1 - value))
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { g in
                    let start = DragTracker.starts[dragID] ?? value
                    DragTracker.starts[dragID] = start
                    value = min(1, max(0, start - Double(g.translation.height / travel)))
                    onChange()
                }
                .onEnded { _ in DragTracker.starts[dragID] = nil }
        )
        .onTapGesture(count: 2) { value = 1; onChange() }
        .scrollAdjusts(id: dragID, value: $value, onChange: onChange)
    }

    private func ticks(_ alignment: HorizontalAlignment) -> some View {
        let count = height > 150 ? 11 : 6
        return VStack(alignment: alignment, spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                Rectangle()
                    .fill(HW.tick)
                    .frame(width: i % 5 == 0 ? width * 0.2 : width * 0.12, height: 1)
                if i < count - 1 { Spacer(minLength: 0) }
            }
        }
        .frame(width: width * 0.22, alignment: alignment == .leading ? .leading : .trailing)
    }
}

/// Round panel button: grey normally, glowing in `litColor` when lit.
struct RoundButton: View {
    var symbol: String
    var lit: Bool
    var litColor: Color
    var width: CGFloat
    var id: String
    var help: String
    var action: () -> Void

    var body: some View {
        let size = max(24, width * 0.92)
        Button(action: action) {
            ZStack {
                Circle().fill(Color.black).frame(width: size + 4, height: size + 4)
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(lit ? litColor.opacity(0.8) : Color(white: 0.26), lineWidth: 1))
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 2)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundColor(lit ? litColor : Color(white: 0.5))
                    .shadow(color: lit ? litColor.opacity(0.8) : .clear, radius: 4)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .panelControl(id)
    }
}

/// Round speaker button: grey normally, glowing orange with a crossed-out speaker when muted.
struct MuteButton: View {
    var muted: Bool
    var width: CGFloat
    let m: Metrics
    var id: String
    var action: () -> Void

    var body: some View {
        RoundButton(symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", lit: muted, litColor: HW.ledOrange,
                    width: width, id: id, help: muted ? "Muted — click to unmute" : "Click to mute", action: action)
    }
}

/// One labelled fader column: name, percentage, fader, mute.
struct FaderColumn: View {
    var title: String
    var color: Color
    @Binding var value: Double
    var muted: Bool
    var dragID: String
    let m: Metrics
    var onChange: () -> Void
    var toggleMute: () -> Void

    var body: some View {
        VStack(spacing: 5 * m.s) {
            Text(title)
                .font(.system(size: m.font(9), weight: .bold))
                .tracking(0.6)
                .foregroundColor(color)
                .fixedSize()
            Text(muted ? "off" : "\(Int((value * 100).rounded()))%")
                .font(.system(size: m.font(10), weight: .semibold).monospacedDigit())
                .foregroundColor(muted ? HW.mutedRed : Color(white: 0.85))
                .fixedSize()
            Fader(value: $value, onChange: onChange, height: m.fader, width: m.faderWidth,
                  dragID: dragID, stripe: color, dimmed: muted)
            MuteButton(muted: muted, width: m.faderWidth + 4, m: m, id: dragID + ".mute", action: toggleMute)
        }
    }
}

struct ChannelMeter: View {
    @ObservedObject var level: ChannelLevel
    let height: CGFloat
    let m: Metrics
    var body: some View {
        LEDMeter(level: level.meter, height: height, width: 4 * m.s + 1)
    }
}

struct BusMeter: View {
    @ObservedObject var meters: BusLevels
    let stream: Bool
    let height: CGFloat
    let m: Metrics
    var body: some View {
        LEDMeter(level: stream ? meters.stream : meters.monitor, height: height, width: 5 * m.s + 1)
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var maxWidth: CGFloat = 400

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(maxWidth, proposal.width ?? maxWidth)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(width, maxX), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let limit = bounds.minX + min(maxWidth, bounds.width)
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > limit { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Channel strip

struct ChannelStrip: View {
    @ObservedObject var ch: Channel
    @ObservedObject var model: MixerModel
    let m: Metrics

    var body: some View {
        VStack(spacing: 6 * m.s) {
            HStack(spacing: 4) {
                Image(nsImage: ch.icon)
                    .renderingMode(ch.kind == .mic ? .template : .original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(HW.ledYellow)
                    .frame(width: 14 * m.s + 3, height: 14 * m.s + 3)
                Text(ch.name)
                    .font(.system(size: m.font(11), weight: .semibold))
                    .foregroundColor(Color(white: 0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if ch.error != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: m.font(9)))
                        .foregroundColor(HW.ledOrange)
                        .help(ch.error ?? "")
                }
                // A channel with its own outputs gets a small icon instead of an extra line, so every strip
                // keeps the same height and the faders line up.
                if let own = ch.outputOverride {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: m.font(8), weight: .bold))
                        .foregroundColor(HW.you)
                        .help("Plays on " + (own.isEmpty ? "no output" : own.map(model.deviceName).joined(separator: ", "))
                              + " instead of the All apps outputs (change it in the patch bay)")
                }
            }
            .frame(width: m.faderWidth * 2 + 26 * m.s)

            HStack(alignment: .bottom, spacing: 4 * m.s) {
                FaderColumn(title: "YOU", color: HW.you, value: $ch.monitorLevel, muted: ch.monitorMuted,
                            dragID: ch.id + ".you", m: m, onChange: { model.changed(ch) },
                            toggleMute: { ch.monitorMuted.toggle(); model.changed(ch) })
                    .help("How loud \(ch.name) is for you")
                ChannelMeter(level: ch.level, height: m.fader, m: m)
                    .padding(.bottom, 20 * m.s + 4 + 5 * m.s)
                FaderColumn(title: "STREAM", color: HW.stream, value: $ch.streamLevel,
                            muted: ch.streamMuted || !ch.toStream || !model.streamDeviceInstalled,
                            dragID: ch.id + ".stream", m: m, onChange: { model.changed(ch) },
                            toggleMute: {
                                if ch.toStream { ch.streamMuted.toggle(); model.changed(ch) }
                                else { model.toggleConnection(ch, MixerModel.streamDeviceUID) } // reconnect
                            })
                    .help(model.streamDeviceInstalled ? "How loud \(ch.name) is in your stream" : "Install Mixer Stream in Setup to use the stream")
            }
        }
        .padding(.vertical, 8 * m.s)
        .padding(.horizontal, 6 * m.s)
        .background(RoundedRectangle(cornerRadius: 12 * m.s, style: .continuous).fill(HW.strip))
        .overlay(RoundedRectangle(cornerRadius: 12 * m.s, style: .continuous).strokeBorder(Color.black.opacity(0.7), lineWidth: 1))
    }
}

// MARK: - Scrolling channel row

/// Which strip is first in view (SwiftUI @State needs a macro plugin the Command Line Tools don't ship).
final class StripScrollState: ObservableObject {
    static let panel = StripScrollState()
    static let menu = StripScrollState()
    @Published var firstID: String?
}

/// The area a scrolling row shows, in global coordinates. Controls scrolled out of it don't count for
/// mouse-wheel targets or panel dragging, even though their frames still exist under neighbouring views.
private struct ControlClipKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    var controlClip: CGRect? {
        get { self[ControlClipKey.self] }
        set { self[ControlClipKey.self] = newValue }
    }
}

/// More channels than fit: a row of `visibleStrips` that scrolls sideways, snapping to whole strips.
/// Scroll with a trackpad or Shift + mouse wheel, or click the arrows on its edges.
struct StripScroller: View {
    let list: [Channel]
    let model: MixerModel
    let m: Metrics
    @ObservedObject var scroll: StripScrollState

    private var spacing: CGFloat { 8 * m.s }
    private var firstIndex: Int {
        scroll.firstID.flatMap { id in list.firstIndex { $0.id == id } } ?? 0
    }
    private var canGoBack: Bool { firstIndex > 0 }
    private var canGoForward: Bool { firstIndex + HardwareMixerView.visibleStrips < list.count }

    var body: some View {
        // Invisible strips give the row exactly the width of `visibleStrips` strips and their natural height.
        return HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<HardwareMixerView.visibleStrips, id: \.self) { _ in
                ChannelStrip(ch: list[0], model: model, m: m)
            }
        }
            .hidden()
            .environment(\.controlScope, "sizer") // registers nothing a window looks up
            .overlay(
                GeometryReader { g in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: spacing) {
                            ForEach(list) { ch in
                                ChannelStrip(ch: ch, model: model, m: m).id(ch.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $scroll.firstID)
                    .environment(\.controlClip, g.frame(in: .global))
                }
            )
            .overlay(alignment: .leading) { edge(back: true) }
            .overlay(alignment: .trailing) { edge(back: false) }
    }

    /// A soft fade and an arrow on an edge with more strips beyond it.
    @ViewBuilder
    private func edge(back: Bool) -> some View {
        if back ? canGoBack : canGoForward {
            ZStack {
                LinearGradient(colors: [Color(white: 0.09), Color(white: 0.09).opacity(0)],
                               startPoint: back ? .leading : .trailing, endPoint: back ? .trailing : .leading)
                    .frame(width: 28 * m.s)
                    .allowsHitTesting(false)
                Button(action: { step(back ? -1 : 1) }) {
                    Image(systemName: back ? "chevron.left" : "chevron.right")
                        .font(.system(size: m.font(10), weight: .bold))
                        .foregroundColor(Color(white: 0.85))
                        .frame(width: 22 * m.s + 4, height: 22 * m.s + 4)
                        .background(Circle().fill(Color(white: 0.16)))
                        .overlay(Circle().strokeBorder(Color(white: 0.32), lineWidth: 1))
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(back ? "Show earlier channels" : "Show more channels")
                .panelControl(back ? "strips.back" : "strips.forward")
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Moves by a page of strips (one fewer than fit, so one stays in view for context).
    private func step(_ direction: Int) {
        let page = max(1, HardwareMixerView.visibleStrips - 1)
        let last = max(0, list.count - HardwareMixerView.visibleStrips)
        let target = min(last, max(0, firstIndex + direction * page))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { scroll.firstID = list[target].id }
    }
}

// MARK: - Main panel

struct HardwareMixerView: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var devices: DeviceManager
    @ObservedObject var settings: AppSettings
    /// Shown in the menu bar dropdown instead of the floating panel.
    var inMenu = false
    var openSettings: () -> Void
    var close: () -> Void
    var quit: () -> Void = { NSApp.terminate(nil) }

    private var m: Metrics { Metrics.of(settings.panelSize) }

    var body: some View {
        DeckWidthStack(spacing: m.pad) {
            topBar
            HStack(alignment: .top, spacing: 8 * m.s) {
                channels
                masterStrip
            }
            outputsBar
            if settings.panelShowsRouting { routingDrawer }
        }
        .padding(m.pad + 2)
        .background(
            RoundedRectangle(cornerRadius: m.radius, style: .continuous)
                .fill(HW.body)
                .overlay(RoundedRectangle(cornerRadius: m.radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        )
        .contentShape(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
        .environment(\.colorScheme, .dark)
        .environment(\.controlScope, inMenu ? ControlScope.menu : ControlScope.panel)
        .fixedSize()
    }

    // MARK: Top bar

    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6 * m.s) {
                Text("CABLEBAY")
                    .font(.system(size: m.font(13), weight: .heavy))
                    .italic()
                    .tracking(1.2)
                    .foregroundColor(Color(white: 0.75))
                    .fixedSize()
                Spacer(minLength: 6)
                topButtons
            }
            HStack(spacing: 6 * m.s) {
                Spacer(minLength: 0)
                topButtons
            }
        }
    }

    private var topButtons: some View {
        HStack(spacing: 6 * m.s) {
            coffeeButton
            iconButton("gearshape", help: "Setup: per-app outputs, size, scroll speed, devices, uninstall", action: openSettings)
            iconButton("minus.magnifyingglass", help: "Smaller") { settings.panelSize = max(0, settings.panelSize - 1) }
                .disabled(settings.panelSize == 0)
            iconButton("plus.magnifyingglass", help: "Larger") { settings.panelSize = min(2, settings.panelSize + 1) }
                .disabled(settings.panelSize == 2)
            if inMenu {
                iconButton(settings.panelVisible ? "macwindow.badge.plus" : "macwindow",
                           help: settings.panelVisible ? "Hide the floating panel" : "Show the floating panel",
                           tint: settings.panelVisible ? HW.you : nil) { settings.panelVisible.toggle() }
                iconButton("power", help: "Quit Cablebay", action: quit)
            } else {
                iconButton("xmark", help: "Close the panel", action: close)
            }
        }
        .fixedSize()
    }

    private var coffeeButton: some View {
        Button(action: Support.open) {
            CoffeeCupIcon()
                .frame(width: m.font(9) * 1.55, height: m.font(9) * 1.55)
                .frame(width: 20 * m.s + 4, height: 20 * m.s + 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.07)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(white: 0.26), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Buy me a coffee — Cablebay is free, a coffee helps fund updates")
        .panelControl("top.coffee")
    }

    private func iconButton(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: m.font(9), weight: .bold))
                .foregroundColor(tint ?? Color(white: 0.6))
                .frame(width: 20 * m.s + 4, height: 20 * m.s + 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.07)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(white: 0.26), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .panelControl("top." + symbol)
    }

    // MARK: Channels

    /// Up to this many channel strips are shown side by side; more scroll sideways.
    static let visibleStrips = 5

    private var channels: some View {
        let list = model.allChannels
        let stripWidth = m.faderWidth * 2 + 26 * m.s + 12 * m.s
        return Group {
            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 22 * m.s))
                        .foregroundColor(Color(white: 0.3))
                    Text(model.tapsSupported ? "Play something —\nevery app shows up here\nas its own channel."
                                             : "Needs macOS 14.2 or later.")
                        .font(.system(size: m.font(10)))
                        .foregroundColor(HW.dimLabel)
                        .multilineTextAlignment(.center)
                }
                .frame(width: stripWidth * 2, height: m.fader + 80 * m.s)
            } else if list.count <= HardwareMixerView.visibleStrips {
                HStack(alignment: .top, spacing: 8 * m.s) {
                    ForEach(list) { ChannelStrip(ch: $0, model: model, m: m) }
                }
            } else {
                StripScroller(list: list, model: model, m: m,
                              scroll: inMenu ? StripScrollState.menu : StripScrollState.panel)
            }
        }
    }

    private var masterStrip: some View {
        VStack(spacing: 6 * m.s) {
            Text("MASTER")
                .font(.system(size: m.font(11), weight: .semibold))
                .foregroundColor(Color(white: 0.88))
            HStack(alignment: .bottom, spacing: 4 * m.s) {
                FaderColumn(title: "YOU", color: HW.you, value: $model.monitorMaster, muted: model.monitorMasterMuted,
                            dragID: "master.you", m: m, onChange: {},
                            toggleMute: { model.monitorMasterMuted.toggle() })
                    .help("Everything you hear")
                BusMeter(meters: model.meters, stream: false, height: m.fader, m: m)
                    .padding(.bottom, 20 * m.s + 4 + 5 * m.s)
                BusMeter(meters: model.meters, stream: true, height: m.fader, m: m)
                    .padding(.bottom, 20 * m.s + 4 + 5 * m.s)
                FaderColumn(title: "STREAM", color: HW.stream, value: $model.streamMaster, muted: model.streamMasterMuted,
                            dragID: "master.stream", m: m, onChange: {},
                            toggleMute: { model.streamMasterMuted.toggle() })
                    .help("Everything in your stream")
            }
        }
        .padding(.vertical, 8 * m.s)
        .padding(.horizontal, 6 * m.s)
        .background(RoundedRectangle(cornerRadius: 12 * m.s, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 12 * m.s, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    // MARK: Outputs and inputs

    /// One button that opens the patch bay, with a plain summary of what's plugged in.
    private var outputsBar: some View {
        HStack(spacing: 6 * m.s) {
            patchBayButton
            streamBadge
        }
    }

    /// "3 channels → 2 outputs": counts every output any channel is plugged into, Mixer Stream included.
    private var patchSummary: String {
        let channels = model.allChannels
        guard !channels.isEmpty else { return "Nothing playing" }
        var outs = Set<String>()
        for ch in channels {
            outs.formUnion(model.monitorUIDs(for: ch))
            outs.formUnion(model.streamUIDs(for: ch))
        }
        let c = channels.count, o = outs.count
        return "\(c) channel\(c == 1 ? "" : "s") → \(o) output\(o == 1 ? "" : "s")"
    }

    private var patchBayButton: some View {
        let open = settings.panelShowsRouting
        return Button(action: { settings.panelShowsRouting.toggle() }) {
            HStack(spacing: 6 * m.s) {
                Image(systemName: "cable.connector.horizontal")
                    .font(.system(size: m.font(10), weight: .bold))
                    .foregroundColor(HW.you)
                Text("PATCH BAY")
                    .font(.system(size: m.font(9.5), weight: .heavy))
                    .tracking(0.6)
                    .foregroundColor(Color(white: 0.9))
                Text(patchSummary)
                    .font(.system(size: m.font(10), weight: .medium))
                    .foregroundColor(HW.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.system(size: m.font(7), weight: .bold))
                    .foregroundColor(HW.dimLabel)
            }
            .padding(.horizontal, 8 * m.s)
            .frame(height: 26 * m.s + 4)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(open ? HW.you.opacity(0.12) : Color(white: 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HW.you.opacity(open ? 0.8 : 0.45), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(open ? "Hide the patch bay" : "Show the patch bay: plug any app or input into any output")
        .panelControl("route.patchbay")
    }

    /// The patch bay, shown under the bar while it's open. Wide enough to show every jack.
    private var routingDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PATCH BAY")
                    .font(.system(size: m.font(10), weight: .heavy))
                    .tracking(0.8)
                    .foregroundColor(HW.label)
                Spacer(minLength: 8)
                RoutingLegend()
            }
            RoutingBoard(model: model, devices: devices, selection: inMenu ? RoutingSelection.menu : RoutingSelection.panel,
                         settings: settings, inPanel: !inMenu, openSettings: openSettings)
        }
        .padding(10)
        .frame(minWidth: min(760, max(400, PatchLayout.make(model, hidden: Set(inMenu ? settings.hiddenInMenu : settings.hiddenInPanel)).contentWidth + 20)))
        .background(RoundedRectangle(cornerRadius: 12 * m.s, style: .continuous).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 12 * m.s, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var streamBadge: some View {
        let installed = model.streamDeviceInstalled
        return Button(action: { installed ? settings.panelShowsRouting.toggle() : openSettings() }) {
            Image(systemName: installed ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle.fill")
                .font(.system(size: m.font(10), weight: .bold))
            .foregroundColor(installed ? HW.stream : HW.ledOrange)
            .frame(width: 26 * m.s + 4, height: 26 * m.s + 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder((installed ? HW.stream : HW.ledOrange).opacity(0.6), lineWidth: 1))
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(installed ? "Your STREAM mix goes to “Mixer Stream”. Pick “Mixer Stream” as the microphone in OBS, Zoom or Discord."
                        : "Mixer Stream isn't installed — click to open Setup and install it.")
        .panelControl("stream.badge")
    }
}
