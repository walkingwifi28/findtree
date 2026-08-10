import SwiftUI
import FindTreeCore

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var pendingTrash: FileUsage?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            summary
            Divider()

            TabView {
                storageView
                    .tabItem { Label("Storage", systemImage: "externaldrive") }

                filesView
                    .tabItem { Label("Files", systemImage: "doc.text.magnifyingglass") }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 980, minHeight: 680)
        .alert("FindTree Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "Unknown error")
        }
        .alert("Move file to Trash?", isPresented: trashBinding) {
            Button("Cancel", role: .cancel) { pendingTrash = nil }
            Button("Move to Trash", role: .destructive) {
                if let file = pendingTrash { model.trash(file) }
                pendingTrash = nil
            }
        } message: {
            Text(pendingTrash?.path ?? "")
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

            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning")
                    .foregroundStyle(.secondary)
            }

            Button(action: model.scan) {
                Label(model.snapshot == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
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
                SummaryCard(title: "Allocated", value: formatBytes(result.allocatedBytes), detail: "Physical allocation")
                SummaryCard(title: "Logical", value: formatBytes(result.logicalBytes), detail: "Apparent file size")
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

                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 10)

            if model.treemapRows.isEmpty {
                ContentUnavailableView(
                    "No child folders",
                    systemImage: "folder",
                    description: Text("This folder has no indexed child directories.")
                )
                .frame(height: 210)
            } else {
                TreemapView(items: model.treemapRows, onSelect: model.navigate)
                    .frame(height: 230)
            }

            HStack {
                TextField("Filter folders", text: $model.directoryFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)

                Picker("Sort", selection: $model.directorySort) {
                    ForEach(AppModel.DirectorySortMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 430)

                Spacer()

                if let usage = model.currentUsage {
                    Text("\(formatBytes(usage.allocatedBytes)) · \(usage.fileCount.formatted()) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            directoryHeader
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.directoryRows) { directory in
                        DirectoryRow(
                            directory: directory,
                            parentAllocated: model.currentUsage?.allocatedBytes ?? 0,
                            onOpen: { model.navigate(to: directory) }
                        )
                        Divider()
                    }
                }
            }
        }
    }

    private var directoryHeader: some View {
        HStack(spacing: 8) {
            Text("Folder")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Allocated")
                .frame(width: 105, alignment: .trailing)
            Text("Logical")
                .frame(width: 105, alignment: .trailing)
            Text("Files")
                .frame(width: 85, alignment: .trailing)
            Text("Folders")
                .frame(width: 85, alignment: .trailing)
            Text("Share")
                .frame(width: 70, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    private var filesView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Search indexed file names", text: $model.fileQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.searchFiles)

                Button("Search", action: model.searchFiles)
                    .keyboardShortcut(.return, modifiers: [])
                Button("Largest Files", action: model.showLargestFiles)

                if model.isSearchingFiles {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.top, 10)

            HStack(spacing: 8) {
                Text("File")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Allocated")
                    .frame(width: 110, alignment: .trailing)
                Text("Logical")
                    .frame(width: 110, alignment: .trailing)
                Text("Actions")
                    .frame(width: 100, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)

            Divider()

            if model.fileResults.isEmpty {
                ContentUnavailableView(
                    "Search the local file index",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Search by file name or show the largest files. No filesystem rescan is required.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.fileResults) { file in
                            FileRow(
                                file: file,
                                onReveal: { model.reveal(file) },
                                onTrash: { pendingTrash = file }
                            )
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )
    }

    private var trashBinding: Binding<Bool> {
        Binding(
            get: { pendingTrash != nil },
            set: { if !$0 { pendingTrash = nil } }
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

private struct DirectoryRow: View {
    let directory: DirectoryUsage
    let parentAllocated: UInt64
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text((directory.path as NSString).lastPathComponent)
                        .lineLimit(1)
                    Text(directory.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatBytes(directory.allocatedBytes))
                .frame(width: 105, alignment: .trailing)
                .monospacedDigit()
            Text(formatBytes(directory.logicalBytes))
                .frame(width: 105, alignment: .trailing)
                .monospacedDigit()
            Text(directory.fileCount.formatted())
                .frame(width: 85, alignment: .trailing)
                .monospacedDigit()
            Text(directory.directoryCount.formatted())
                .frame(width: 85, alignment: .trailing)
                .monospacedDigit()
            Text(percentage(directory.allocatedBytes, of: parentAllocated))
                .frame(width: 70, alignment: .trailing)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .contextMenu {
            Button("Open Folder", action: onOpen)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory.path)])
            }
        }
    }
}

private struct FileRow: View {
    let file: FileUsage
    let onReveal: () -> Void
    let onTrash: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "doc.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .lineLimit(1)
                    Text(file.parentPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatBytes(file.allocatedBytes))
                .frame(width: 110, alignment: .trailing)
                .monospacedDigit()
            Text(formatBytes(file.logicalBytes))
                .frame(width: 110, alignment: .trailing)
                .monospacedDigit()

            HStack(spacing: 8) {
                Button(action: onReveal) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")

                Button(role: .destructive, action: onTrash) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Move to Trash")
            }
            .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onReveal)
    }
}
