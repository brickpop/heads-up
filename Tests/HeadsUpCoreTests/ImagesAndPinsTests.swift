import Foundation
import Testing

@testable import HeadsUpCore

/// A whole app over fakes, with its data in a real folder, so pins go to a real SQLite file.
/// `relaunch()` starts a new app on the same folder, as after quitting.
@MainActor
private final class PinHarness {
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let provider = FakeLLMProvider()
    let pasteboard = FakePasteboard()
    let panels = FakeOpenPanels()
    let images = FakeImageProcessor()
    let folder: URL
    let endpoints: [Endpoint]
    private(set) var model: AppModel!
    var chat: ChatStore { model.chat }
    var hud: HUDStore { model.hud }

    static let vision = Endpoint(
        id: "gpt", name: "GPT-4o mini", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini", images: true)
    static let textOnly = Endpoint(id: "llama", name: "Llama 3.1 8B", baseURL: "http://localhost:11434/v1")

    /// Set, pins go here instead of the SQLite file.
    let pinStore: PinnedChats?

    init(endpoints: [Endpoint] = [vision], pinStore: PinnedChats? = nil) {
        self.pinStore = pinStore
        scheduler = ManualScheduler(clock: clock)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("headsup-pins-\(UUID().uuidString)")
        self.endpoints = endpoints
        relaunch()
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func relaunch() {
        var settings = Settings()
        settings.general.welcomeDone = true
        settings.endpoints = endpoints
        settings.defaultEndpointID = endpoints.first?.id
        var ports = AppModel.Ports(
            clock: clock, scheduler: scheduler, hotkeys: FakeHotkeyRegistrar(), appearance: FixedAppearance(),
            files: FakeFileRevealer(), loginItem: FakeLoginItem(), systemSettings: FakeSystemSettingsLinks(),
            notifier: FakeNotifier(), powerAssertions: FakePowerAssertions(), powerSource: FakePowerSource(),
            serviceLauncher: FakeServiceLauncher(), portProbe: FakePortProbe(), openPanels: panels,
            imageProcessor: images, terminalLauncher: FakeTerminalLauncher(), secrets: MemorySecretStore(),
            httpClient: FakeHTTPClient(), linkOpener: FakeLinkOpener(), pasteboard: pasteboard,
            llmProvider: provider, dataFolder: folder)
        ports.pinnedChats = pinStore
        model = AppModel(ports: ports, settings: settings)
        model.hud.attach(window: FakeHUDWindow())
        model.launch()
        model.hud.selectTab(.chat)
        model.hud.didBecomeKey()
    }

    var databaseFile: URL { folder.appendingPathComponent(Database.fileName) }

    /// What a fresh connection reads from the file: what survives a quit.
    func stored() throws -> [PinnedChat] {
        let store = SQLitePinnedChats(folder: folder)
        return try store.list().compactMap { try store.load($0.id) }
    }

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() { await Task.yield() }
    }

    /// Attaches, and waits for the image port to answer.
    func attach(_ inputs: [ImageInput]) async {
        await chat.attach(inputs, offered: inputs.count)?.value
    }

    /// Types `text` and presses Enter, then waits for the request.
    func send(_ text: String) async {
        let before = provider.requests.count
        hud.setInput(text)
        hud.submit()
        await waitUntil { provider.requests.count > before || !chat.isBusy }
    }

    func reply(_ text: String) async {
        provider.say(.text(text))
        provider.finish()
        await waitUntil { !chat.isBusy }
    }

    /// The user parts of the last request, in order.
    func lastUserParts() -> [[LLMMessage.Part]] {
        (provider.requests.last ?? []).filter { $0.role == .user }.map(\.parts)
    }
}

private func image(_ name: String? = "Screenshot 1.png", _ bytes: String = "png-bytes") -> ImageInput {
    ImageInput(data: Data(bytes.utf8), name: name)
}

// MARK: - Attachments (F17's core rules; UX part 1, §6–7; addendum 4)

@MainActor
@Suite(.serialized) struct AttachmentTests {
    @Test func imagesGoThroughThePortAndShowAsThumbnailsInOrder() async {
        let h = PinHarness()
        await h.attach([image("a.png", "one"), image(nil, "two")])
        #expect(h.images.processed.map(\.data) == [Data("one".utf8), Data("two".utf8)])
        #expect(h.chat.attachments.map(\.name) == ["a.png", "Pasted image"])
        #expect(h.chat.attachments.first?.accessibilityLabel == "Image a.png")
        #expect(h.chat.attachments.first?.removeLabel == "Remove image a.png")
        #expect(h.chat.attachments.allSatisfy { !$0.hasWarning && $0.preview == Data("preview".utf8) })
        #expect(h.chat.attachmentNotice == nil)
    }

