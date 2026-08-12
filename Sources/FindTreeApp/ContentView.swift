import SwiftUI
import FindTreeCore

private enum AppVisualStyle: String {
    case standard
    case neumorphism
}

private enum AppScreen {
    case main
    case settings
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var currentScreen = AppScreen.main
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("findtree.visualStyle") private var visualStyleRawValue = AppVisualStyle.neumorphism.rawValue

    private let neumorphicHorizontalInset: CGFloat = 12
    private let neumorphicScanButtonContentWidth: CGFloat = 72
    private let settingsContentMaxWidth: CGFloat = 560

    private var visualStyle: AppVisualStyle {
        get { AppVisualStyle(rawValue: visualStyleRawValue) ?? .neumorphism }
        nonmutating set { visualStyleRawValue = newValue.rawValue }
    }

    var body: some View {
        Group {
            switch currentScreen {
            case .main:
                mainContent
            case .settings:
                settingsContent
            }
        }
            .frame(minWidth: 980, minHeight: 680)
            .onAppear {
                if visualStyleRawValue == "neumorphic" {
                    visualStyleRawValue = AppVisualStyle.neumorphism.rawValue
                }
            }
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
        case .neumorphism:
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
                .disabled(model.isScanning)
                .background {
                    DisabledCursorRegion(isDisabled: model.isScanning)
                }

                rootPathLabel

                scanButton

                settingsButton
            }
            .padding(12)
        case .neumorphism:
            HStack(spacing: 14) {
                Button(action: model.chooseRootFolder) {
                    Label("Folder", systemImage: "folder")
                }
                .disabled(model.isScanning)
                .buttonStyle(NeumorphicButtonStyle())
                .background {
                    DisabledCursorRegion(isDisabled: model.isScanning)
                }

                rootPathLabel
                    .padding(.horizontal, 4)

                scanButton
                    .buttonStyle(
                        NeumorphicButtonStyle(
                            forcePressed: model.isScanning,
                            preserveOpacityWhenForcedPressed: true
                        )
                    )

                settingsButton
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
            Group {
                if model.isScanning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("\(model.scanProgressPercent ?? 0)%")
                            .monospacedDigit()
                    }
                } else {
                    Label(model.snapshot == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
                }
            }
            .lineLimit(1)
            .frame(
                width: visualStyle == .neumorphism ? neumorphicScanButtonContentWidth : nil
            )
        }
        .disabled(model.isScanning)
        .keyboardShortcut("r", modifiers: [.command])
    }

    @ViewBuilder
    private var settingsButton: some View {
        switch visualStyle {
        case .standard:
            Button {
                currentScreen = .settings
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 16, height: 18)
                    .frame(width: 36, height: 26)
                    .background(
                        .primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")

        case .neumorphism:
            Button {
                currentScreen = .settings
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 16, height: 17)
            }
            .buttonStyle(
                NeumorphicButtonStyle(
                    horizontalPadding: 10,
                    verticalPadding: 9
                )
            )
            .accessibilityLabel("Settings")
        }
    }

    private var settingsContent: some View {
        ZStack {
            NeumorphicTheme.surface(for: colorScheme)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                settingsHeader

                if visualStyle == .standard {
                    Divider()
                }

                ScrollView {
                    VStack(spacing: visualStyle == .standard ? 16 : 32) {
                        SettingsSection(
                            title: "Appearance",
                            showsBackground: visualStyle == .standard
                        ) {
                            HStack(spacing: 12) {
                                Text("UI")
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                appearanceControl
                                    .frame(width: 220, alignment: .trailing)
                            }
                        }

                        SettingsSection(
                            title: "About",
                            showsBackground: visualStyle == .standard
                        ) {
                            VStack(spacing: 12) {
                                HStack(spacing: 12) {
                                    Text("Creator")
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 12)
                                    Text("@walkingwifi28")
                                        .frame(width: 220, alignment: .trailing)
                                }

                                HStack(spacing: 12) {
                                    Text("Version")
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 12)
                                    Text(appVersion)
                                        .monospacedDigit()
                                        .frame(width: 220, alignment: .trailing)
                                }
                            }
                        }
                    }
                    .padding(visualStyle == .standard ? 20 : neumorphicHorizontalInset)
                    .frame(maxWidth: settingsContentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var settingsHeader: some View {
        switch visualStyle {
        case .standard:
            HStack(spacing: 12) {
                Button {
                    currentScreen = .main
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }

                Text("Settings")
                    .font(.title2.weight(.semibold))

                Spacer()
            }
            .padding(12)

        case .neumorphism:
            HStack(spacing: 14) {
                Button {
                    currentScreen = .main
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(
                    NeumorphicButtonStyle(
                        horizontalPadding: 12,
                        verticalPadding: 8
                    )
                )

                Text("Settings")
                    .font(.title2.weight(.semibold))

                Spacer()
            }
            .padding(.horizontal, neumorphicHorizontalInset)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        return "v\(version ?? "0.1.1")"
    }

    @ViewBuilder
    private var appearanceControl: some View {
        switch visualStyle {
        case .standard:
            Picker("Appearance", selection: $visualStyleRawValue) {
                Text("Standard")
                    .tag(AppVisualStyle.standard.rawValue)
                Text("Neumorphism")
                    .tag(AppVisualStyle.neumorphism.rawValue)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 220, alignment: .trailing)

        case .neumorphism:
            Menu {
                Button {
                    visualStyleRawValue = AppVisualStyle.standard.rawValue
                } label: {
                    if visualStyle == .standard {
                        Label("Standard", systemImage: "checkmark")
                    } else {
                        Text("Standard")
                    }
                }

                Button {
                    visualStyleRawValue = AppVisualStyle.neumorphism.rawValue
                } label: {
                    if visualStyle == .neumorphism {
                        Label("Neumorphism", systemImage: "checkmark")
                    } else {
                        Text("Neumorphism")
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(visualStyle == .standard ? "Standard" : "Neumorphism")
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 180)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .neumorphicRaised(
                    cornerRadius: 12,
                    shadowRadius: 7,
                    distance: 5,
                    strength: 1
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
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
            case .neumorphism:
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
            case .neumorphism:
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
                    legendTrailingPadding: visualStyle == .neumorphism ? 0 : 2
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

private struct SettingsSection<Content: View>: View {
    let title: String
    var inline = false
    var showsBackground = true
    @ViewBuilder let content: () -> Content

    @ViewBuilder
    var body: some View {
        Group {
            if inline {
                HStack(spacing: 12) {
                    Text(title)
                        .font(.headline)

                    Spacer(minLength: 12)

                    content()
                        .frame(width: 220, alignment: .trailing)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text(title)
                        .font(.headline)

                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if showsBackground {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.28))
            }
        }
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
        case .neumorphism:
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
