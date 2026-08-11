import SwiftUI
import FindTreeCore

private enum AppVisualStyle: String {
    case standard
    case neumorphic
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("findtree.visualStyle") private var visualStyleRawValue = AppVisualStyle.neumorphic.rawValue

    private let neumorphicHorizontalInset: CGFloat = 12

    private var visualStyle: AppVisualStyle {
        get { AppVisualStyle(rawValue: visualStyleRawValue) ?? .neumorphic }
        nonmutating set { visualStyleRawValue = newValue.rawValue }
    }

    var body: some View {
        mainContent
            .frame(minWidth: 980, minHeight: 680)
            .background {
                WindowAppearanceConfigurator(
                    visualStyleRawValue: visualStyleRawValue,
                    colorScheme: colorScheme
                )
                .frame(width: 0, height: 0)
            }
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

    @ViewBuilder
    private var mainContent: some View {
        switch visualStyle {
        case .standard:
            ZStack {
                NeumorphicTheme.surface(for: colorScheme)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    summary
                    Divider()

                    storageView
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
        case .neumorphic:
            ZStack {
                NeumorphicTheme.surface(for: colorScheme)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    toolbar
                    summary

                    storageView
                        .padding(.horizontal, neumorphicHorizontalInset)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        switch visualStyle {
        case .standard:
            HStack(spacing: 10) {
                Button(action: model.chooseRootFolder) {
                    Label("Folder", systemImage: "folder")
                }

                rootPathLabel

                scanButton

                optionsMenu
            }
            .padding(12)
        case .neumorphic:
            HStack(spacing: 14) {
                Button(action: model.chooseRootFolder) {
                    Label("Folder", systemImage: "folder")
                }
                .buttonStyle(NeumorphicButtonStyle())

                rootPathLabel
                    .padding(.horizontal, 4)

                scanButton
                    .buttonStyle(NeumorphicButtonStyle())

                optionsMenu
            }
            .padding(.horizontal, neumorphicHorizontalInset)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
    }

    private var rootPathLabel: some View {
        Text(model.rootPath)
            .font(.system(.body, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scanButton: some View {
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
    }

    @ViewBuilder
    private var optionsMenu: some View {
        switch visualStyle {
        case .standard:
            Menu {
                appearancePicker
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 16, height: 18)
                    .frame(width: 36, height: 26)
                    .background(
                        .primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel("Options")
        case .neumorphic:
            Menu {
                appearancePicker
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 16, height: 17)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .neumorphicRaised(cornerRadius: 12, shadowRadius: 7, distance: 5, strength: 1)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        }
    }

    private var appearancePicker: some View {
        Picker("Appearance", selection: $visualStyleRawValue) {
            Text("Standard")
                .tag(AppVisualStyle.standard.rawValue)
            Text("Neumorphic")
                .tag(AppVisualStyle.neumorphic.rawValue)
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let result = model.snapshot?.result {
            switch visualStyle {
            case .standard:
                HStack(spacing: 12) {
                    SummaryCard(title: "Capacity", value: model.totalCapacityBytes.map(formatBytes) ?? "—", systemImage: "externaldrive", visualStyle: visualStyle)
                    SummaryCard(title: "Volume Used", value: model.volumeUsedBytes.map(formatBytes) ?? "—", systemImage: "chart.pie", visualStyle: visualStyle)
                    SummaryCard(title: "Free", value: model.volumeFreeBytes.map(formatBytes) ?? "—", systemImage: "circle.dashed", visualStyle: visualStyle)
                    SummaryCard(title: "Files", value: result.fileCount.formatted(), systemImage: "doc", visualStyle: visualStyle)
                    SummaryCard(title: "Folders", value: result.directoryCount.formatted(), systemImage: "folder", visualStyle: visualStyle)
                }
                .padding(12)
            case .neumorphic:
                HStack(spacing: 14) {
                    SummaryCard(title: "Capacity", value: model.totalCapacityBytes.map(formatBytes) ?? "—", systemImage: "externaldrive", visualStyle: visualStyle)
                    SummaryCard(title: "Volume Used", value: model.volumeUsedBytes.map(formatBytes) ?? "—", systemImage: "chart.pie", visualStyle: visualStyle)
                    SummaryCard(title: "Free", value: model.volumeFreeBytes.map(formatBytes) ?? "—", systemImage: "circle.dashed", visualStyle: visualStyle)
                    SummaryCard(title: "Files", value: result.fileCount.formatted(), systemImage: "doc", visualStyle: visualStyle)
                    SummaryCard(title: "Folders", value: result.directoryCount.formatted(), systemImage: "folder", visualStyle: visualStyle)
                }
                .padding(.horizontal, neumorphicHorizontalInset)
                .padding(.vertical, 8)
            }
        } else {
            switch visualStyle {
            case .standard:
                HStack {
                    Image(systemName: "externaldrive.badge.questionmark")
                    Text(model.statusMessage.isEmpty ? "Choose a folder and run Scan." : model.statusMessage)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(14)
            case .neumorphic:
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
                .padding(.horizontal, neumorphicHorizontalInset)
                .padding(.vertical, 10)
            }
        }
    }

    private var storageView: some View {
        VStack(spacing: 0) {
            if let treemapRoot = model.treemapRoot,
               !treemapRoot.children.isEmpty || treemapRoot.directAllocatedBytes > 0 {
                TreemapView(
                    root: treemapRoot,
                    onMoveToTrash: model.moveToTrash,
                    legendLeadingPadding: 2,
                    legendTrailingPadding: visualStyle == .neumorphic ? 0 : 2
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
    let systemImage: String
    let visualStyle: AppVisualStyle

    @ViewBuilder
    var body: some View {
        switch visualStyle {
        case .standard:
            cardContent
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        case .neumorphic:
            cardContent
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }

    private var cardContent: some View {
        HStack(spacing: visualStyle == .standard ? 10 : 11) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: visualStyle == .standard ? .regular : .medium))
                .foregroundStyle(.secondary)
                .frame(width: visualStyle == .standard ? 22 : 24)

            VStack(alignment: .leading, spacing: visualStyle == .standard ? 3 : 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