    @Test func aSixthImageIsNotAddedAndTheNoticeSaysSo() async throws {
        let h = PinHarness()
        await h.attach((1...7).map { image("\($0).png") })
        #expect(h.chat.attachments.count == 5)
        #expect(h.images.processed.count == 5)
        let notice = try #require(h.chat.attachmentNotice)
        #expect(notice.text == "You can send up to 5 images at a time. 2 images weren't added.")
        #expect(notice.dismiss != nil)
        // Removing an image clears it.
        h.chat.removeAttachment(h.chat.attachments[0].id)
        #expect(h.chat.attachmentNotice == nil)
        await h.attach([image(), image()])
        #expect(h.chat.attachmentNotice?.text == "You can send up to 5 images at a time. 1 image wasn't added.")
        h.chat.dismissAttachmentNotice()
        #expect(h.chat.attachmentNotice == nil)
    }

    @Test func somethingThatIsntAnImageIsSkipped() async {
        let h = PinHarness()
        await h.attach([image("doc.pdf", "bad: a PDF"), image("ok.png")])
        #expect(h.chat.attachments.map(\.name) == ["ok.png"])
        #expect(h.chat.attachmentNotice?.text == "Only images can be attached")
    }

    @Test func aNameCantHideDirectionOrZeroWidthCharacters() async {
        let h = PinHarness()
        await h.attach([image("photo\u{202E}gnp.exe\u{200B}.png")])
        #expect(h.chat.attachments.first?.name == "photognp.exe.png")
    }

    @Test func theDropZoneSaysWhatADropWouldDo() async {
        let h = PinHarness()
        #expect(h.chat.dropZone(images: 2, others: 0) == DropZone(text: "Drop to attach", style: .accept))
        #expect(
            h.chat.dropZone(images: 7, others: 0)
                == DropZone(text: "Drop to attach 5 of 7 images (up to 5 per message)", style: .accept))
        #expect(h.chat.dropZone(images: 0, others: 2) == DropZone(text: "Only images can be attached", style: .refuse))
        #expect(
            h.chat.dropZone(images: 1, others: 1) == DropZone(text: "Only the images will be attached", style: .accept))
        await h.attach((1...5).map { image("\($0).png") })
        #expect(
            h.chat.dropZone(images: 1, others: 0)
                == DropZone(text: "You can send up to 5 images at a time.", style: .refuse))
    }

    @Test func backspaceRemovesTheLastImageOnlyWhenThereIsOne() async {
        let h = PinHarness()
        #expect(!h.chat.removeLastAttachment())
        await h.attach([image("a.png"), image("b.png")])
        #expect(h.chat.removeLastAttachment())
        #expect(h.chat.attachments.map(\.name) == ["a.png"])
    }

    @Test func attachOpensThePanelAndKeepsTheHUDOpen() async {
        let h = PinHarness()
        h.panels.images = [image("picked.png")]
        let task = h.model.pickImages()
        #expect(h.hud.modalDepth == 1)
        await task.value
        #expect(h.hud.modalDepth == 0)
        #expect(h.panels.imageLimits == [5])
        #expect(h.chat.attachments.map(\.name) == ["picked.png"])
    }

    @Test func pasteAttachesOnlyWhenTheClipboardHasImages() async {
        let h = PinHarness()
        #expect(!h.model.pasteImages())
        h.pasteboard.images = [image(nil)]
        #expect(h.model.pasteImages())
        await h.waitUntil { !h.chat.attachments.isEmpty }
        #expect(h.chat.attachments.map(\.name) == ["Pasted image"])
    }

    @Test func theHeaderButtonsShowOnChatOnly() {
        let h = PinHarness()
        #expect(h.model.chatButtons?.attach.accessibilityLabel == "Attach image")
        #expect(h.model.chatButtons?.pinned.isOn == false)
        h.hud.togglePinnedList()
        #expect(h.model.chatButtons?.pinned.isOn == true)
        h.hud.selectTab(.focus)
        #expect(h.model.chatButtons == nil)
    }
}

