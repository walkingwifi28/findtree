import SwiftUI
import FindTreeCore

struct TreemapView: View {
    let items: [DirectoryUsage]
    let onSelect: (DirectoryUsage) -> Void

    var body: some View {
        GeometryReader { proxy in
            let layouts = TreemapLayout.layout(items: items, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(layouts) { layout in
                    Button {
                        onSelect(layout.usage)
                    } label: {
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(color(for: layout.usage.path))
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(.white.opacity(0.25), lineWidth: 1)

                            if layout.rect.width > 80, layout.rect.height > 42 {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((layout.usage.path as NSString).lastPathComponent)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text(formatBytes(layout.usage.allocatedBytes))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(7)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: max(layout.rect.width - 2, 0), height: max(layout.rect.height - 2, 0))
                    .offset(x: layout.rect.minX + 1, y: layout.rect.minY + 1)
                    .help(layout.usage.path + " — " + formatBytes(layout.usage.allocatedBytes))
                }
            }
        }
    }

    private func color(for path: String) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.45, brightness: 0.78)
    }
}

private struct TreemapLayoutItem: Identifiable {
    let usage: DirectoryUsage
    let rect: CGRect
    var id: String { usage.path }
}

private enum TreemapLayout {
    static func layout(items: [DirectoryUsage], in rect: CGRect) -> [TreemapLayoutItem] {
        let positive = items.filter { $0.allocatedBytes > 0 }
        guard !positive.isEmpty, rect.width > 1, rect.height > 1 else { return [] }
        return split(positive, in: rect, depth: 0)
    }

    private static func split(_ items: [DirectoryUsage], in rect: CGRect, depth: Int) -> [TreemapLayoutItem] {
        guard items.count > 1 else {
            return items.first.map { [TreemapLayoutItem(usage: $0, rect: rect)] } ?? []
        }

        let total = items.reduce(UInt64(0)) { $0 &+ $1.allocatedBytes }
        guard total > 0 else { return [] }

        let target = Double(total) / 2.0
        var running: UInt64 = 0
        var splitIndex = 1
        var bestDistance = Double.greatestFiniteMagnitude

        for index in 1..<items.count {
            running &+= items[index - 1].allocatedBytes
            let distance = abs(Double(running) - target)
            if distance < bestDistance {
                bestDistance = distance
                splitIndex = index
            }
        }

        let first = Array(items[..<splitIndex])
        let second = Array(items[splitIndex...])
        let firstTotal = first.reduce(UInt64(0)) { $0 &+ $1.allocatedBytes }
        let ratio = max(0.05, min(0.95, Double(firstTotal) / Double(total)))

        let splitVertically = rect.width >= rect.height
        let firstRect: CGRect
        let secondRect: CGRect

        if splitVertically {
            let width = rect.width * ratio
            firstRect = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
            secondRect = CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height)
        } else {
            let height = rect.height * ratio
            firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
            secondRect = CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height)
        }

        return split(first, in: firstRect, depth: depth + 1)
            + split(second, in: secondRect, depth: depth + 1)
    }
}
