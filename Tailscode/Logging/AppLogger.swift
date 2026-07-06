import Foundation
import OSLog

enum AppLogger {
    enum Category: String {
        case lifecycle, connection, session, chat, streaming, persistence, ui
    }

    static let lifecycle = AppLog(.lifecycle)
    static let connection = AppLog(.connection)
    static let session = AppLog(.session)
    static let chat = AppLog(.chat)
    static let streaming = AppLog(.streaming)
    static let persistence = AppLog(.persistence)
    static let ui = AppLog(.ui)
}

struct AppLog: Sendable {
    private let category: AppLogger.Category
    private let logger: Logger

    init(_ category: AppLogger.Category) {
        self.category = category
        self.logger = Logger(subsystem: "com.guitaripod.tailscode", category: category.rawValue)
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        LogFileWriter.shared.write("[\(category.rawValue)] \(message)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        LogFileWriter.shared.write("[\(category.rawValue)] ERROR \(message)")
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        LogFileWriter.shared.write("[\(category.rawValue)] \(message)")
    }
}