// MARK: - The vision notice (UX part 1, §6)

@MainActor
@Suite(.serialized) struct VisionNoticeTests {
    @Test func aModelThatCantSeeImagesGetsTheNoticeAndEnterWaits() async throws {
        let h = PinHarness(endpoints: [PinHarness.textOnly, PinHarness.vision])
        await h.attach([image()])
        let notice = try #require(h.chat.attachmentNotice)
        #expect(notice.text == "Llama 3.1 8B can't see images.")
        #expect(
            notice.actions == [
                NoticeAction(kind: .switchModel("gpt"), title: "Switch to GPT-4o mini"),
                NoticeAction(kind: .removeImages, title: "Remove image"),
            ])
        #expect(notice.dismiss == nil)
        #expect(h.chat.attachments.allSatisfy { $0.hasWarning })

        // Enter sends nothing, and the text stays.
        h.hud.setInput("what's wrong here?")
        h.hud.submit()
        #expect(h.provider.requests.isEmpty)
        #expect(h.hud.input == "what's wrong here?")

        h.model.performAttachmentNotice(.switchModel("gpt"))
        #expect(h.chat.attachmentNotice == nil)
        #expect(h.chat.attachments.allSatisfy { !$0.hasWarning })
        await h.send("what's wrong here?")
        #expect(h.provider.requests.count == 1)
    }

    @Test func removeImageClearsTheNotice() async {
        let h = PinHarness(endpoints: [PinHarness.textOnly, PinHarness.vision])
        await h.attach([image()])
        h.model.performAttachmentNotice(.removeImages)
        #expect(h.chat.attachments.isEmpty && h.chat.attachmentNotice == nil)
    }

    @Test func noModelThatSeesImagesOffersSettings() async {
        let h = PinHarness(endpoints: [PinHarness.textOnly])
        await h.attach([image(), image()])
        #expect(h.chat.attachmentNotice?.text == "None of your models can see images.")
        #expect(h.chat.attachmentNotice?.actions.map(\.kind) == [.openSettings])
        h.model.performAttachmentNotice(.openSettings)
        #expect(h.hud.tab == .settings && h.hud.settingsSection == .models)
    }

    @Test func noModelAtAllSaysAddAModel() async {
        let h = PinHarness(endpoints: [])
        await h.attach([image()])
        #expect(h.chat.attachmentNotice?.text == "Add a model to send images.")
    }

    @Test func theVisionNoticeWinsOverTheLimitNotice() async {
        let h = PinHarness(endpoints: [PinHarness.textOnly, PinHarness.vision])
        await h.attach((1...6).map { image("\($0).png") })
        #expect(h.chat.attachmentNotice?.text == "Llama 3.1 8B can't see images.")
    }
}

// MARK: - Sending images (ADR-001 §8.2)

@MainActor
@Suite(.serialized) struct SendingImagesTests {
    @Test func theNewestMessageSendsItsImagesAndOlderOnesAreOmitted() async throws {
        let h = PinHarness()
        await h.attach([image("a.png", "first")])
        await h.send("what's this?")
        let url = "data:image/jpeg;base64,\(Data("first".utf8).base64EncodedString())"
        #expect(h.lastUserParts() == [[.text("what's this?"), .imageDataURL(url)]])
        #expect(h.chat.attachments.isEmpty)
        await h.reply("A cat.")

        await h.send("and its name?")
        #expect(h.lastUserParts() == [[.text("what's this?\n[image omitted]")], [.text("and its name?")]])
    }

    @Test func aMessageCanBeImagesOnly() async throws {
        let h = PinHarness()
        await h.attach([image("a.png", "one"), image("b.png", "two")])
        await h.send("")
        let parts = try #require(h.lastUserParts().last)
        #expect(parts.count == 2)
        #expect(parts.allSatisfy { if case .imageDataURL = $0 { true } else { false } })
        guard case .user(_, let text, let images, let label)? = h.chat.screen.messages.first else {
            Issue.record("expected the user's message")
            return
        }
        #expect(text.isEmpty)
        #expect(images.map(\.name) == ["Image 1 of 2", "Image 2 of 2"])
        #expect(images.allSatisfy { $0.preview == Data("preview".utf8) && !$0.hasWarning })
        #expect(label == "You: 2 images")
    }

