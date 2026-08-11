import SwiftUI
import AppKit
@preconcurrency import QuickLookUI

struct FinderContextMenu: View {
    let url: URL
    let onMoveToTrash: (URL) -> Void

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }

        Button {
            QuickLookPreviewController.shared.show(url: url)
        } label: {
            Label("Quick Look", systemImage: "eye")
        }

        Divider()

        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.path, forType: .string)
        } label: {
            Label("Copy Path", systemImage: "link")
        }

        Divider()

        Button(role: .destructive) {
            onMoveToTrash(url)
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
    }
}

private final class QuickLookPreviewController: NSObject, QLPreviewPanelDataSource {
    @MainActor static let shared = QuickLookPreviewController()

    nonisolated(unsafe) private var previewURL: URL?

    @MainActor
    func show(url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }
}
