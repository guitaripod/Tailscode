import CodingAgentKit
import Foundation

enum AppCache {
    static let sessionCache: SessionCache? = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions", isDirectory: true)
        return try? FileSessionCache(directory: dir)
    }()
}
