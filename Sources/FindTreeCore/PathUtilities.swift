import Foundation

enum PathUtilities {
    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }


    static func isDescendantOrEqual(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
