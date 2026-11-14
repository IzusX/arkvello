import AppKit
import ArchiveCore
import SwiftUI

struct PasswordPromptSheet: View {
    let request: PasswordPromptRequest
    @Environment(\.dismiss) private var dismiss
    @State private var password: String = ""
    @State private var revealPassword: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Требуется пароль")
                        .font(.headline)
                    Text(request.archiveURL.lastPathComponent)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if request.isRetryAfterFailure {
                Label("Введённый ранее пароль не подошёл. Проверьте раскладку и повторите попытку.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Group {
                    if revealPassword {
                        TextField("Пароль к архиву", text: $password)
                    } else {
                        SecureField("Пароль к архиву", text: $password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }

                Button {
                    revealPassword.toggle()
                } label: {
                    Image(systemName: revealPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealPassword ? "Скрыть пароль" : "Показать пароль")
            }

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) {
                    request.completion(nil)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Открыть") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        request.completion(password)
        dismiss()
    }
}

struct CompressSheetView: View {
    let request: CompressSheetRequest
    let onConfirm: (URL, CompressionOptions, String?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var archiveBaseName: String
    @State private var destinationFolder: URL
    @State private var format: String = "7z"
    @State private var compressionLevel: Int = 5
    @State private var method: String = "LZMA2"
    @State private var dictionarySizeKB: UInt32 = 16384
    @State private var solidMode: Int = -1 // -1 default solid, 0 non-solid
    @State private var splitPresetMB: Int = 0 // 0 = single file
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var encryptHeaders: Bool = true
    @State private var storeSymlinks: Bool = true

    init(
        request: CompressSheetRequest,
        onConfirm: @escaping (URL, CompressionOptions, String?) -> Void
    ) {
        self.request = request
        self.onConfirm = onConfirm
        _archiveBaseName = State(initialValue: request.suggestedArchiveName)
        _destinationFolder = State(initialValue: request.defaultDestinationFolder)
    }

    private var availableMethods: [String] {
        switch format {
        case "7z": return ["LZMA2", "LZMA", "PPMd", "BZip2", "Copy"]
        case "zip": return ["Deflate", "BZip2", "LZMA", "Copy"]
        default: return ["По умолчанию"]
        }
    }

    private var passwordMismatch: Bool {
        !password.isEmpty && password != confirmPassword
    }

    private var targetArchiveURL: URL {
        let trimmed = archiveBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Archive" : trimmed
        let expectedExt = ".\(format)"
        let fileName = base.lowercased().hasSuffix(expectedExt) ? base : "\(base)\(expectedExt)"
        return destinationFolder.appendingPathComponent(fileName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Добавить к архиву")
                .font(.headline)

            Form {
                Section("Назначение") {
                    TextField("Имя архива", text: $archiveBaseName)
                    HStack {
                        Text("Папка")
                        Spacer()
                        Text(destinationFolder.path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Выбрать…") {
                            chooseFolder()
                        }
                    }
                    LabeledContent("Объектов к сжатию") {
                        Text("\(request.inputURLs.count)")
                            .monospacedDigit()
                    }
                }

                Section("Параметры сжатия (7-Zip)") {
                    Picker("Формат архива", selection: $format) {
                        Text("7z").tag("7z")
                        Text("zip").tag("zip")
                        Text("tar").tag("tar")
                        Text("wim").tag("wim")
                    }
                    .onChange(of: format) { _, newValue in
                        if newValue == "7z" { method = "LZMA2" }
                        else if newValue == "zip" { method = "Deflate" }
                        else { method = "По умолчанию" }
                    }

                    if format == "7z" || format == "zip" {
                        Picker("Уровень сжатия", selection: $compressionLevel) {
                            Text("0 — Без сжатия (Store)").tag(0)
                            Text("1 — Скоростной").tag(1)
                            Text("3 — Быстрый").tag(3)
                            Text("5 — Нормальный").tag(5)
                            Text("7 — Максимальный").tag(7)
                            Text("9 — Ультра").tag(9)
                        }

                        Picker("Метод сжатия", selection: $method) {
                            ForEach(availableMethods, id: \.self) { m in
                                Text(m).tag(m)
                            }
                        }
                    }

                    if format == "7z" && compressionLevel > 0 {
                        Picker("Размер словаря", selection: $dictionarySizeKB) {
                            Text("Авто").tag(UInt32(0))
                            Text("4 МБ").tag(UInt32(4096))
                            Text("16 МБ").tag(UInt32(16384))
                            Text("32 МБ").tag(UInt32(32768))
                            Text("64 МБ").tag(UInt32(65536))
                        }

                        Picker("Режим непрерывности (Solid)", selection: $solidMode) {
                            Text("Непрерывный (Solid — по умолчанию)").tag(-1)
                            Text("Независимые блоки (быстрое обновление)").tag(0)
                        }
                    }

                    Picker("Разделить на тома", selection: $splitPresetMB) {
                        Text("Единый файл").tag(0)
                        Text("100 МБ").tag(100)
                        Text("700 МБ (CD)").tag(700)
                        Text("4096 МБ (FAT32)").tag(4096)
                    }

                    Toggle("Сохранять символические ссылки", isOn: $storeSymlinks)
                }

                if format == "7z" || format == "zip" {
                    Section("Шифрование (AES-256)") {
                        SecureField("Пароль (необязательно)", text: $password)
                        SecureField("Повторите пароль", text: $confirmPassword)
                        if passwordMismatch {
                            Text("Пароли не совпадают.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        if format == "7z" {
                            Toggle("Шифровать имена файлов (-mhe=on)", isOn: $encryptHeaders)
                                .disabled(password.isEmpty)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text(targetArchiveURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Отмена", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Создать архив") {
                    let chosenMethod: String? = (method == "По умолчанию") ? nil : method
                    let opts = CompressionOptions(
                        format: format,
                        method: chosenMethod,
                        level: (format == "tar" || format == "wim") ? 0 : compressionLevel,
                        dictionarySizeKB: format == "7z" ? dictionarySizeKB : 0,
                        threads: 0,
                        solidBlockBytes: Int64(solidMode),
                        splitVolumeBytes: splitPresetMB > 0 ? UInt64(splitPresetMB) * 1024 * 1024 : 0,
                        encryptHeaders: format == "7z" && !password.isEmpty && encryptHeaders,
                        storeSymlinks: storeSymlinks
                    )
                    onConfirm(targetArchiveURL, opts, password.isEmpty ? nil : password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(passwordMismatch || archiveBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520, height: 590)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = destinationFolder
        if panel.runModal() == .OK, let url = panel.url {
            destinationFolder = url
        }
    }
}

struct ExtractSheetView: View {
    let request: ExtractSheetRequest
    let onConfirm: (URL, Bool, Bool, OverwriteMode, String?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var destinationFolder: URL
    @State private var createArchiveSubfolder: Bool
    @State private var fullPaths: Bool = true
    @State private var overwriteMode: OverwriteMode = .overwriteAll
    @State private var password: String = ""

    init(
        request: ExtractSheetRequest,
        onConfirm: @escaping (URL, Bool, Bool, OverwriteMode, String?) -> Void
    ) {
        self.request = request
        self.onConfirm = onConfirm
        _destinationFolder = State(initialValue: request.defaultDestinationFolder)
        // When extracting the whole archive, default to creating a clean subfolder named after the archive
        _createArchiveSubfolder = State(initialValue: request.selectedPaths.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.selectedPaths.isEmpty ? "Извлечь весь архив" : "Извлечь выбранные объекты (\(request.selectedPaths.count))")
                .font(.headline)

            Form {
                Section("Куда извлечь") {
                    HStack {
                        Text(destinationFolder.path)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("Обзор…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.canCreateDirectories = true
                            panel.directoryURL = destinationFolder
                            if panel.runModal() == .OK, let url = panel.url {
                                destinationFolder = url
                            }
                        }
                    }

                    Toggle(
                        "Создать подпапку «\(AppViewModel.archiveBaseName(for: request.archiveURL))»",
                        isOn: $createArchiveSubfolder
                    )
                }

                Section("Режим путей и перезаписи") {
                    Picker("Структура папок", selection: $fullPaths) {
                        Text("Полные пути папок").tag(true)
                        Text("Плоский список (без подпапок)").tag(false)
                    }

                    Picker("При совпадении имён", selection: $overwriteMode) {
                        Text("Заменить существующие файлы").tag(OverwriteMode.overwriteAll)
                        Text("Пропустить существующие файлы").tag(OverwriteMode.skipExisting)
                        Text("Автопереименование извлекаемых файлов").tag(OverwriteMode.autoRenameExtracted)
                        Text("Автопереименование старых файлов").tag(OverwriteMode.autoRenameExisting)
                    }
                }

                Section("Пароль (если зашифрован)") {
                    SecureField("Оставьте пустым, если пароль не требуется или уже введён", text: $password)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Извлечь") {
                    onConfirm(
                        destinationFolder,
                        createArchiveSubfolder,
                        fullPaths,
                        overwriteMode,
                        password.isEmpty ? nil : password
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 490, height: 420)
    }
}

struct SimpleNamePromptSheet: View {
    let title: String
    let fieldLabel: String
    let confirmTitle: String
    @State var text: String
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)

            TextField(fieldLabel, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { finish() }

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(confirmTitle) {
                    finish()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.contains("/"))
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func finish() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        onSubmit(trimmed)
        dismiss()
    }
}

struct PropertiesSheetView: View {
    let request: PropertiesSheetRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Свойства")
                .font(.headline)

            Form {
                if let sum = request.summary {
                    Section("Контейнер архива") {
                        LabeledContent("Формат", value: sum.displayFormat)
                        LabeledContent("Физический размер", value: ByteFormatting.string(for: sum.physicalSize))
                        if sum.headersSize > 0 {
                            LabeledContent("Размер заголовков", value: ByteFormatting.string(for: sum.headersSize))
                        }
                        LabeledContent("Всего записей в архиве", value: "\(sum.itemCount)")
                        LabeledContent("Непрерывный (Solid)", value: sum.isSolid ? "Да" : "Нет")
                        LabeledContent("Томов", value: "\(sum.volumeCount)")
                        LabeledContent("Шифрование заголовков", value: sum.headersEncrypted ? "Включено" : "Нет")
                        LabeledContent("Поддержка записи", value: sum.isUpdatable ? "Чтение и запись" : "Только чтение")
                    }
                }

                if !request.selectedRows.isEmpty {
                    Section(request.selectedRows.count == 1 ? "Выбранный объект" : "Выделение (\(request.selectedRows.count))") {
                        if request.selectedRows.count == 1, let item = request.selectedRows.first {
                            LabeledContent("Имя", value: item.name)
                            LabeledContent("Тип", value: item.isDirectory ? "Папка" : "Файл")
                            LabeledContent("Размер", value: ByteFormatting.string(for: item.size))
                            if item.packedSize != nil {
                                LabeledContent("Сжатый размер", value: ByteFormatting.string(for: item.packedSize))
                            }
                            LabeledContent("Изменён", value: ByteFormatting.dateString(item.modifiedDate))
                            if !item.attributes.isEmpty {
                                LabeledContent("Атрибуты", value: item.attributes)
                            }
                            if !item.crcHex.isEmpty {
                                LabeledContent("CRC32", value: item.crcHex)
                            }
                            if !item.method.isEmpty {
                                LabeledContent("Метод", value: item.method)
                            }
                        } else {
                            let total = request.selectedRows.reduce(UInt64(0)) { $0 &+ ($1.size ?? 0) }
                            let packed = request.selectedRows.reduce(UInt64(0)) { $0 &+ ($1.packedSize ?? 0) }
                            LabeledContent("Объектов", value: "\(request.selectedRows.count)")
                            LabeledContent("Суммарный размер", value: ByteFormatting.string(for: total))
                            if packed > 0 {
                                LabeledContent("Суммарный сжатый", value: ByteFormatting.string(for: packed))
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Закрыть") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 450, height: 420)
    }
}
