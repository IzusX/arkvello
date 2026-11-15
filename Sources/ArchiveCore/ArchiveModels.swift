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

public enum ArchiveNameEncoding: UInt32, CaseIterable, Identifiable, Codable, Sendable {
    case auto = 0
    case utf8 = 65001
    case cp866 = 866
    case windows1251 = 1251
    case koi8r = 20866
    case windows1252 = 1252
    case cp437 = 437

    public var id: UInt32 { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Авто (UTF-8 / Кириллица)"
        case .utf8: return "UTF-8"
        case .cp866: return "CP866 (DOS Кириллица)"
        case .windows1251: return "Windows-1251 (Кириллица)"
        case .koi8r: return "KOI8-R"
        case .windows1252: return "Windows-1252 (Западная)"
        case .cp437: return "CP437 (DOS US)"
        }
    }

    public var shortBadge: String {
        switch self {
        case .auto: return "АВТО"
        case .utf8: return "UTF-8"
        case .cp866: return "CP866"
        case .windows1251: return "1251"
        case .koi8r: return "KOI8"
        case .windows1252: return "1252"
        case .cp437: return "CP437"
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

    public init(
        index: UInt32,
        path: String,
        name: String,
        size: UInt64?,
        packedSize: UInt64?,
        modifiedDate: Date?,
        posixMode: UInt32,
        attributes: String,
        crc32: UInt32?,
        method: String?,
        symlinkTarget: String?,
        isDirectory: Bool,
        isEncrypted: Bool,
        isSymlink: Bool
    ) {
        self.index = index
        self.path = path
        self.name = name
        self.size = size
        self.packedSize = packedSize
        self.modifiedDate = modifiedDate
        self.posixMode = posixMode
        self.attributes = attributes
        self.crc32 = crc32
        self.method = method
        self.symlinkTarget = symlinkTarget
        self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted
        self.isSymlink = isSymlink
    }

    public var id: UInt32 { index }

    public var crcHex: String? {
        guard let crc32 else { return nil }
        return String(format: "%08X", crc32)
    }
}

public enum OverwriteMode: Int, CaseIterable, Codable, Sendable {
    case askInteractive = 0
    case overwriteAll = 1
    case skipExisting = 2
    case autoRenameExtracted = 3
    case autoRenameExisting = 4

    var cValue: sz_overwrite_mode_t {
        switch self {
        case .askInteractive: return SZ_OVERWRITE_ASK
        case .overwriteAll: return SZ_OVERWRITE_ALL
        case .skipExisting: return SZ_OVERWRITE_SKIP
        case .autoRenameExtracted: return SZ_OVERWRITE_AUTO_RENAME
        case .autoRenameExisting: return SZ_OVERWRITE_AUTO_RENAME_EXISTING
        }
    }
}

public struct OverwriteConflict: Equatable, Sendable {
    public let existingPath: String
    public let existingSize: UInt64?
    public let existingModifiedDate: Date?
    public let newPath: String
    public let newSize: UInt64?
    public let newModifiedDate: Date?

    public init(
        existingPath: String,
        existingSize: UInt64?,
        existingModifiedDate: Date?,
        newPath: String,
        newSize: UInt64?,
        newModifiedDate: Date?
    ) {
        self.existingPath = existingPath
        self.existingSize = existingSize
        self.existingModifiedDate = existingModifiedDate
        self.newPath = newPath
        self.newSize = newSize
        self.newModifiedDate = newModifiedDate
    }
}

public enum OverwriteDecision: Sendable {
    case replace
    case replaceAll
    case skip
    case skipAll
    case autoRename
    case cancel

    var cValue: sz_overwrite_answer_t {
        switch self {
        case .replace: return SZ_OW_ANSWER_YES
        case .replaceAll: return SZ_OW_ANSWER_YES_TO_ALL
        case .skip: return SZ_OW_ANSWER_NO
        case .skipAll: return SZ_OW_ANSWER_NO_TO_ALL
        case .autoRename: return SZ_OW_ANSWER_AUTO_RENAME
        case .cancel: return SZ_OW_ANSWER_CANCEL
        }
    }
}

public struct ArchiveHashDigest: Identifiable, Equatable, Sendable {
    public let algorithm: String
    public let hex: String

    public var id: String { algorithm }

    public init(algorithm: String, hex: String) {
        self.algorithm = algorithm
        self.hex = hex
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
    public var excludeMacOSMetadata: Bool
    public var preserveMacExtendedAttributes: Bool

    public init(
        format: String? = nil,
        method: String? = nil,
        level: Int = 5,
        dictionarySizeKB: UInt32 = 0,
        threads: Int = 0,
        solidBlockBytes: Int64 = -1,
        splitVolumeBytes: UInt64 = 0,
        encryptHeaders: Bool = false,
        storeSymlinks: Bool = true,
        excludeMacOSMetadata: Bool = true,
        preserveMacExtendedAttributes: Bool = false
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
        self.excludeMacOSMetadata = excludeMacOSMetadata
        self.preserveMacExtendedAttributes = preserveMacExtendedAttributes
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
