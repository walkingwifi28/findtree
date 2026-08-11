import SwiftUI
import AppKit
import FindTreeCore

struct TreemapNode: Identifiable {
    let usage: DirectoryUsage
    let children: [TreemapNode]
    let files: [FileUsage]
    let directAllocatedBytes: UInt64

    var id: String { usage.path }
}

struct TreemapView: View {
    let root: TreemapNode
    let onMoveToTrash: (URL) -> Void


    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let layouts = TreemapLayout.layout(root: root, in: bounds)

            ZStack(alignment: .topLeading) {
                // Keep the coordinate space at the full GeometryReader size without
                // painting a background. This lets the app's real light/dark background
                // show through every non-terminal directory.
                Color.clear
                    .frame(width: bounds.width, height: bounds.height)
                    .allowsHitTesting(false)

                ForEach(layouts) { layout in
                    TreemapTile(
                        layout: layout,
                        onMoveToTrash: onMoveToTrash
                    )
                }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .clipped()
            .onDisappear {
                FastTreemapTooltipController.shared.hide()
            }
        }
    }
}

private struct TreemapAggregate: Identifiable {
    let id: String
    let name: String
    let path: String
    let allocatedBytes: UInt64
}

private enum TreemapEntry: Identifiable {
    case directory(TreemapNode)
    case file(FileUsage)
    case aggregate(TreemapAggregate)

    var id: String {
        switch self {
        case .directory(let node):
            return "d:\(node.usage.path)"
        case .file(let file):
            return "f:\(file.path)"
        case .aggregate(let aggregate):
            return "a:\(aggregate.id)"
        }
    }

    var displayName: String {
        switch self {
        case .directory(let node):
            return (node.usage.path as NSString).lastPathComponent
        case .file(let file):
            return file.name
        case .aggregate(let aggregate):
            return aggregate.name
        }
    }

    var path: String {
        switch self {
        case .directory(let node):
            return node.usage.path
        case .file(let file):
            return file.path
        case .aggregate(let aggregate):
            return aggregate.path
        }
    }

    var allocatedBytes: UInt64 {
        switch self {
        case .directory(let node):
            return node.usage.allocatedBytes
        case .file(let file):
            return file.allocatedBytes
        case .aggregate(let aggregate):
            return aggregate.allocatedBytes
        }
    }

    var finderURL: URL? {
        switch self {
        case .directory(let node):
            return URL(fileURLWithPath: node.usage.path, isDirectory: true)
        case .file(let file):
            return URL(fileURLWithPath: file.path)
        case .aggregate:
            return nil
        }
    }
}

private struct TreemapTile: View {
    let layout: TreemapLayoutItem
    let onMoveToTrash: (URL) -> Void

    var body: some View {
        tileContent
        .frame(width: tileWidth, height: tileHeight)
        .offset(x: layout.rect.minX + layout.gap, y: layout.rect.minY + layout.gap)
        .zIndex(Double(layout.depth))
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active:
                FastTreemapTooltipController.shared.hover(
                    id: layout.entry.id,
                    path: layout.entry.path,
                    size: formatBytes(layout.entry.allocatedBytes)
                )
            case .ended:
                FastTreemapTooltipController.shared.endHover(id: layout.entry.id)
            }
        }
        .help(helpText)
        .contextMenu {
            if let finderURL = layout.entry.finderURL {
                FinderContextMenu(url: finderURL, onMoveToTrash: onMoveToTrash)
                    .onAppear {
                        FastTreemapTooltipController.shared.hide()
                    }
            }
        }
    }

    private var tileContent: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(
                    layout.isTerminal
                        ? TreemapColor.terminalColor(for: layout.entry.path)
                        : Color.clear
                )
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(.primary.opacity(borderOpacity), lineWidth: 1)

            if shouldShowLabel {
                if layout.isTerminal {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(layout.entry.displayName)
                            .font(labelFont)
                            .lineLimit(1)
                        Text(formatBytes(layout.entry.allocatedBytes))
                            .font(sizeLabelFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(layout.depth <= 2 ? 6 : 4)
                } else {
                    Text(layout.entry.displayName + "  " + formatBytes(layout.entry.allocatedBytes))
                        .font(labelFont)
                        .lineLimit(1)
                        .padding(layout.depth <= 2 ? 6 : 4)
                }
            }
        }
    }

    private var tileWidth: CGFloat { max(layout.rect.width - layout.gap * 2, 0) }
    private var tileHeight: CGFloat { max(layout.rect.height - layout.gap * 2, 0) }
    private var cornerRadius: CGFloat { layout.depth <= 1 ? 4 : 2 }
    private var borderOpacity: Double { layout.depth <= 2 ? 0.34 : 0.24 }

    private var shouldShowLabel: Bool {
        if layout.isTerminal {
            return layout.rect.width > 72 && layout.rect.height > 40
        }
        if layout.depth <= 2 {
            return layout.rect.width > 78 && layout.rect.height > 24
        }
        return layout.rect.width > 88 && layout.rect.height > 22
    }

    private var labelFont: Font {
        .system(size: 10)
    }

    private var sizeLabelFont: Font {
        .system(size: 10)
    }

    private var helpText: String {
        layout.entry.path + "\n" + formatBytes(layout.entry.allocatedBytes)
    }
}

