import Foundation
import Darwin

enum PathUtilities {
    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    /// Returns the kernel-facing real path for an existing item. This matters for FSEvents,
    /// which can report paths such as /private/tmp while callers use the /tmp alias.
    static func canonicalExisting(_ path: String) -> String {
        let normalized = standardized(path)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = normalized.withCString { pointer in
            realpath(pointer, &buffer)
        }
        guard resolved != nil else { return normalized }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func isDescendantOrEqual(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
