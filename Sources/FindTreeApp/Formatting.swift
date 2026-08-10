import Foundation
import FindTreeCore

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

func percentage(_ part: UInt64, of total: UInt64) -> String {
    guard total > 0 else { return "0%" }
    return (Double(part) / Double(total)).formatted(.percent.precision(.fractionLength(1)))
}

extension DirectoryUsage: Identifiable {
    public var id: String { path }
}

extension FileUsage: Identifiable {
    public var id: String { path }
}
