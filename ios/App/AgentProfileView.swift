import CompanionCore
import PhotosUI
import SwiftUI
import UIKit

/// A chat action offered from inside the bot's settings page. Tapping the
/// bot's face opens settings; these three used to be buttons beside it.
enum AgentProfileAction {
    case threads
    case computer
    case browser
    case liveCall
    case open(Chat)
    case newThread
}


/// The paired-safe subset of bot settings. Shared provider keys remain on the
/// computer; the phone sees only the model catalog, configured/not-configured
/// status, and renderer-neutral profile operations.
struct AgentProfileView: View {
    let bot: Bot
    /// Set by the chat that pushes this page: the page pops and the chat
    /// performs the chosen action.
    var onAction: ((AgentProfileAction) -> Void)?
    /// Whether the chat may start a Live call right now.
    var canStartCall = false

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var title: String
    @State private var description: String
    @State private var notifications: Bool
    @State private var crop: AvatarCrop
    @State private var voice: String
    @State private var speakReplies: Bool
    @State private var photo: PhotosPickerItem?
    @State private var prompt = ""
    @State private var showGenerator = false
    @State private var voices: [Voice] = []
    @State private var config: ConfigStatus?
    @State private var engine: VoiceProvider = .elevenlabs
    @State private var hostIsMac = false
    @State private var chatterboxURL = ""
    @State private var chatterboxModel = ""
    @State private var switchingEngine = false
    @State private var savingServer = false
    @State private var serverProblem: String?
    @State private var instances: [Instance] = []
    @State private var modelsLoaded = false
    @State private var selectedInstanceID: String
    @State private var selectedModelID: String
    @State private var selectedEffort: String?
    @State private var savedModel: ModelSelection
    @State private var busy = false
    @StateObject private var player = VoiceNotePlayer()
    @State private var previewTask: Task<Void, Never>?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var baseline: ProfileFormSnapshot
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var showingEditPage = false
    @AppStorage(PrefKey.screenTarget) private var screenTargetRaw = ScreenTarget.browser.rawValue

    init(
        bot: Bot,
        onAction: ((AgentProfileAction) -> Void)? = nil,
        canStartCall: Bool = false
    ) {
        self.bot = bot
        self.onAction = onAction
        self.canStartCall = canStartCall
        _name = State(initialValue: bot.name)
        _title = State(initialValue: bot.title)
        _description = State(initialValue: bot.description)
        _notifications = State(initialValue: bot.notifications)
        _crop = State(initialValue: bot.avatarCrop ?? .mascot)
        _voice = State(initialValue: bot.voice ?? "")
        _speakReplies = State(initialValue: bot.speakReplies == true)
        _selectedInstanceID = State(initialValue: bot.currentTaskModelSelection.instanceId)
        _selectedModelID = State(initialValue: bot.currentTaskModelSelection.model)
        _selectedEffort = State(initialValue: bot.currentTaskModelSelection.effort)
        _savedModel = State(initialValue: bot.currentTaskModelSelection)
        _baseline = State(initialValue: ProfileFormSnapshot(bot: bot))
    }