@MainActor
final class FastTreemapTooltipController {
    static let shared = FastTreemapTooltipController()

    private var pendingTask: Task<Void, Never>?
    private var hoveredID: String?
    private var panel: NSPanel?

    func hover(id: String, path: String, size: String) {
        if hoveredID == id {
            if panel?.isVisible == true {
                positionPanelNearMouse()
            }
            return
        }

        hoveredID = id
        pendingTask?.cancel()
        pendingTask = nil
        panel?.orderOut(nil)

        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard let self, self.hoveredID == id, !Task.isCancelled else { return }
            self.show(path: path, size: size)
        }
    }

    func endHover(id: String) {
        guard hoveredID == id else { return }
        hide()
    }

    func hide() {
        hoveredID = nil
        pendingTask?.cancel()
        pendingTask = nil
        panel?.orderOut(nil)
    }

    private func show(path: String, size: String) {
        let rootView = FastTreemapTooltipView(path: path, size: size)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.layoutSubtreeIfNeeded()

        let fitting = hostingView.fittingSize
        let screen = screenContainingMouse()
        let maxWidth = max(min(screen.visibleFrame.width - 24, 720), 240)
        let width = min(max(fitting.width, 180), maxWidth)
        let height = max(fitting.height, 42)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.appearance = NSApp.effectiveAppearance
        panel.contentView = hostingView
        panel.setContentSize(NSSize(width: width, height: height))
        positionPanelNearMouse(panel: panel, screen: screen)
        panel.orderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        return panel
    }

    private func positionPanelNearMouse() {
        guard let panel, panel.isVisible else { return }
        positionPanelNearMouse(panel: panel, screen: screenContainingMouse())
    }

    private func positionPanelNearMouse(panel: NSPanel, screen: NSScreen) {
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        let xOffset: CGFloat = 14
        let yOffset: CGFloat = 18

        var x = mouse.x + xOffset
        var y = mouse.y - frame.height - yOffset

        if x + frame.width > visible.maxX - margin {
            x = mouse.x - frame.width - xOffset
        }
        if y < visible.minY + margin {
            y = mouse.y + yOffset
        }

        x = min(max(x, visible.minX + margin), visible.maxX - frame.width - margin)
        y = min(max(y, visible.minY + margin), visible.maxY - frame.height - margin)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func screenContainingMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

private struct FastTreemapTooltipView: View {
    let path: String
    let size: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(path)
                .font(.system(size: 11))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(size)
                .font(.system(size: 11))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 700, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(.primary.opacity(0.16), lineWidth: 1)
        }
    }
}

private enum TreemapColor {
    static func terminalColor(for path: String) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.20, brightness: 0.68)
    }
}

private struct TreemapLayoutItem: Identifiable {
    let entry: TreemapEntry
    let rect: CGRect
    let depth: Int
    let isTerminal: Bool

    var id: String { entry.id }
    var gap: CGFloat { depth <= 1 ? 1.5 : 0.8 }
}

private struct WeightedTreemapSlot {
    let entry: TreemapEntry
    let weight: UInt64
}

private enum TreemapLayout {
    private static let maxRenderedDepth = 6
    private static let minimumExpandedWidth: CGFloat = 36
    private static let minimumExpandedHeight: CGFloat = 28

    static func layout(root: TreemapNode, in rect: CGRect) -> [TreemapLayoutItem] {
        guard rect.width > 1, rect.height > 1, root.usage.allocatedBytes > 0 else { return [] }

        let firstLevel = splitSlots(childSlots(for: root), in: rect)
        return firstLevel.flatMap { slot, slotRect in
            layoutSlot(slot, in: slotRect, depth: 1)
        }
    }

    private static func layoutSlot(
        _ slot: WeightedTreemapSlot,
        in rect: CGRect,
        depth: Int
    ) -> [TreemapLayoutItem] {
        switch slot.entry {
        case .directory(let node):
            return layoutDirectory(node, in: rect, depth: depth)
        case .file, .aggregate:
            return [TreemapLayoutItem(entry: slot.entry, rect: rect, depth: depth, isTerminal: true)]
        }
    }

