import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject var llamaState = LlamaState()
    @State private var multiLineText = ""
    @State private var showingHelp = false
    @State private var apiKeyInput = ""
    @State private var apiKeyStatus = ""

    var body: some View {
        NavigationView {
            VStack {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(llamaState.messageLog)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .onTapGesture {
                                UIApplication.shared.sendAction(
                                    #selector(UIResponder.resignFirstResponder),
                                    to: nil,
                                    from: nil,
                                    for: nil
                                )
                            }

                        Color.clear
                            .frame(height: 1)
                            .id("messageLogBottom")
                    }
                    .onChange(of: llamaState.messageLog) { _ in
                        proxy.scrollTo("messageLogBottom", anchor: .bottom)
                    }
                }

                TextEditor(text: $multiLineText)
                    .frame(height: 80)
                    .padding()
                    .border(Color.gray, width: 0.5)

                HStack {
                    Button("Send") {
                        sendText()
                    }

                    Button("Bench") {
                        bench()
                    }

                    Button("Clear") {
                        clear()
                    }

                    Button("Copy") {
                        UIPasteboard.general.string = llamaState.messageLog
                    }
                }
                .buttonStyle(.bordered)
                .padding()

                VStack(alignment: .leading, spacing: 8) {
                    SecureField("MissionaryX API key", text: $apiKeyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    HStack {
                        Button("Save API Key") {
                            do {
                                try llamaState.saveAPIKey(apiKeyInput)
                                apiKeyInput = ""
                                apiKeyStatus = "API key configured"
                            } catch {
                                apiKeyStatus = error.localizedDescription
                            }
                        }

                        Button("Remove API Key") {
                            do {
                                try llamaState.clearAPIKey()
                                apiKeyInput = ""
                                apiKeyStatus = "API key removed"
                            } catch {
                                apiKeyStatus = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.bordered)

                    Text(
                        apiKeyStatus.isEmpty
                            ? (llamaState.apiKeyConfigured
                                ? "API key configured"
                                : "API key required before server start")
                            : apiKeyStatus
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                HStack {
                    Button(llamaState.serverRunning ? "Stop Server" : "Start Server") {
                        llamaState.toggleServer()
                    }
                    .foregroundColor(llamaState.serverRunning ? .red : .green)

                    if !llamaState.serverAddress.isEmpty {
                        Text(llamaState.serverAddress)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text(llamaState.serverStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)

                NavigationLink(destination: DrawerView(llamaState: llamaState)) {
                    Text("View Models")
                }
                .padding()

            }
            .padding()
            .navigationBarTitle("Model Settings", displayMode: .inline)

        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                llamaState.stopServerForBackground()
            }
        }
    }

    func sendText() {
        Task {
            await llamaState.complete(text: multiLineText)
            multiLineText = ""
        }
    }

    func bench() {
        Task {
            await llamaState.bench()
        }
    }

    func clear() {
        Task {
            await llamaState.clear()
        }
    }
    struct DrawerView: View {

        @ObservedObject var llamaState: LlamaState
        @State private var showingHelp = false
        func delete(at offsets: IndexSet) {
            offsets.forEach { offset in
                let model = llamaState.downloadedModels[offset]
                let fileURL = getDocumentsDirectory().appendingPathComponent(model.filename)
                do {
                    try FileManager.default.removeItem(at: fileURL)
                } catch {
                    print("Error deleting file: \(error)")
                }
            }

            // Remove models from downloadedModels array
            llamaState.downloadedModels.remove(atOffsets: offsets)
        }

        func getDocumentsDirectory() -> URL {
            let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            return paths[0]
        }
        var body: some View {
            List {
                Section(
                    header: Text("Load A Local Model"),
                    footer: Text("Loads a .gguf file already on this device from the Files app. The file is used in place and is not downloaded again.")
                ) {
                    LoadCustomButton(llamaState: llamaState)
                }
                Section(header: Text("Download Models From Hugging Face")) {
                    HStack {
                        InputButton(llamaState: llamaState)
                    }
                }
                Section(header: Text("Downloaded Models")) {
                    ForEach(llamaState.downloadedModels) { model in
                        DownloadButton(llamaState: llamaState, modelName: model.name, modelUrl: model.url, filename: model.filename)
                    }
                    .onDelete(perform: delete)
                }
                Section(header: Text("Default Models")) {
                    ForEach(llamaState.undownloadedModels) { model in
                        DownloadButton(llamaState: llamaState, modelName: model.name, modelUrl: model.url, filename: model.filename)
                    }
                }

            }
            .listStyle(GroupedListStyle())
            .navigationBarTitle("Model Settings", displayMode: .inline).toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Help") {
                        showingHelp = true
                    }
                }
            }.sheet(isPresented: $showingHelp) {    // Sheet for help modal
                NavigationView {
                    VStack(alignment: .leading) {
                        VStack(alignment: .leading) {
                            Text("1. Make sure the model is in GGUF Format")
                                    .padding()
                            Text("2. Copy the download link of the quantized model")
                                    .padding()
                            Text("3. Or, if the .gguf file is already on this device, use Load A Local Model to pick it from the Files app")
                                    .padding()
                        }
                        Spacer()
                    }
                    .navigationTitle("Help")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                showingHelp = false
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