    @Test func enterWithNothingTypedAndNoImagesSendsNothing() async {
        let h = PinHarness()
        h.hud.setInput("")
        h.hud.submit()
        #expect(h.provider.requests.isEmpty && !h.chat.hasMessages)
    }

    @Test func newChatForgetsTheImagesWaiting() async {
        let h = PinHarness()
        await h.attach([image()])
        h.chat.newChat()
        #expect(h.chat.attachments.isEmpty)
    }
}

// MARK: - Pinned chats (ADR-001 §6.3, F12)

@MainActor
@Suite(.serialized) struct PinnedChatTests {
    @Test func aLongFirstMessageIsCutTo47CharactersAndAnEllipsis() {
        let text = String(repeating: "abcdefghij", count: 6)
        let title = PinnedTitle.make([ChatMessage(role: .user, text: text)])
        #expect(title == String(text.prefix(47)) + "…")
        #expect(title.unicodeScalars.count == 48)
    }

    @Test func theTitleIsOneCleanLineAndImagesOnlyHaveTheirOwn() {
        #expect(PinnedTitle.make([ChatMessage(role: .user, text: "  Weekly\n\nplan\u{202E} ")]) == "Weekly plan")
        #expect(PinnedTitle.make([ChatMessage(role: .user, text: "", imageIDs: ["x"])]) == "Image conversation")
    }

    @Test func emojiTitlesStillFitTheDatabaseCheck() async throws {
        // 👩‍👩‍👧‍👦 is one character but seven code points; SQLite's length() counts code points.
        let h = PinHarness()
        await h.send(String(repeating: "👩‍👩‍👧‍👦", count: 20))
        await h.reply("Hi!")
        h.chat.togglePin()
        #expect(h.chat.isPinned)
        let stored = try #require(try h.stored().first)
        #expect(stored.title.unicodeScalars.count <= 48)
        #expect(stored.title.hasSuffix("…"))
    }

    @Test func pinningNeedsAMessageFromTheUser() throws {
        let h = PinHarness()
        h.chat.togglePin()
        #expect(!h.chat.isPinned)
        // A fresh install writes nothing.
        #expect(!FileManager.default.fileExists(atPath: h.databaseFile.path))
    }

    @Test func pinQuitRelaunchAndFollowUp() async throws {
        let h = PinHarness()
        await h.attach([image("cat.png", "cat-bytes")])
        await h.send("What's in this picture?")
        await h.reply("A **cat**.")
        #expect(h.hud.handleShortcut(Shortcut(keyCode: KeyCode.p, modifiers: .command, key: "P")))
        #expect(h.chat.isPinned)
        #expect(h.hud.footerLeft == .toast("Chat pinned"))
        #expect(h.chat.screen.toolbar.saved == .pinned)
        #expect(h.chat.screen.toolbar.saveLabel == "Pinned · kept until you unpin it")
        #expect(h.chat.screen.toolbar.pin == .init(title: "Pinned", isOn: true, help: "Unpin this chat (⌘P)"))
        #expect(h.chat.screen.toolbar.pinnedList == "Pinned · 1")

        h.relaunch()
        #expect(!h.chat.hasMessages)
        #expect(h.model.pins.count == 1)
        #expect(
            h.model.menu.entries.contains {
                if case .row(let row) = $0 { row.action == .pinned && row.value == "1" } else { false }
            })
        let row = try #require(h.model.pins.screen.rows.first)
        #expect(row.title == "What's in this picture?")
        #expect(row.meta == "2 messages · GPT-4o mini")
        #expect(row.date == "Just now")
        #expect(!row.isLoaded)

        h.hud.togglePinnedList()
        #expect(h.model.body == .pinnedList)
        h.hud.setInput("draft")
        await h.model.loadPinned(row.id)?.value
        #expect(h.model.body == .conversation)
        #expect(h.hud.input.isEmpty)
        #expect(h.chat.isPinned && h.model.pins.screen.rows.first?.isLoaded == true)
        guard case .user(_, _, let images, _)? = h.chat.screen.messages.first else {
            Issue.record("expected the user's message")
            return
        }
        #expect(images.count == 1 && images.first?.preview != nil)

