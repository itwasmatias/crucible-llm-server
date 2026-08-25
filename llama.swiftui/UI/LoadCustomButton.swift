import SwiftUI
import UniformTypeIdentifiers

struct LoadCustomButton: View {
    @ObservedObject private var llamaState: LlamaState
    @State private var showFileImporter = false

    // The picker filters on the GGUF content type when the system can resolve
    // one. Resolution is not guaranteed, so the selected file is validated by
    // name as well and the filter is never the only thing enforcing GGUF.
    private static let allowedContentTypes: [UTType] = {
        if let gguf = UTType(filenameExtension: LocalModelImport.allowedFileExtension) {
            return [gguf]
        }
        return [.data]
    }()

    init(llamaState: LlamaState) {
        self.llamaState = llamaState
    }

    var body: some View {
        Button("Import .gguf From Files") {
            showFileImporter = true
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: LoadCustomButton.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let files):
                guard let file = files.first else {
                    llamaState.messageLog += "No model file was selected\n"
                    return
                }
                Task {
                    do {
                        try await llamaState.loadLocalModel(at: file.absoluteURL)
                    } catch {
                        llamaState.messageLog += "Model import failed: \(error.localizedDescription)\n"
                    }
                }
            case .failure(let error):
                llamaState.messageLog += "Model import failed: \(error.localizedDescription)\n"
            }
        }
    }
}
