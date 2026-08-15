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
    var legendLeadingPadding: CGFloat = 2
    var legendTrailingPadding: CGFloat = 2

    @State private var selectedDirectoryID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TreemapColorLegend(
                leadingPadding: legendLeadingPadding,
                trailingPadding: legendTrailingPadding
            )

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
                            onMoveToTrash: onMoveToTrash,
                            onSelectDirectory: { selectedDirectoryID = $0 }
                        )
                    }

                    if let selectedDirectoryID,
                       let selectedLayout = layouts.first(where: { layout in
                           guard case .directory = layout.entry else { return false }
                           return layout.entry.id == selectedDirectoryID
                       }) {
                        TreemapSelectionBorder(layout: selectedLayout)
                            .zIndex(10_000)
                            .allowsHitTesting(false)
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
}

private struct TreemapColorLegend: View {
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat

    var body: some View {
        HStack(spacing: 14) {
            ForEach(TreemapFileCategory.allCases, id: \.self) { category in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(TreemapColor.legendColor(for: category))
                        .frame(width: 10, height: 10)

                    Text(category.legendTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.top, 8)
        .padding(.leading, leadingPadding)
        .padding(.trailing, trailingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
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
    let onSelectDirectory: (String) -> Void

    var body: some View {
        tileContent
        .frame(width: tileWidth, height: tileHeight)
        // Non-terminal folders are transparent, so make the entire folder tile
        // participate in hit testing instead of only its label and border.
        .contentShape(Rectangle())
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
        .onTapGesture {
            guard case .directory = layout.entry else { return }
            FastTreemapTooltipController.shared.hide()
            onSelectDirectory(layout.entry.id)
        }
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
                        ? TreemapColor.terminalColor(for: layout.entry)
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
                    .padding(.horizontal, layout.depth <= 2 ? 8 : 6)
                    .padding(.top, layout.depth <= 2 ? 7 : 5)
                    .padding(.bottom, layout.depth <= 2 ? 6 : 4)
                } else {
                    HStack(spacing: 4) {
                        Text(layout.entry.displayName)
                            .font(labelFont)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(formatBytes(layout.entry.allocatedBytes))
                            .font(sizeLabelFont)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, TreemapLabelMetrics.parentVerticalPadding)
                }
            }
        }
    }

    private var tileWidth: CGFloat { max(layout.rect.width - layout.gap * 2, 0) }
    private var tileHeight: CGFloat { max(layout.rect.height - layout.gap * 2, 0) }
    private var cornerRadius: CGFloat { layout.depth <= 1 ? 4 : 2 }
    private var borderOpacity: Double { 0.18 }

    private var shouldShowLabel: Bool {
        if layout.isTerminal {
            return TreemapLabelMetrics.shouldShowTerminalLabel(in: layout.rect)
        }
        return TreemapLabelMetrics.shouldShowParentLabel(in: layout.rect)
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

private struct TreemapSelectionBorder: View {
    let layout: TreemapLayoutItem

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(TreemapColor.selectionBorderColor, lineWidth: 2.5)
            .frame(width: tileWidth, height: tileHeight)
            .offset(x: layout.rect.minX + layout.gap, y: layout.rect.minY + layout.gap)
    }

    private var tileWidth: CGFloat { max(layout.rect.width - layout.gap * 2, 0) }
    private var tileHeight: CGFloat { max(layout.rect.height - layout.gap * 2, 0) }
    private var cornerRadius: CGFloat { layout.depth <= 1 ? 4 : 2 }
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

private enum TreemapFileCategory: CaseIterable {
    case video
    case image
    case audio
    case archive
    case application
    case document
    case code
    case system
    case other

    var legendTitle: String {
        switch self {
        case .video: return "Video"
        case .image: return "Image"
        case .audio: return "Audio"
        case .archive: return "Archive"
        case .application: return "Application"
        case .document: return "Document"
        case .code: return "Code"
        case .system: return "System"
        case .other: return "Other"
        }
    }

    static func classify(fileName: String) -> TreemapFileCategory {
        let lowercasedName = fileName.lowercased()
        let ext = (lowercasedName as NSString).pathExtension

        switch ext {
        case "mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv", "flv", "mpeg", "mpg", "m2ts", "mts", "3gp":
            return .video
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "ico", "icns", "avif", "raw", "dng", "psd":
            return .image
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus", "aiff", "aif", "wma", "caf":
            return .audio
        case "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz", "lzma", "cab", "iso", "dmg", "pkg", "xip":
            return .archive
        case "app", "exe", "dll", "dylib", "so", "bin", "msi", "com", "bundle", "plugin", "appex":
            return .application
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "rtfd", "odt", "ods", "odp", "epub", "md", "markdown", "txt", "csv", "tsv":
            return .document
        case "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts", "py", "rb", "php", "go", "rs", "js", "jsx", "ts", "tsx", "vue", "svelte", "html", "htm", "css", "scss", "sass", "less", "json", "yaml", "yml", "toml", "xml", "sql", "sh", "bash", "zsh", "fish", "ps1", "gradle":
            return .code
        case "plist", "strings", "stringsdict", "entitlements", "mobileprovision", "car", "mom", "momd", "nib", "storyboardc", "xcassets", "DS_Store".lowercased():
            return .system
        default:
            if lowercasedName == ".ds_store" || lowercasedName.hasPrefix("._") {
                return .system
            }
            return .other
        }
    }

    static func classify(directoryPath: String) -> TreemapFileCategory? {
        let ext = (directoryPath.lowercased() as NSString).pathExtension
        switch ext {
        case "app", "bundle", "plugin", "appex", "xpc":
            return .application
        case "framework", "kext", "systemextension":
            return .system
        default:
            return nil
        }
    }
}

private enum TreemapColor {
    static var selectionBorderColor: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            if match == .darkAqua {
                // Windows 11-style bright blue accent for dark surfaces.
                return NSColor(srgbRed: 96.0 / 255.0, green: 205.0 / 255.0, blue: 255.0 / 255.0, alpha: 1.0)
            }
            return NSColor(srgbRed: 0.0 / 255.0, green: 120.0 / 255.0, blue: 212.0 / 255.0, alpha: 1.0)
        })
    }

