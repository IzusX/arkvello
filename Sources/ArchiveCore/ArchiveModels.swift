import CSevenZip
import Foundation

public enum ArchiveError: Error, LocalizedError, Equatable, Sendable {
    case openFailed(String)
    case passwordRequired
    case wrongPassword
    case corruptArchive(String)
    case unsupportedFormat(String)
    case cancelled
    case ioError(String)
    case invalidArgument(String)
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let detail):
            return "Не удалось открыть архив: \(detail)"
        case .passwordRequired:
            return "Архив защищён паролем. Требуется ввод пароля."
        case .wrongPassword:
            return "Неверный пароль к архиву."
        case .corruptArchive(let detail):
            return "Данные архива повреждены: \(detail)"
        case .unsupportedFormat(let detail):
            return "Формат или операция не поддерживается: \(detail)"
        case .cancelled:
            return "Операция отменена пользователем."
        case .ioError(let detail):
            return "Ошибка ввода-вывода: \(detail)"
        case .invalidArgument(let detail):
            return "Некорректные параметры операции: \(detail)"
        case .internalError(let detail):
            return "Внутренняя ошибка движка 7-Zip: \(detail)"
        }
    }

    static func from(status: sz_status_t, errorPointer: UnsafeMutablePointer<CChar>?) -> ArchiveError {
        let message: String
        if let errorPointer {
            message = String(cString: errorPointer)
            sz_string_free(errorPointer)
        } else {
            message = ""
        }

        switch status {
        case SZ_STATUS_ERR_OPEN:
            return .openFailed(message.isEmpty ? "неизвестный формат или повреждённый заголовок" : message)
        case SZ_STATUS_ERR_PASSWORD_REQUIRED:
            return .passwordRequired
        case SZ_STATUS_ERR_WRONG_PASSWORD:
            return .wrongPassword
        case SZ_STATUS_ERR_CORRUPT:
            return .corruptArchive(message)
        case SZ_STATUS_ERR_UNSUPPORTED:
            return .unsupportedFormat(message)
        case SZ_STATUS_ERR_CANCELLED:
            return .cancelled
        case SZ_STATUS_ERR_IO:
            return .ioError(message)
        case SZ_STATUS_ERR_INVALID_ARG:
            return .invalidArgument(message)
        default:
            return .internalError(message)
        }
    }
}

public struct ArchiveFormatInfo: Equatable, Hashable, Sendable {
    public let name: String
    public let extensions: [String]
    public let isUpdatable: Bool
    public let keepsStreamName: Bool

    public init(name: String, extensions: [String], isUpdatable: Bool, keepsStreamName: Bool) {
        self.name = name
        self.extensions = extensions
        self.isUpdatable = isUpdatable
        self.keepsStreamName = keepsStreamName
    }
}

public struct ArchiveSummary: Equatable, Sendable {
    public let formatName: String
    public let outerFormatName: String?
    public let comment: String?
    public let physicalSize: UInt64
    public let headersSize: UInt64
    public let itemCount: UInt32
    public let volumeCount: UInt32
    public let isSolid: Bool
    public let isMultiVolume: Bool
    public let isUpdatable: Bool
    public let headersEncrypted: Bool

    public var displayFormat: String {
        if let outer = outerFormatName, !outer.isEmpty {
            return "\(outer) → \(formatName)"
        }
        return formatName
    }
}

public struct ArchiveEntry: Identifiable, Equatable, Hashable, Sendable {
    public let index: UInt32
    public let path: String
    public let name: String
    public let size: UInt64?
    public let packedSize: UInt64?
    public let modifiedDate: Date?
    public let posixMode: UInt32
    public let attributes: String
    public let crc32: UInt32?
    public let method: String?
    public let symlinkTarget: String?
    public let isDirectory: Bool
    public let isEncrypted: Bool
    public let isSymlink: Bool

    public var id: UInt32 { index }

    public var crcHex: String? {
        guard let crc32 else { return nil }
        return String(format: "%08X", crc32)
    }
}

public enum OverwriteMode: Int, CaseIterable, Sendable {
    case overwriteAll = 1
    case skipExisting = 2
    case autoRenameExtracted = 3
    case autoRenameExisting = 4

    var cValue: sz_overwrite_mode_t {
        switch self {
        case .overwriteAll: return SZ_OVERWRITE_ALL
        case .skipExisting: return SZ_OVERWRITE_SKIP
        case .autoRenameExtracted: return SZ_OVERWRITE_AUTO_RENAME
        case .autoRenameExisting: return SZ_OVERWRITE_AUTO_RENAME_EXISTING
        }
    }
}

public struct CompressionOptions: Equatable, Sendable {
    public var format: String?
    public var method: String?
    public var level: Int
    public var dictionarySizeKB: UInt32
    public var threads: Int
    public var solidBlockBytes: Int64
    public var splitVolumeBytes: UInt64
    public var encryptHeaders: Bool
    public var storeSymlinks: Bool

    public init(
        format: String? = nil,
        method: String? = nil,
        level: Int = 5,
        dictionarySizeKB: UInt32 = 0,
        threads: Int = 0,
        solidBlockBytes: Int64 = -1,
        splitVolumeBytes: UInt64 = 0,
        encryptHeaders: Bool = false,
        storeSymlinks: Bool = true
    ) {
        self.format = format
        self.method = method
        self.level = level
        self.dictionarySizeKB = dictionarySizeKB
        self.threads = threads
        self.solidBlockBytes = solidBlockBytes
        self.splitVolumeBytes = splitVolumeBytes
        self.encryptHeaders = encryptHeaders
        self.storeSymlinks = storeSymlinks
    }
}

public struct ArchiveProgress: Equatable, Sendable {
    public let completedBytes: UInt64
    public let totalBytes: UInt64
    public let currentItem: String?

    public var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1.0, Double(completedBytes) / Double(totalBytes))
    }
}