        // A follow-up updates the stored copy, and the older image is omitted from what's sent.
        await h.send("What colour is it?")
        await h.reply("Orange.")
        #expect(h.lastUserParts().first == [.text("What's in this picture?\n[image omitted]")])
        let stored = try #require(try h.stored().first)
        #expect(
            stored.messages.map(\.text) == ["What's in this picture?", "A **cat**.", "What colour is it?", "Orange."])
        #expect(stored.images.values.map(\.data) == [Data("cat-bytes".utf8)])
    }

    @Test func unpinningLeavesNothingInTheDatabaseOrTheWAL() async throws {
        let h = PinHarness()
        let marker = "MARKER-\(UUID().uuidString)"
        await h.attach([image("m.png", "IMAGE-\(marker)")])
        await h.send("remember \(marker)")
        await h.reply("Noted: \(marker)")
        h.chat.togglePin()
        let wal = URL(fileURLWithPath: h.databaseFile.path + "-wal")
        let before = try Data(contentsOf: h.databaseFile) + ((try? Data(contentsOf: wal)) ?? Data())
        #expect(before.range(of: Data(marker.utf8)) != nil)

        h.chat.togglePin()
        #expect(!h.chat.isPinned)
        #expect(h.hud.footerLeft == .toast("Unpinned. This chat is ephemeral again"))
        // The chat stays on screen, not kept.
        #expect(h.chat.hasMessages && h.chat.screen.toolbar.saved == .ephemeral)
        let after = try Data(contentsOf: h.databaseFile) + ((try? Data(contentsOf: wal)) ?? Data())
        #expect(after.range(of: Data(marker.utf8)) == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: h.databaseFile.path)
        #expect((attributes[.posixPermissions] as! NSNumber).intValue & 0o777 == 0o600)
    }

    @Test func whileAReplyStreamsTheCopyIsWrittenAtMostEvery500ms() async throws {
        let h = PinHarness()
        await h.send("Count")
        await h.reply("Ready.")
        h.chat.togglePin()
        await h.send("Go")
        h.provider.say(.text("one"))
        await h.waitUntil { h.chat.phase == .streaming }
        h.scheduler.advance(by: 0.04)
        // The first flush after a save waits: the copy has no reply yet.
        #expect(try h.stored().first?.messages.count == 3)
        h.scheduler.advance(by: 0.5)
        #expect(try h.stored().first?.messages.last?.text == "one")
        #expect(try h.stored().first?.messages.last?.state == .streaming)

        // Killed here: the copy loads with the reply stopped.
        h.relaunch()
        let id = try #require(h.model.pins.screen.rows.first?.id)
        h.model.loadPinned(id)
        guard case .assistant(let reply)? = h.chat.screen.messages.last else {
            Issue.record("expected the reply")
            return
        }
        #expect(reply.stopped == "Stopped" && !reply.isStreaming)
    }

    @Test func loadingAPinStopsARunningReplyFirst() async throws {
        let h = PinHarness()
        await h.send("Plan my week")
        await h.reply("Sure.")
        h.chat.togglePin()
        let id = try #require(h.model.pins.screen.rows.first?.id)
        h.chat.newChat()
        await h.send("Something else")
        h.provider.say(.text("partial"))
        #expect(h.chat.isBusy)
        h.model.loadPinned(id)
        #expect(!h.chat.isBusy)
        #expect(h.chat.screen.messages.count == 2)
        // The stopped chat wasn't pinned, so nothing else was kept.
        #expect(try h.stored().count == 1)
    }

    @Test func rowsAndToolResultsArentKept() async throws {
        let h = PinHarness()
        await h.send("Hi")
        h.provider.fail(.offline)
        await h.waitUntil { !h.chat.isBusy }
        h.chat.togglePin()
        let stored = try #require(try h.stored().first)
        #expect(stored.messages.map(\.text) == ["Hi"])
    }

    @Test func theListIsNewestPinFirstAndUnpinningARowRemovesIt() async throws {
        let h = PinHarness()
        await h.send("First")
        await h.reply("1")
        h.chat.togglePin()
        h.chat.newChat()
        h.clock.advance(by: 90)
        await h.send("Second")
        await h.reply("2")
        h.chat.togglePin()
        #expect(h.model.pins.screen.rows.map(\.title) == ["Second", "First"])
        #expect(h.model.pins.screen.rows.map(\.date) == ["Just now", "1 min ago"])
        #expect(h.model.pins.screen.rows.first?.unpinHelp == "Unpin Second")
        #expect(h.model.pins.screen.rows.first?.accessibilityLabel == "Second, 2 messages, GPT-4o mini, Just now")

        // Unpinning another chat leaves this one pinned.
        let first = try #require(h.model.pins.screen.rows.last?.id)
        h.model.pins.unpin(first)
        #expect(h.model.pins.screen.rows.map(\.title) == ["Second"])
        #expect(h.chat.isPinned)
        h.model.pins.unpin(h.model.pins.screen.rows[0].id)
        #expect(h.model.pins.screen.empty == Strings.Chat.nothingPinned)
        #expect(h.model.pins.screen.rows.isEmpty && !h.chat.isPinned)
    }

    @Test func clearOnCloseClearsOnlyAnUnpinnedChat() async {
        let h = PinHarness()
        h.model.settings.update { $0.general.clearOnClose = true }
        await h.send("Keep me")
        await h.reply("Kept.")
        h.chat.togglePin()
        h.hud.close()
        #expect(h.chat.hasMessages && h.chat.isPinned)
        h.chat.togglePin()
        h.hud.open()
        h.hud.close()
        #expect(!h.chat.hasMessages)
    }

    @Test func thePinnedChatsActionOpensTheList() throws {
        let h = PinHarness()
        h.hud.selectTab(.focus)
        let action = try #require(h.model.registry.actions.first { $0.id == ActionID("chat.pinned") })
        #expect(action.subtitle == "0 saved")
        action.run()
        #expect(h.hud.tab == .chat && h.model.body == .pinnedList)
        // Esc goes back to the chat.
        h.hud.escape()
        #expect(h.hud.chatView == .conversation)
    }

    @Test func theCmdPHintIsBack() {
        let h = PinHarness()
        #expect(h.hud.footerLeft == .hints(Strings.Hints.chat))
        #expect(Strings.Hints.chat.contains { $0.keys == ["⌘P"] })
    }
}

