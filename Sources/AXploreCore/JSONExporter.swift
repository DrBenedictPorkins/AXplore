import Foundation

public enum JSONExporter {

    public static func export(_ result: AXScanResult, to dir: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(result)
        let path = (dir as NSString).appendingPathComponent("scan.json")
        try data.write(to: URL(fileURLWithPath: path))
        print("[export] JSON  -> \(path) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")
    }
}