    static func legendColor(for category: TreemapFileCategory) -> Color {
        systemColor(for: category)
    }

    static func terminalColor(for entry: TreemapEntry) -> Color {
        switch entry {
        case .file(let file):
            return systemColor(for: TreemapFileCategory.classify(fileName: file.name))

        case .directory(let node):
            if let packageCategory = TreemapFileCategory.classify(directoryPath: node.usage.path) {
                return systemColor(for: packageCategory)
            }

            if let dominant = dominantFileCategory(in: node.files) {
                return systemColor(for: dominant)
            }

            return systemColor(for: .system)

        case .aggregate(let aggregate):
            if aggregate.id.hasSuffix("#other-folders") {
                return systemColor(for: .system)
            }
            return systemColor(for: .other)
        }
    }

    private static func dominantFileCategory(in files: [FileUsage]) -> TreemapFileCategory? {
        guard !files.isEmpty else { return nil }

        var bytesByCategory: [TreemapFileCategory: UInt64] = [:]
        for file in files where file.allocatedBytes > 0 {
            let category = TreemapFileCategory.classify(fileName: file.name)
            bytesByCategory[category, default: 0] &+= file.allocatedBytes
        }

        return bytesByCategory.max(by: { $0.value < $1.value })?.key
    }

    private static func systemColor(for category: TreemapFileCategory) -> Color {
        let color: NSColor
        switch category {
        case .video:
            color = .systemBlue
        case .image:
            color = .systemPurple
        case .audio:
            color = .systemPink
        case .archive:
            color = .systemOrange
        case .application:
            color = .systemRed
        case .document:
            color = .systemGreen
        case .code:
            color = .systemCyan
        case .system:
            color = NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [.darkAqua, .aqua])
                if match == .darkAqua {
                    return NSColor(srgbRed: 72.0 / 255.0, green: 72.0 / 255.0, blue: 74.0 / 255.0, alpha: 1.0)
                }
                return NSColor(srgbRed: 199.0 / 255.0, green: 199.0 / 255.0, blue: 204.0 / 255.0, alpha: 1.0)
            }
        case .other:
            color = .systemYellow
        }

        // Keep the Apple system hue while letting the app background show through.
        // This preserves readable primary/secondary labels in both light and dark mode.
        return Color(nsColor: color).opacity(0.72)
    }
}

private enum TreemapLabelMetrics {
    static func shouldShowTerminalLabel(in rect: CGRect) -> Bool {
        rect.width > 72 && rect.height > 40
    }

    static func shouldShowParentLabel(in rect: CGRect) -> Bool {
        let minimumWidth: CGFloat = 78
        let headerHeight = parentHeaderHeight
        // Keep enough room below the label for the nested treemap. Using the same
        // predicate in both rendering and layout prevents child tiles from covering
        // a label that SwiftUI decided to draw.
        return rect.width > minimumWidth && rect.height > headerHeight + 8
    }

    static let parentVerticalPadding: CGFloat = 2

    static var parentHeaderHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: 10)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return lineHeight + parentVerticalPadding * 2
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
        if TreemapLabelMetrics.shouldShowParentLabel(in: rect) {
            labelHeight = TreemapLabelMetrics.parentHeaderHeight
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