// MARK: - The store on its own

@MainActor
@Suite(.serialized) struct SQLitePinnedChatsTests {
    @Test func imagesRoundTripAsBlobsAndUnusedOnesGo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("headsup-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLitePinnedChats(folder: folder)
        let bytes = Data([0, 1, 2, 0xFF, 0])
        let image = ProcessedImage(data: bytes, mime: .png, pixelWidth: 1, pixelHeight: 1, preview: bytes)
        let message = ChatMessage(role: .user, text: "", imageIDs: ["i1"])
        var chat = PinnedChat(
            id: "c1", title: "Image conversation", modelName: "GPT-4o mini", pinnedAt: Date(milliseconds: 1000),
            updatedAt: Date(milliseconds: 1000), messages: [message], images: ["i1": image, "i2": image])
        try store.save(chat)
        let loaded = try #require(try store.load("c1"))
        #expect(loaded.messages == [message])
        #expect(loaded.images.keys.sorted() == ["i1"])
        #expect(loaded.images["i1"]?.data == bytes && loaded.images["i1"]?.mime == .png)

        chat.messages = [ChatMessage(role: .user, text: "now text only")]
        try store.save(chat)
        #expect(try store.load("c1")?.images.isEmpty == true)
    }
}

// MARK: - Fix loop: image limits (Scan L1, L2), counts, the VoiceOver label