    private var current: Bot { session.state.bot(bot.id)?.projected(forThread: bot.threadId) ?? bot }
    private var screenTarget: ScreenTarget {
        ScreenTarget(rawValue: screenTargetRaw) ?? .browser
    }
    private var imageGenerationReady: Bool { config?.imageGen?.configured == true }
    private var voiceConfigured: Bool { config?.isTTSConfigured == true }
    private var hasWorkspaceDefaultVoice: Bool { config?.hasWorkspaceDefaultVoice == true }
    private var selectedVoiceCanSpeak: Bool { config?.canSpeak(agentVoice: voice) == true }
    private var selectedInstance: Instance? {
        instances.first { $0.instanceId == selectedInstanceID }
    }
    private var availableInstances: [Instance] { instances.filter(\.snapshot.isAvailable) }
    private var instanceChoices: [Instance] {
        guard let currentInstance = instances.first(where: { $0.instanceId == savedModel.instanceId }),
              !currentInstance.snapshot.isAvailable
        else { return availableInstances }
        return [currentInstance] + availableInstances
    }
    private var selectedModelChoices: [ModelChoice] {
        guard let instance = selectedInstance else {
            return selectedModelID.isEmpty ? [] : [ModelChoice(id: selectedModelID, label: selectedModelID)]
        }
        var seen = Set<String>()
        var choices: [ModelChoice] = []
        let defaultOption = instance.models.options.first { $0.id == instance.models.default }
        if !instance.models.default.isEmpty {
            seen.insert(instance.models.default)
            choices.append(ModelChoice(
                id: instance.models.default,
                label: defaultOption?.label ?? instance.models.default
            ))
        }
        for option in instance.models.options where seen.insert(option.id).inserted {
            choices.append(ModelChoice(id: option.id, label: option.label))
        }
        if !selectedModelID.isEmpty, seen.insert(selectedModelID).inserted {
            choices.append(ModelChoice(id: selectedModelID, label: selectedModelID))
        }
        return choices
    }
    private var effortLevels: [String] {
        var seen = Set<String>()
        return (selectedInstance?.capabilities?.effortLevels ?? []).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }
    private var modelDraft: ModelSelection {
        ModelSelection(instanceId: selectedInstanceID, model: selectedModelID, effort: selectedEffort)
    }
    private var canApplyModel: Bool {
        guard modelsLoaded, current.busy != true,
              let selectedInstance, selectedInstance.snapshot.isAvailable
        else { return false }
        let modelIsOffered = selectedModelID == selectedInstance.models.default
            || selectedInstance.models.options.contains { $0.id == selectedModelID }
        let effortIsOffered = selectedEffort.map(effortLevels.contains) ?? true
        return modelIsOffered && effortIsOffered && modelDraft != savedModel
    }
    /// The fields autosave watches.
    private var hasUnsavedChanges: Bool {
        name != baseline.name
            || title != baseline.title
            || description != baseline.description
            || notifications != baseline.notifications
            || crop != baseline.crop
            || voice != baseline.voice
            || speakReplies != baseline.speakReplies
    }
    /// Which engine's words to use. An unloaded status is ElevenLabs for the
    /// same reason a missing `provider` is: that is the server's own fallback,
    /// and the copy that shipped.
    private var usesSystemVoices: Bool { config?.voiceProvider == .system }
    private var usesChatterbox: Bool { config?.voiceProvider == .chatterbox }
    private var usesFishAudio: Bool { config?.voiceProvider == .fish }

