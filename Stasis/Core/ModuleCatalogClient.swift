import CryptoKit
import Foundation
import Observation

struct ModuleCatalogIndex: Codable, Sendable {
    let formatVersion: Int
    let generatedAt: Date?
    let modules: [ModuleCatalogEntry]
}

struct ModuleCatalogEntry: Codable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let summary: String
    let version: String
    let downloadURL: URL
    let sha256: String
    let recommended: Bool
}

@MainActor
@Observable
final class ModuleCatalogClient {
    private(set) var entries: [ModuleCatalogEntry] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    let indexURL: URL

    init(indexURL: URL = URL(string: "https://raw.githubusercontent.com/Xu-Zhangsheng/Stasis/main/catalog/index.json")!) {
        self.indexURL = indexURL
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: indexURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw CatalogError.unavailable
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let index = try decoder.decode(ModuleCatalogIndex.self, from: data)
            guard index.formatVersion == 1 else { throw CatalogError.unsupportedFormat }
            entries = index.modules
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func download(_ entry: ModuleCatalogEntry) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: entry.downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CatalogError.unavailable }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(entry.id)-\(entry.version).stasismodule")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        let digest = SHA256.hash(data: try Data(contentsOf: destination))
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest.caseInsensitiveCompare(entry.sha256) == .orderedSame else {
            try? FileManager.default.removeItem(at: destination)
            throw CatalogError.checksumMismatch
        }
        return destination
    }
}

enum CatalogError: LocalizedError {
    case unavailable
    case unsupportedFormat
    case checksumMismatch
    var errorDescription: String? {
        switch self {
        case .unavailable: "The official module catalog is unavailable."
        case .unsupportedFormat: "The module catalog format is not supported."
        case .checksumMismatch: "The downloaded module does not match the catalog checksum."
        }
    }
}