@MainActor
@Suite(.serialized) struct ImageLimitTests {
    @Test func onlyTheAllowedTypesWithinTheSizeLimitsPass() throws {
        for type in [
            "public.png", "public.jpeg", "public.heic", "com.compuserve.gif", "org.webmproject.webp", "public.tiff",
        ] {
            try ImageLimits.check(type: type, width: 4032, height: 3024)
        }
        for type in ["com.adobe.pdf", "public.svg-image", "com.canon.cr2-raw-image", "public.image", nil] {
            #expect(throws: ImageError.notAnImage) { try ImageLimits.check(type: type, width: 100, height: 100) }
        }
        #expect(throws: ImageError.tooLarge) { try ImageLimits.check(type: "public.png", width: 20_001, height: 10) }
        #expect(throws: ImageError.tooLarge) {
            try ImageLimits.check(type: "public.png", width: 10_001, height: 10_000)
        }
        try ImageLimits.check(type: "public.png", width: 20_000, height: 5000)
        #expect(throws: ImageError.notAnImage) { try ImageLimits.check(type: "public.png", width: 0, height: 0) }
    }

    @Test func aDecompressionBombIsRefusedWithItsOwnLine() async {
        let h = PinHarness()
        await h.attach([image("bomb.png", "hdr:public.png:50000x50000;"), image("ok.png")])
        #expect(h.chat.attachments.map(\.name) == ["ok.png"])
        #expect(h.chat.attachmentNotice?.text == "1 image wasn't attached because it's too big.")
    }

    @Test func aTypeOffTheListIsNotAnImage() async {
        let h = PinHarness()
        await h.attach([image("drawing.svg", "hdr:public.svg-image:100x100;")])
        #expect(h.chat.attachments.isEmpty)
        #expect(h.chat.attachmentNotice?.text == "Only images can be attached")
    }

    @Test func theNoticeCountsEverythingOffered() async {
        let h = PinHarness()
        // A drop of 9 reads only the 5 that fit.
        await h.chat.attach((1...5).map { image("\($0).png") }, offered: 9)?.value
        #expect(h.chat.attachments.count == 5)
        #expect(h.chat.attachmentNotice?.text == "You can send up to 5 images at a time. 4 images weren't added.")
    }

    @Test func thePickerReadsWhatFitsAndCountsTheRest() async {
        let h = PinHarness()
        await h.attach([image("a.png"), image("b.png")])
        h.panels.images = (1...7).map { image("\($0).png") }
        await h.model.pickImages().value
        #expect(h.panels.imageLimits == [3])
        #expect(h.chat.attachments.count == 5)
        #expect(h.chat.attachmentNotice?.text == "You can send up to 5 images at a time. 4 images weren't added.")
    }

    @Test func pasteCountsTheRestToo() async {
        let h = PinHarness()
        h.pasteboard.images = (1...6).map { image("\($0).png") }
        #expect(h.model.pasteImages())
        await h.waitUntil { h.chat.attachments.count == 5 }
        #expect(h.chat.attachmentNotice?.text == "You can send up to 5 images at a time. 1 image wasn't added.")
    }

    @Test func voiceOverSaysWhichModelCantSeeAnImage() async {
        let h = PinHarness(endpoints: [PinHarness.textOnly, PinHarness.vision])
        await h.attach([image("Screenshot 1.png")])
        #expect(h.chat.attachments.first?.accessibilityLabel == "Screenshot 1.png, can't be seen by Llama 3.1 8B")
        h.model.performAttachmentNotice(.switchModel("gpt"))
        #expect(h.chat.attachments.first?.accessibilityLabel == "Image Screenshot 1.png")
    }
}

// MARK: - Fix loop: the pins store, failed saves, corrupt rows, New chat

@MainActor
@Suite(.serialized) struct PinFixLoopTests {
    private func failure(_ message: String) -> PinnedChatsError { PinnedChatsError(message: message) }

    @Test func aFailedPinShowsTheLineAndTryAgainClearsIt() async throws {
        let store = FakePinnedChats()
        let h = PinHarness(pinStore: store)
        await h.send("Plan my week")
        await h.reply("Sure.")
        store.failure = failure("database or disk is full")
        h.chat.togglePin()
        #expect(!h.chat.isPinned)
        let problem = try #require(h.chat.screen.toolbar.problem)
        #expect(problem.text == "Couldn't pin this chat (the disk is full).")
        #expect(problem.tryAgain == "Try Again")
        // Never a toast.
        #expect(h.hud.footerLeft != .toast("Chat pinned"))
        if case .toast = h.hud.footerLeft { Issue.record("a failed pin showed a toast") }

        store.failure = nil
        h.chat.retryPin()
        #expect(h.chat.isPinned && h.chat.screen.toolbar.problem == nil)
    }

    @Test func aFollowUpThatIsntSavedSaysSoAndTheNextSaveClearsIt() async throws {
        let store = FakePinnedChats()
        let h = PinHarness(pinStore: store)
        await h.send("Plan my week")
        await h.reply("Sure.")
        h.chat.togglePin()
        store.failure = failure("some I/O error")
        await h.send("And Friday?")
        #expect(h.chat.isPinned)
        #expect(h.chat.screen.toolbar.problem?.text == "Pinned, but the latest messages aren't saved.")
        store.failure = nil
        await h.reply("Free.")
        #expect(h.chat.screen.toolbar.problem == nil)
        #expect(try store.load(try #require(h.model.pins.screen.rows.first?.id))?.messages.count == 4)
    }