    var body: some View {
        Form {
            Section {
                profileIdentity
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if onAction != nil {
                chatActionsSection
            }
            // Changing the model needs the admin scope on a server; a
            // chat-only phone is not shown either.
            if session.canAdminister {
                modelSection
            }
            voiceSection
            moreSection
            deleteSection
        }
        .scrollContentBackground(.hidden)
        .compactSectionSpacing()
        .background(Color.appGroupedBackground)
        .navigationBarTitleDisplayMode(.inline)
        // Pushed from a chat/roster that hides its bar, so opt this page back
        // into the system back button.
        .toolbar(.visible, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .background(SwipeBackBridge())
        .toolbar { profileToolbar }
        .accessibilityIdentifier("bot-settings-page")
        // Auto-saving: every field writes through as it changes, so the page
        // carries no Save button and a stray back swipe loses nothing.
        .onValueChange(of: name) { _ in autosave() }
        .onValueChange(of: title) { _ in autosave() }
        .onValueChange(of: description) { _ in autosave() }
        .onValueChange(of: notifications) { _ in autosave() }
        .onValueChange(of: crop) { _ in autosave() }
        .onValueChange(of: voice) { _ in autosave() }
        .onValueChange(of: speakReplies) { _ in autosave() }
        .overlay { if busy { ProgressView().controlSize(.large) } }
        .task { await loadProfile() }
        .navigationDestination(isPresented: $showingEditPage) { editPage }
        .confirmationDialog(
            Text("Delete \(current.name)?"),
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete bot", role: .destructive) {
                deleting = true
                Task {
                    let removed = await session.deleteBot(current)
                    deleting = false
                    if removed { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the bot and its threads from your computer. It cannot be undone.")
        }
        .onValueChange(of: photo) { item in
            guard let item else { return }
            Task { await upload(item) }
        }
        .onValueChange(of: engine) { selected in
            Task { await switchEngine(to: selected) }
        }
        .onValueChange(of: player.isPlaying) { playing in
            if !playing { VoiceNoteCenter.shared.release(player) }
        }
        .onDisappear {
            previewTask?.cancel()
            player.pause()
            VoiceNoteCenter.shared.release(player)
            if hasUnsavedChanges { Task { await save() } }
        }
    }

    /// Writes the form back without a Save button: keystrokes coalesce into
    /// one patch, switches and pickers commit the moment they change. Quiet
    /// on purpose — no spinner for a write the reader never started.
    private func autosave() {
        guard hasUnsavedChanges, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    /// Back matches the conversation's own round chevron. Threads is a
    /// native dropdown of this bot's threads instead of a second sheet.
    @ToolbarContentBuilder
    private var profileToolbar: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { backButton }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { backButton }
        }

        if onAction != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(current.visibleTasks, id: \.threadId) { task in
                        Button(task.displayTitle) {
                            if let projected = current.projected(forThread: task.threadId) {
                                onAction?(.open(.bot(projected)))
                            }
                        }
                        .accessibilityIdentifier("thread-\(task.threadId)")
                    }
                    if !current.visibleTasks.isEmpty { Divider() }
                    Button {
                        onAction?(.newThread)
                    } label: {
                        Label("New thread", systemImage: "plus")
                    }
                    Divider()
                    Button {
                        onAction?(.threads)
                    } label: {
                        Label("Manage threads", systemImage: "slider.horizontal.3")
                    }
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 14, weight: .medium))
                }
                .accessibilityLabel("Threads")
            }
        }
    }

    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCapsule()
        .accessibilityLabel("Back")
    }

    private var chatActionsSection: some View {
        Section {
            // The whole panel is the target, not just the button inside it.
            Button {
                onAction?(screenTarget == .browser ? .browser : .computer)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(0.45))

                    Text("View screen")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .frame(width: 190, height: 44)
                        .background(
                            Color.white,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View screen")
            .accessibilityHint("Opens the selected browser or computer")
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            Menu {
                Button {
                    screenTargetRaw = ScreenTarget.browser.rawValue
                } label: {
                    Label("Browser", systemImage: "globe")
                }
                Button {
                    screenTargetRaw = ScreenTarget.computer.rawValue
                } label: {
                    Label("Computer", systemImage: "display")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(screenTarget.title)
                        .font(.headline)
                        .foregroundStyle(Color.secondary)
                        .textCase(nil)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
            }
            .accessibilityLabel("Screen source")
            .accessibilityValue(screenTarget.title)
        }
    }

    private var modelSection: some View {
        Section {
            if !modelsLoaded {
                HStack {
                    Text("Loading models")
                    Spacer()
                    ProgressView()
                }
            } else if instanceChoices.isEmpty {
                Text("No model providers are available")
                    .foregroundStyle(.secondary)
            } else {
                modelPickers
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Provider accounts and API keys stay on your computer. Default sends no reasoning level and lets the provider decide.")
        }
    }

    @ViewBuilder private var modelPickers: some View {
        Picker("Provider", selection: $selectedInstanceID) {
            if !instances.contains(where: { $0.instanceId == selectedInstanceID }) {
                Text("Current provider (unavailable)")
                    .tag(selectedInstanceID)
                    .disabled(true)
            }
            ForEach(instanceChoices) { instance in
                Text(instanceLabel(instance))
                    .tag(instance.instanceId)
                    .disabled(!instance.snapshot.isAvailable)
            }
        }
        .onValueChange(of: selectedInstanceID) { instanceID in
            selectDefaults(for: instanceID)
        }

        Picker("Model", selection: $selectedModelID) {
            ForEach(selectedModelChoices) { option in
                Text(option.label).tag(option.id)
            }
        }
        .disabled(selectedInstance?.snapshot.isAvailable != true)

        if !effortLevels.isEmpty {
            Picker("Reasoning effort", selection: $selectedEffort) {
                Text("Default").tag(String?.none)
                ForEach(effortLevels, id: \.self) { level in
                    Text(effortLabel(level)).tag(Optional(level))
                }
            }
        }

        if current.busy == true {
            Text("Stop this bot before changing its model.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if selectedInstance?.snapshot.isAvailable != true {
            Text("Choose an available provider to change this bot's model.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Button("Apply model") {
            Task { await saveModel() }
        }
        .disabled(busy || !canApplyModel)
    }

    /// The identity card: face, name and role stacked on top of one another
    /// and centred, larger than the roster row this replaced. The card opens
    /// the edit page.
    private var profileIdentity: some View {
        // A button, not a NavigationLink: the form would draw a disclosure
        // chevron beside the centred face, which reads as a stray arrow.
        Button {
            showingEditPage = true
        } label: {
            VStack(spacing: 14) {
                BotAvatarView(bot: current, size: 112, state: .happy, animated: true)
                Text(current.name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !current.title.isEmpty {
                    Text(current.title)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(current.name) details")
        .accessibilityHint("Change the name, title and photo")
        .accessibilityIdentifier("edit-bot-profile")
    }

    private var appearanceSection: some View {
        Section {
            HStack {
                Spacer()
                BotAvatarView(bot: current, size: 96, state: .happy, animated: true)
                Spacer()
            }
            .listRowBackground(Color.clear)

            Picker("Shape", selection: $crop) {
                ForEach(AvatarCrop.allCases, id: \.self) { shape in
                    Text(shape.label).tag(shape)
                }
            }
            .pickerStyle(.segmented)

            PhotosPicker(selection: $photo, matching: .images) {
                Text("Upload an image")
            }
            .disabled(busy)

            if current.avatarUrl != nil {
                Button("Use the mascot instead", role: .destructive) {
                    Task { await clearImage() }
                }
                .disabled(busy)
            }

            if session.canAdminister {
                DisclosureGroup(isExpanded: $showGenerator) {
                    TextField("Describe the image you want", text: $prompt, axis: .vertical)
                        .lineLimit(2...5)
                    Button("Generate on your computer") {
                        Task { await generateImage() }
                    }
                    .disabled(busy || !imageGenerationReady || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text(imageGenerationReady
                         ? "Uses the shared image provider configured on your computer. No key is sent to this phone."
                         : "Set up the shared image provider in OpenMausBot on your computer to generate one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Generate an image")
                }
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("PNG, JPEG, GIF, or WebP, up to 10 MB. The image stays on your paired computer.")
        }
    }

    private var editPage: some View {
        Form {
            aboutSection
            alertsSection
            appearanceSection
        }
        .scrollContentBackground(.hidden)
        .background(Color.appGroupedBackground)
        .navigationTitle("Edit bot")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Name") {
                TextField("Pepper", text: $name)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
            }
            LabeledContent("Title") {
                TextField("Personal assistant", text: $title)
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Description")
                    .foregroundStyle(.secondary)
                TextField("What this agent does", text: $description, axis: .vertical)
                    .lineLimit(2...6)
            }
        } header: {
            Text("About")
        } footer: {
            Text("Name and title appear in the roster. The description tells the bot how to introduce itself.")
        }
    }

    private var alertsSection: some View {
        Section {
            Toggle("Notifications", isOn: $notifications)
        } header: {
            Text("Alerts")
        } footer: {
            Text("Announcements for this bot on this phone.")
        }
    }

    private var moreSection: some View {
        Section("Details") {
            NavigationLink {
                BotOverviewView(bot: current)
            } label: {
                Text("What this bot does")
            }
            NavigationLink {
                BotActivityView(bot: current)
            } label: {
                Text("Activity")
            }
            NavigationLink {
                TeamMemoryView(section: current.section ?? "")
            } label: {
                Text("Team memory")
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                if deleting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Delete bot")
                        .foregroundStyle(Color.red)
                }
            }
            .disabled(deleting)
        } footer: {
            Text("Deleting this bot also removes its threads from your computer.")
        }
    }

    private var voiceSection: some View {
        Section {
            Picker("Voice engine", selection: $engine) {
                Text("ElevenLabs").tag(VoiceProvider.elevenlabs)
                Text("Fish Audio").tag(VoiceProvider.fish)
                Text("Built-in Mac voices")
                    .tag(VoiceProvider.system)
                    .disabled(!hostIsMac)
                Text("Chatterbox (local)").tag(VoiceProvider.chatterbox)
            }
            .disabled(switchingEngine)

            if usesChatterbox {
                chatterboxFields
            }

            if voiceConfigured {
                voiceControls
            } else if usesSystemVoices {
                Text("Built-in Mac voices are unavailable")
                    .foregroundStyle(.secondary)
            } else if !usesChatterbox {
                Text(usesFishAudio ? "Fish Audio is not configured" : "ElevenLabs is not configured")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Voice")
        } footer: {
            voiceFooter
        }
    }

    @ViewBuilder private var chatterboxFields: some View {
        TextField(
            "Chatterbox server address",
            text: $chatterboxURL,
            prompt: Text("http://127.0.0.1:4123")
        )
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        TextField(
            "Chatterbox model",
            text: $chatterboxModel,
            prompt: Text("chatterbox-turbo")
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        Button {
            Task { await saveChatterboxServer() }
        } label: {
            HStack {
                Text("Save server")
                if savingServer { Spacer(); ProgressView() }
            }
        }
        .disabled(savingServer || chatterboxURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if let serverProblem {
            Text(serverProblem)
                .foregroundStyle(Color.orange)
        }
    }

    @ViewBuilder private var voiceControls: some View {
        Picker("Voice", selection: $voice) {
            if hasWorkspaceDefaultVoice {
                Text("Workspace default").tag("")
            } else {
                Text("Choose an agent voice").tag("").disabled(true)
            }
            if !voice.isEmpty, !voices.contains(where: { $0.id == voice }) {
                Text("Current agent voice").tag(voice)
            }
            ForEach(voices) { option in
                VStack(alignment: .leading) {
                    Text(option.label)
                    if let detail = option.description { Text(detail) }
                }
                .tag(option.id)
            }
        }
        Toggle("Speak replies", isOn: $speakReplies)
            .disabled(!selectedVoiceCanSpeak)
        Button("Preview voice") {
            previewTask = Task { await previewVoice() }
        }
        .disabled(busy || !selectedVoiceCanSpeak)

        if !hasWorkspaceDefaultVoice, voice.isEmpty {
            Text("Pick a voice for this agent before enabling speech.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var voiceFooter: some View {
        if !voiceConfigured {
            // Under the built-in engine "not configured" is not a
            // missing credential — there is none — so the remedy
            // cannot be a key. `providerConfigured` in
            // `server/tts/index.ts` is reporting that this
            // computer has no built-in voices to speak with.
            if usesSystemVoices {
                Text("Built-in Mac voices need no key, and this computer has none available. Switch the voice engine above to ElevenLabs to keep using voice.")
            } else if usesChatterbox {
                Text("Any OpenAI-compatible server running Chatterbox works, no key needed. Save its address and model id above.")
            } else if usesFishAudio {
                Text("Add the shared Fish Audio key in OpenMausBot on your computer. The key is never returned to iOS.")
            } else {
                Text("Add the shared ElevenLabs key in this agent's profile on the computer. The key is never returned to iOS.")
            }
        } else if !hasWorkspaceDefaultVoice {
            if usesSystemVoices {
                Text("No workspace default voice is selected. Choose an agent-specific voice above; synthesis still uses the built-in Mac voices on your computer.")
            } else if usesChatterbox {
                Text("No workspace default voice is selected. Choose an agent-specific voice above; synthesis still uses the Chatterbox server on your computer.")
            } else if usesFishAudio {
                Text("No workspace default voice is selected. Choose an agent-specific voice above; synthesis still uses the shared Fish Audio key on your computer.")
            } else {
                Text("No workspace default voice is selected. Choose an agent-specific voice above; synthesis still uses the shared ElevenLabs key on your computer.")
            }
        } else {
            Text("The voice choice belongs to this agent. Workspace default uses the shared voice selected on your computer.")
        }
    }

    private func loadProfile() async {
        async let status = session.configStatus()
        async let options = session.voiceOptions()
        async let catalog = loadModelCatalog()
        async let environment = session.serverEnvironment()
        let (loadedConfig, loadedVoices, loadedInstances) = await (status, options, catalog)
        config = loadedConfig
        engine = loadedConfig?.voiceProvider ?? .elevenlabs
        chatterboxURL = loadedConfig?.tts?.baseUrl ?? ""
        chatterboxModel = loadedConfig?.tts?.model ?? ""
        hostIsMac = (await environment)?.platform == "darwin"
        voices = loadedVoices
        instances = loadedInstances
        modelsLoaded = true
        if let loadedConfig, !loadedConfig.canSpeak(agentVoice: voice) {
            speakReplies = false
        }
    }

    /// Switch the workspace's voice engine. The engine is a setting, not a
    /// secret, so it rides the ordinary config write; the voice list reloads
    /// because every engine offers different voices. A failed switch snaps
    /// the picker back to whatever the server still reports.
    private func switchEngine(to selected: VoiceProvider) async {
        guard selected != (config?.voiceProvider ?? .elevenlabs) else { return }
        switchingEngine = true
        defer { switchingEngine = false }
        if let status = await session.setVoiceProvider(selected) {
            let reset = AgentProfileVoiceState(
                voice: voice,
                speakReplies: speakReplies,
                baselineVoice: baseline.voice
            ).afterProviderSwitch(to: status)
            voice = reset.voice
            speakReplies = reset.speakReplies
            baseline.voice = reset.baselineVoice
            config = status
            engine = status.voiceProvider
            // Do not render the previous provider's catalog while the new
            // one loads. Its identifiers are invalid under this provider.
            voices = []
            voices = await session.voiceOptions()
        } else {
            engine = config?.voiceProvider ?? .elevenlabs
        }
    }

    private func saveChatterboxServer() async {
        let address = chatterboxURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.hasPrefix("http://") || address.hasPrefix("https://") else {
            serverProblem = String(localized: "The server address must start with http:// or https://.")
            return
        }
        serverProblem = nil
        savingServer = true
        defer { savingServer = false }
        // Both fields commit together: an address without its model id (or
        // the reverse) is half a setting, exactly as on the desktop.
        if let status = await session.saveChatterboxServer(
            baseURL: address,
            model: chatterboxModel.trimmingCharacters(in: .whitespacesAndNewlines)
        ) {
            config = status
            voices = await session.voiceOptions()
        }
    }

    private func profilePatch() -> BotProfilePatch {
        let savedSpeakReplies = config.map { $0.canSpeak(agentVoice: voice) && speakReplies } ?? speakReplies
        return BotProfilePatch(
            // The shared server contract owns the 100/200/4000 limits. Do not
            // silently apply narrower iOS-only limits to a user's profile.
            name: name == baseline.name ? nil : name.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title == baseline.title ? nil : title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description == baseline.description
                ? nil : description.trimmingCharacters(in: .whitespacesAndNewlines),
            notifications: notifications == baseline.notifications ? nil : notifications,
            avatarCrop: crop == baseline.crop ? nil : crop,
            // Empty is the server's explicit "use workspace default" value;
            // nil would mean the voice field is not part of this patch.
            voice: voice == baseline.voice ? nil : voice,
            speakReplies: savedSpeakReplies == baseline.speakReplies ? nil : savedSpeakReplies
        )
    }

    private func save() async {
        guard hasUnsavedChanges, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let updated = await session.updateProfile(profilePatch(), for: current) {
            synchronizeForm(with: updated)
        }
    }

    /// The provider list is admin-only on a server: asking without the
    /// scope would only put a 403 on screen for a picker that is not shown.
    private func loadModelCatalog() async -> [Instance] {
        session.canAdminister ? await session.modelInstances() : []
    }

    private func saveModel() async {
        guard canApplyModel else { return }
        busy = true
        defer { busy = false }
        if let updated = await session.updateModel(modelDraft, for: current) {
            let model = updated.projected(forThread: bot.threadId)?.currentTaskModelSelection ?? modelDraft
            selectedInstanceID = model.instanceId
            selectedModelID = model.model
            selectedEffort = model.effort
            savedModel = model
        }
    }

    private func selectDefaults(for instanceID: String) {
        guard let instance = instances.first(where: { $0.instanceId == instanceID }) else { return }
        if instanceID == savedModel.instanceId {
            selectedModelID = savedModel.model
            let supported = instance.capabilities?.effortLevels ?? []
            selectedEffort = savedModel.effort.flatMap { supported.contains($0) ? $0 : nil }
        } else {
            selectedModelID = instance.models.default
            selectedEffort = nil
        }
    }

    private func instanceLabel(_ instance: Instance) -> String {
        let base = instance.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = base.flatMap { $0.isEmpty ? nil : $0 } ?? instance.instanceId
        return instance.snapshot.isAvailable ? name : "\(name) (Unavailable)"
    }

    private func effortLabel(_ effort: String) -> String {
        switch effort.lowercased() {
        case "xhigh": "X-High"
        default: effort.capitalized
        }
    }

    private func clearImage() async {
        busy = true
        defer { busy = false }
        if let updated = await session.updateProfile(
            BotProfilePatch(avatarUrl: .clear, avatarCrop: .mascot),
            for: current
        ) {
            crop = updated.avatarCrop ?? .mascot
            baseline.crop = crop
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        busy = true
        defer { busy = false; photo = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let mime = Self.imageMIME(data)
        else {
            session.actionError = "Choose a PNG, JPEG, GIF, or WebP image."
            return
        }
        if data.count > 10 * 1_024 * 1_024 {
            session.actionError = "That image is larger than 10 MB."
            return
        }
        let intendedCrop = crop == .mascot ? AvatarCrop.circle : crop
        if let updated = await session.uploadAvatar(data, mime: mime, for: current, crop: intendedCrop) {
            crop = updated.avatarCrop ?? intendedCrop
            baseline.crop = crop
        }
    }

    private func generateImage() async {
        busy = true
        defer { busy = false }
        // What the selector said when the request went out. The desktop
        // compares the same way (`latestCrop === cropAtStart` in
        // `src/components/BotProfileAvatarCard.tsx`) so a selector moved
        // mid-flight still wins over the server's pick.
        let cropAtStart = crop
        guard let generated = await session.generateAvatar(
            prompt: String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)),
            for: current
        ) else { return }

        // `AvatarCrop.afterGenerating` is the shared decision: the server's
        // pick unless the selector moved while the request was in flight, in
        // which case that newer explicit choice wins.
        let resolved = AvatarCrop.afterGenerating(
            cropAtStart: cropAtStart,
            latestCrop: crop,
            serverCrop: generated.avatarCrop
        )

        guard crop != cropAtStart else {
            crop = resolved
            baseline.crop = crop
            return
        }

        // The user moved the selector while the image was generating: an
        // explicit choice made after the request, so persist it against the
        // returned attachment rather than leaving UI and server out of sync.
        if let updated = await session.updateProfile(BotProfilePatch(avatarCrop: resolved), for: generated) {
            crop = updated.avatarCrop ?? resolved
        } else {
            // Generation itself succeeded. Reflect its authoritative result
            // rather than claiming the requested crop was persisted. A `nil`
            // crop here matches `afterGenerating`'s own fallback: `.circle`,
            // not `.mascot`, which would throw away the picture just
            // generated.
            crop = generated.avatarCrop ?? .circle
        }
        baseline.crop = crop
    }

    private func previewVoice() async {
        guard selectedVoiceCanSpeak else {
            session.actionError = "Pick an agent voice or configure a workspace default on your computer first."
            return
        }
        // The preview reconfigures and later deactivates the shared audio
        // session, which would cut a Live call's audio. Same arbiter as
        // voice notes: refused while an input owner holds the session.
        guard VoiceNoteCenter.shared.playbackAllowed else {
            session.actionError = String(localized: "Voice previews are paused during a Live call.")
            return
        }
        busy = true
        defer { busy = false }
        guard let data = await session.previewVoice(voice, for: current), !Task.isCancelled else { return }
        // A call may have taken ownership while the generated clip loaded.
        guard VoiceNoteCenter.shared.playbackAllowed else {
            session.actionError = String(localized: "Voice previews are paused during a Live call.")
            return
        }
        do {
            player.reset()
            try player.load(data)
            VoiceNoteCenter.shared.claim(player)
            player.play(mode: .spokenAudio)
            guard player.isPlaying else {
                VoiceNoteCenter.shared.release(player)
                session.actionError = "The generated audio could not be played."
                return
            }
        } catch {
            player.reset()
            VoiceNoteCenter.shared.release(player)
            session.actionError = "The generated audio could not be played."
        }
    }

    private static func imageMIME(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xff, 0xd8, 0xff]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.count >= 12,
           String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { return "image/webp" }
        return nil
    }

    private func synchronizeForm(with bot: Bot) {
        name = bot.name
        title = bot.title
        description = bot.description
        notifications = bot.notifications
        crop = bot.avatarCrop ?? .mascot
        voice = bot.voice ?? ""
        speakReplies = bot.speakReplies == true
        baseline = ProfileFormSnapshot(bot: bot)
    }
}

private struct ModelChoice: Identifiable {
    let id: String
    let label: String
}

private struct ProfileFormSnapshot {
    var name: String
    var title: String
    var description: String
    var notifications: Bool
    var crop: AvatarCrop
    var voice: String
    var speakReplies: Bool

    init(bot: Bot) {
        name = bot.name
        title = bot.title
        description = bot.description
        notifications = bot.notifications
        crop = bot.avatarCrop ?? .mascot
        voice = bot.voice ?? ""
        speakReplies = bot.speakReplies == true
    }
}

private extension AvatarCrop {
    var label: LocalizedStringKey {
        switch self {
        case .mascot: "Mascot"
        case .circle: "Circle"
        case .rounded: "Rounded"
        case .square: "Square"
        }
    }
}

private extension View {
    /// Tighter gaps between form sections on iOS 17+; iOS 16 keeps the
    /// system spacing this screen shipped with.
    @ViewBuilder
    func compactSectionSpacing() -> some View {
        if #available(iOS 17.0, *) {
            listSectionSpacing(.compact)
                // The form's own top inset is what felt like padding above
                // the identity row; trim it without pulling the row out of
                // its cell (negative row insets clip the avatar).
                .contentMargins(.top, 4, for: .scrollContent)
        } else {
            self
        }
    }
}
