import SwiftUI
import FindTreeCore

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            summary
            Divider()

            storageView
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .frame(minWidth: 980, minHeight: 680)
        .alert("FindTree Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "Unknown error")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: model.chooseRootFolder) {
                Label("Folder", systemImage: "folder")
            }

            Text(model.rootPath)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: model.scan) {
                if model.isScanning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("\(model.scanProgressPercent ?? 0)%")
                            .monospacedDigit()
                    }
                    .frame(minWidth: 62)
                } else {
                    Label(model.snapshot == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isScanning)
            .keyboardShortcut("r", modifiers: [.command])

            Button(action: model.toggleWatching) {
                Label(
                    model.isWatching ? "Live" : "Paused",
                    systemImage: model.isWatching ? "dot.radiowaves.left.and.right" : "pause.circle"
                )
            }
            .disabled(model.snapshot == nil || model.isScanning)

            Menu {
                Button("Reveal Current Folder in Finder", action: model.revealCurrentDirectory)
                Button("Full Disk Access Settings", action: model.openFullDiskAccessSettings)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var summary: some View {
        if let result = model.snapshot?.result {
            HStack(spacing: 12) {
                SummaryCard(
                    title: "Capacity",
                    value: model.totalCapacityBytes.map(formatBytes) ?? "—",
                    detail: "Total volume capacity"
                )
                SummaryCard(title: "Allocated", value: formatBytes(result.allocatedBytes), detail: "Physical allocation")
                SummaryCard(title: "Files", value: result.fileCount.formatted(), detail: "Indexed files")
                SummaryCard(title: "Folders", value: result.directoryCount.formatted(), detail: "Indexed directories")

                if result.inaccessibleDirectoryCount > 0 {
                    Button(action: model.openFullDiskAccessSettings) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Access")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(result.inaccessibleDirectoryCount) unreadable")
                                .font(.headline)
                            Text("Open Full Disk Access")
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(12)
        } else {
            HStack {
                Image(systemName: "externaldrive.badge.questionmark")
                Text(model.statusMessage.isEmpty ? "Choose a folder and run Scan." : model.statusMessage)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(14)
        }
    }

    private var storageView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button(action: model.navigateUp) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canNavigateUp)

                Button(action: model.goToRoot) {
                    Image(systemName: "house")
                }
                .disabled(model.currentDirectory == model.rootPath)

                Text(model.currentDirectory)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if let usage = model.currentUsage {
                    Text("\(formatBytes(usage.allocatedBytes)) · \(usage.fileCount.formatted()) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 10)

            if let treemapRoot = model.treemapRoot,
               !treemapRoot.children.isEmpty || treemapRoot.directAllocatedBytes > 0 {
                TreemapView(
                    root: treemapRoot,
                    onSelectDirectory: model.navigate,
                    onSelectFile: model.revealFile,
                    onMoveToTrash: model.moveToTrash
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No child folders",
                    systemImage: "folder",
                    description: Text("This folder has no indexed child directories.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}
