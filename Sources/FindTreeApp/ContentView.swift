import SwiftUI
import FindTreeCore

struct ContentView: View {
    @StateObject private var model = AppModel()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            NeumorphicTheme.surface(for: colorScheme)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                toolbar
                summary

                storageView
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 18)
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .alert("Full Disk Access is not enabled", isPresented: $model.shouldShowFullDiskAccessNotice) {
            Button("Open Settings") {
                model.dismissFullDiskAccessNotice()
                model.openFullDiskAccessSettings()
            }
            Button("Later", role: .cancel) {
                model.dismissFullDiskAccessNotice()
            }
        } message: {
            Text("To scan the entire Mac, allow FindTree in System Settings → Privacy & Security → Full Disk Access. After enabling it, restart FindTree.")
        }
        .alert("FindTree Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "Unknown error")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button(action: model.chooseRootFolder) {
                Label("Folder", systemImage: "folder")
            }
            .buttonStyle(NeumorphicButtonStyle())

            Text(model.rootPath)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

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
            .buttonStyle(NeumorphicButtonStyle())
            .disabled(model.isScanning)
            .keyboardShortcut("r", modifiers: [.command])

            Button(action: {}) {
                Image(systemName: "ellipsis")
                    .frame(width: 16)
            }
            .buttonStyle(
                NeumorphicButtonStyle(
                    cornerRadius: 12,
                    horizontalPadding: 10,
                    verticalPadding: 9
                )
            )
            .disabled(true)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var summary: some View {
        if let result = model.snapshot?.result {
            HStack(spacing: 14) {
                SummaryCard(title: "Capacity", value: model.totalCapacityBytes.map(formatBytes) ?? "—", systemImage: "externaldrive")
                SummaryCard(title: "Volume Used", value: model.volumeUsedBytes.map(formatBytes) ?? "—", systemImage: "chart.pie")
                SummaryCard(title: "Free", value: model.volumeFreeBytes.map(formatBytes) ?? "—", systemImage: "circle.dashed")
                SummaryCard(title: "Files", value: result.fileCount.formatted(), systemImage: "doc")
                SummaryCard(title: "Folders", value: result.directoryCount.formatted(), systemImage: "folder")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                Text(model.statusMessage.isEmpty ? "Choose a folder and run Scan." : model.statusMessage)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(14)
            .neumorphicRaised(cornerRadius: 16, shadowRadius: 7, distance: 5, strength: 0.72)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    private var storageView: some View {
        VStack(spacing: 0) {
            if let treemapRoot = model.treemapRoot,
               !treemapRoot.children.isEmpty || treemapRoot.directAllocatedBytes > 0 {
                TreemapView(
                    root: treemapRoot,
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
        .padding(10)
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
    let systemImage: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