    private static func layoutDirectory(
        _ node: TreemapNode,
        in rect: CGRect,
        depth: Int
    ) -> [TreemapLayoutItem] {
        let directoryEntry = TreemapEntry.directory(node)
        guard rect.width > 2, rect.height > 2 else {
            return [TreemapLayoutItem(entry: directoryEntry, rect: rect, depth: depth, isTerminal: true)]
        }

        let slots = childSlots(for: node)
        guard depth < maxRenderedDepth,
              !slots.isEmpty,
              rect.width >= minimumExpandedWidth,
              rect.height >= minimumExpandedHeight
        else {
            return [TreemapLayoutItem(entry: directoryEntry, rect: rect, depth: depth, isTerminal: true)]
        }

        let labelHeight: CGFloat
        if rect.width > 72, rect.height > 44 {
            labelHeight = depth <= 2 ? 22 : 18
        } else {
            labelHeight = 2
        }

        var contentRect = rect.insetBy(dx: 2.5, dy: 2.5)
        contentRect.origin.y += labelHeight
        contentRect.size.height -= labelHeight
        guard contentRect.width > 1, contentRect.height > 1 else {
            return [TreemapLayoutItem(entry: directoryEntry, rect: rect, depth: depth, isTerminal: true)]
        }

        let childLayouts = splitSlots(slots, in: contentRect)
        guard !childLayouts.isEmpty else {
            return [TreemapLayoutItem(entry: directoryEntry, rect: rect, depth: depth, isTerminal: true)]
        }

        var result = [
            TreemapLayoutItem(entry: directoryEntry, rect: rect, depth: depth, isTerminal: false)
        ]
        for (slot, childRect) in childLayouts {
            guard childRect.width > 0.25, childRect.height > 0.25 else { continue }
            result.append(contentsOf: layoutSlot(slot, in: childRect, depth: depth + 1))
        }
        return result
    }

    private static func childSlots(for node: TreemapNode) -> [WeightedTreemapSlot] {
        var slots: [WeightedTreemapSlot] = node.children
            .filter { $0.usage.allocatedBytes > 0 }
            .map {
                WeightedTreemapSlot(
                    entry: .directory($0),
                    weight: $0.usage.allocatedBytes
                )
            }

        let visibleChildBytes = node.children.reduce(UInt64(0)) { partial, child in
            partial &+ child.usage.allocatedBytes
        }

        let files = node.files.filter { $0.allocatedBytes > 0 }
        let visibleFileBytes = files.reduce(UInt64(0)) { partial, file in
            partial &+ file.allocatedBytes
        }
        slots.append(contentsOf: files.map {
            WeightedTreemapSlot(entry: .file($0), weight: $0.allocatedBytes)
        })

        let directBytes = min(node.directAllocatedBytes, node.usage.allocatedBytes)
        if directBytes > visibleFileBytes {
            let remaining = directBytes - visibleFileBytes
            slots.append(
                WeightedTreemapSlot(
                    entry: .aggregate(
                        TreemapAggregate(
                            id: node.usage.path + "#other-files",
                            name: "Other files",
                            path: node.usage.path + "/[Other files]",
                            allocatedBytes: remaining
                        )
                    ),
                    weight: remaining
                )
            )
        }

        let descendantBytes = node.usage.allocatedBytes > directBytes
            ? node.usage.allocatedBytes - directBytes
            : 0
        if descendantBytes > visibleChildBytes {
            let remaining = descendantBytes - visibleChildBytes
            slots.append(
                WeightedTreemapSlot(
                    entry: .aggregate(
                        TreemapAggregate(
                            id: node.usage.path + "#other-folders",
                            name: "Other folders",
                            path: node.usage.path + "/[Other folders]",
                            allocatedBytes: remaining
                        )
                    ),
                    weight: remaining
                )
            )
        }

        return slots
            .filter { $0.weight > 0 }
            .sorted {
                if $0.weight == $1.weight { return $0.entry.id < $1.entry.id }
                return $0.weight > $1.weight
            }
    }

    private static func splitSlots(
        _ slots: [WeightedTreemapSlot],
        in rect: CGRect
    ) -> [(WeightedTreemapSlot, CGRect)] {
        let positive = slots.filter { $0.weight > 0 }
        guard !positive.isEmpty, rect.width > 1, rect.height > 1 else { return [] }
        return split(positive, in: rect)
    }

    private static func split(
        _ slots: [WeightedTreemapSlot],
        in rect: CGRect
    ) -> [(WeightedTreemapSlot, CGRect)] {
        guard slots.count > 1 else {
            return slots.first.map { [($0, rect)] } ?? []
        }

        let total = slots.reduce(UInt64(0)) { $0 &+ $1.weight }
        guard total > 0 else { return [] }

        let target = Double(total) / 2.0
        var running: UInt64 = 0
        var splitIndex = 1
        var bestDistance = Double.greatestFiniteMagnitude

        for index in 1..<slots.count {
            running &+= slots[index - 1].weight
            let distance = abs(Double(running) - target)
            if distance < bestDistance {
                bestDistance = distance
                splitIndex = index
            }
        }

        let first = Array(slots[..<splitIndex])
        let second = Array(slots[splitIndex...])
        let firstTotal = first.reduce(UInt64(0)) { $0 &+ $1.weight }
        let ratio = max(0.01, min(0.99, Double(firstTotal) / Double(total)))

        let firstRect: CGRect
        let secondRect: CGRect
        if rect.width >= rect.height {
            let width = rect.width * ratio
            firstRect = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
            secondRect = CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height)
        } else {
            let height = rect.height * ratio
            firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
            secondRect = CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height)
        }

        return split(first, in: firstRect) + split(second, in: secondRect)
    }
}
