import SwiftUI
import UniformTypeIdentifiers

/// The file Export Interface Text… hands to the system's file exporter on the iPhone (FR39): the bytes of
/// `InterfaceTextOverridesWriter.export`, a JSON file, which the person saves where they choose.
struct InterfaceTextExportDocument: FileDocument {
    /// The exporter reads nothing back: the document only writes.
    static var readableContentTypes: [UTType] { [.json] }

    /// The file's bytes.
    let data: Data

    init(data: Data) {
        self.data = data
    }

    /// A document read from a file: its bytes as they are.
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    /// The file the exporter writes: the bytes as they are.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