    @Test func aFailedUnpinKeepsThePinAndNewChatClearsTheLine() async throws {
        let store = FakePinnedChats()
        let h = PinHarness(pinStore: store)
        await h.send("Plan my week")
        await h.reply("Sure.")
        h.chat.togglePin()
        store.failure = failure("attempt to write a readonly database")
        h.chat.togglePin()
        #expect(h.chat.isPinned)
        #expect(h.chat.screen.toolbar.problem?.text == "Couldn't unpin this chat (the file can't be written).")
        h.chat.newChat()
        #expect(h.chat.screen.toolbar.problem == nil)
    }

    @Test func unpinningTheLoadedChatFromTheListUnlinksIt() async throws {
        let h = PinHarness()
        await h.send("Plan my week")
        await h.reply("Sure.")
        h.chat.togglePin()
        let row = try #require(h.model.pins.screen.rows.first)
        #expect(row.isLoaded)
        h.model.pins.unpin(row.id)
        #expect(!h.chat.isPinned && h.chat.hasMessages && h.model.pins.count == 0)
    }

    @Test func aCorruptRowFailsTheLoadAsAWhole() async throws {
        let h = PinHarness()
        await h.send("Plan my week")
        await h.reply("Sure.")
        h.chat.togglePin()
        let id = try #require(h.model.pins.screen.rows.first?.id)
        let database = try Database(file: h.databaseFile)
        try database.execute("UPDATE message SET body = '{\"role\":42}' WHERE chat_id = ? AND seq = 1", [.text(id)])
        #expect(throws: PinnedChatsError.self) { try SQLitePinnedChats(folder: h.folder).load(id) }

        h.chat.newChat()
        h.hud.togglePinnedList()
        #expect(h.model.loadPinned(id) == nil)
        #expect(!h.chat.hasMessages)
        #expect(h.model.pins.screen.problem?.text == "Couldn't open this chat (the saved chat can't be read).")
        #expect(h.model.pins.screen.problem?.retry == nil)
    }

    @Test func aLoadedPinShowsSmallPreviewsNotTheFullImage() async throws {
        let h = PinHarness()
        await h.attach([image("cat.png", "full-size-bytes")])
        await h.send("What's this?")
        await h.reply("A cat.")
        h.chat.togglePin()
        let id = try #require(h.model.pins.screen.rows.first?.id)
        h.relaunch()
        await h.model.loadPinned(id)?.value
        guard case .user(_, _, let images, _)? = h.chat.screen.messages.first else {
            Issue.record("expected the user's message")
            return
        }
        #expect(images.first?.preview == Data("preview".utf8))
    }

    @Test func newChatIsAOneClickCatalogueAction() async throws {
        let h = PinHarness()
        await h.send("Hello")
        await h.reply("Hi.")
        let action = try #require(h.model.registry.actions.first { $0.id == ActionID("chat.new") })
        #expect(action.title == "New chat" && action.subtitle == "clear the current conversation")
        #expect(action.kind == .chat && action.glyph == .plus && action.suggest == .oneClick)
        action.run()
        #expect(!h.chat.hasMessages)
    }
}

@MainActor
@Suite(.serialized) struct PinFixLoopTwoTests {
    @Test func tooBigImagesAloneGetTheAdvice() async {
        let h = PinHarness()
        await h.attach([image("a.png", "hdr:public.png:30000x100;")])
        #expect(
            h.chat.attachmentNotice?.text
                == "This image is too big to attach. Try a smaller copy or a screenshot of it.")
        await h.attach([image("a.png", "hdr:public.png:30000x100;"), image("b.png", "hdr:public.png:30000x100;")])
        #expect(h.chat.attachmentNotice?.text == "2 images are too big to attach. Try smaller copies.")
        await h.attach([
            image("a.png", "hdr:public.png:30000x100;"), image("b.png", "hdr:public.png:30000x100;"), image("ok.png"),
        ])
        #expect(h.chat.attachmentNotice?.text == "2 images weren't attached because they're too big.")
    }

    @Test func aListThatCantBeReadOffersTryAgain() throws {
        let store = FakePinnedChats()
        store.failure = PinnedChatsError(message: "database or disk is full")
        let h = PinHarness(pinStore: store)
        let problem = try #require(h.model.pins.screen.problem)
        #expect(problem.text == "Couldn't read your pinned chats (the disk is full).")
        #expect(problem.retry == "Try Again")
        store.failure = nil
        h.model.pins.retry()
        #expect(h.model.pins.screen.problem == nil)
    }
}
