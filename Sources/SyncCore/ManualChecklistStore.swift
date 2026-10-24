import Foundation
import Darwin

public enum ManualChecklistStoreError: Error, LocalizedError, Sendable {
    case invalidLocation, unsafeLocation, readFailed, invalidState, writeFailed

    public var errorDescription: String? {
        switch self {
        case .invalidLocation: return "El checklist necesita una ubicación de archivo local válida."
        case .unsafeLocation: return "La ubicación del checklist debe ser un archivo normal dentro de un directorio privado, sin enlaces simbólicos."
        case .readFailed: return "No se pudo leer el checklist guardado. Revisá los permisos del archivo."
        case .invalidState: return "El checklist guardado no contiene un estado JSON válido. No se reemplazó por un estado vacío."
        case .writeFailed: return "No se pudo guardar el checklist de forma atómica. Revisá los permisos y el espacio disponible."
        }
    }
}

public actor ManualChecklistStore {
    private let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> ManualChecklistState? {
        try validateURL()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw ManualChecklistStoreError.unsafeLocation }
            throw ManualChecklistStoreError.readFailed
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ManualChecklistStoreError.unsafeLocation
        }
        let data: Data
        do { data = try file.readToEnd() ?? Data() }
        catch { throw ManualChecklistStoreError.readFailed }
        do { return try JSONDecoder().decode(ManualChecklistState.self, from: data) }
        catch { throw ManualChecklistStoreError.invalidState }
    }

    public func save(_ state: ManualChecklistState) throws {
        try validateURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(state) }
        catch { throw ManualChecklistStoreError.invalidState }
        let directory = url.deletingLastPathComponent()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            var directoryInfo = stat()
            guard lstat(directory.path, &directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR else {
                throw ManualChecklistStoreError.unsafeLocation
            }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch let error as ManualChecklistStoreError { throw error }
        catch { throw ManualChecklistStoreError.writeFailed }
        var destinationInfo = stat()
        if lstat(url.path, &destinationInfo) == 0, destinationInfo.st_mode & S_IFMT != S_IFREG {
            throw ManualChecklistStoreError.unsafeLocation
        }

        let temporaryURL = directory.appendingPathComponent(".manual-checklist-\(UUID().uuidString).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ManualChecklistStoreError.writeFailed }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? file.close()
            unlink(temporaryURL.path)
        }
        do {
            guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw ManualChecklistStoreError.writeFailed }
            try file.write(contentsOf: data)
            try file.synchronize()
            try file.close()
            guard rename(temporaryURL.path, url.path) == 0 else { throw ManualChecklistStoreError.writeFailed }
        } catch { throw ManualChecklistStoreError.writeFailed }
    }

    private func validateURL() throws {
        guard url.isFileURL, !url.hasDirectoryPath, !url.lastPathComponent.isEmpty,
              !url.path.utf8.contains(0), ![".", "..", "/"].contains(url.lastPathComponent) else {
            throw ManualChecklistStoreError.invalidLocation
        }
    }
}
