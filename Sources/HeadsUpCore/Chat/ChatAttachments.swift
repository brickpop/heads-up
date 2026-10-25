import Foundation

/// An image waiting to be sent with the next message, already cleaned by the image port (F17).
struct Attachment: Equatable, Sendable {
    let id: String
    /// Cleaned for display: "Screenshot 1.png", or "Pasted image".
    let name: String
    let image: ProcessedImage
}

/// Why images the user gave weren't added, for the notice bar (addendum 4).
enum AttachmentProblem: Equatable, Sendable {
    /// Over the 5 per message: this many weren't added.
    case tooMany(Int)
    /// Some weren't images the image port could read.
    case notImages
    /// This many were too big to open safely (Scan L1); others in the same batch may have been
    /// added.
    case tooLarge(Int, someAdded: Bool)
}

/// An image thumbnail: in the header before the prompt, or above a user message.
public struct Thumb: Equatable, Sendable, Identifiable {
    public let id: String
    /// A PNG at most 240 × 160; nil shows the photo icon.
    public let preview: Data?
    /// The tooltip: "Screenshot 1.png".
    public let name: String
    /// "Image Screenshot 1.png"
    public let accessibilityLabel: String
    /// "Remove image Screenshot 1.png", the × and its VoiceOver action.
    public let removeLabel: String
    /// The model can't see it: the small --warn badge (UX part 1, §6).
    public let hasWarning: Bool
}

/// What a drop would do, while images are dragged over the HUD (UX part 1, §7; addendum 4).
public struct DropZone: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// The accent ring: the drop is taken.
        case accept
        /// No ring, --ink-2 text: the drop is refused.
        case refuse
    }

    public let text: String
    public let style: Style
}

/// The bar at the top of the body about the attached images: the model can't see them, or
/// some weren't added. One at a time; the vision notice wins.
public struct AttachmentNotice: Equatable, Sendable {
    public let text: String
    public let actions: [NoticeAction]
    /// The ×'s VoiceOver label, or nil when the notice has no × (it lasts while it applies).
    public let dismiss: String?
}

public struct NoticeAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Switch to the first model that sees images.
        case switchModel(Endpoint.ID)
        case removeImages
        /// Settings → Models.
        case openSettings
    }

    public let kind: Kind
    public let title: String
}

/// The header's Pinned chats and Attach image buttons, on the Chat tab.
public struct ChatButtons: Equatable, Sendable {
    public struct Pinned: Equatable, Sendable {
        public let help: String
        public let accessibilityLabel: String
        /// The Pinned list shows.
        public let isOn: Bool
    }

    public struct Attach: Equatable, Sendable {
        public let help: String
        public let accessibilityLabel: String
    }

    public let pinned: Pinned
    public let attach: Attach
}

extension ChatStore {
    /// At most this many images go with one message.
    public static let maxImages = 5

    /// How many more images the next message takes.
    var imageRoom: Int { max(0, Self.maxImages - pending.count - processing) }

    /// The images waiting to be sent, as header thumbnails.
    public var attachments: [Thumb] {
        // The model that can't see them, for VoiceOver (Yuki).
        let blind = isSendBlocked ? sanitizeForDisplay(endpoints.active?.name ?? "", max: 64) : nil
        return pending.map { attachment in
            Thumb(
                id: attachment.id, preview: attachment.image.preview, name: attachment.name,
                accessibilityLabel: blind.map { Strings.Attachments.unseenLabel(attachment.name, model: $0) }
                    ?? Strings.Attachments.label(attachment.name),
                removeLabel: Strings.Attachments.remove(attachment.name), hasWarning: blind != nil)
        }
    }

    /// Pasted, picked or dropped images: `inputs` are the ones read, `offered` how many the user
    /// gave in all (a drop of 9 reads only what fits). Up to the 5 per message go through the
    /// image port off the main actor, then are added in order; the notice says how many weren't.
    /// Anything that isn't an image is skipped with "Only images can be attached".
    @discardableResult
    public func attach(_ inputs: [ImageInput], offered: Int) -> Task<Void, Never>? {
        guard !inputs.isEmpty || offered > 0 else { return nil }
        let taken = Array(inputs.prefix(imageRoom))
        let overflow = max(offered, inputs.count) - taken.count
        if overflow > 0 { attachmentProblem = .tooMany(overflow) }
        guard !taken.isEmpty else { return nil }
        processing += taken.count
        let processor = imageProcessor
        return Task {
            let results = await Task.detached(priority: .userInitiated) {
                taken.map { input in Result { () throws(ImageError) in try processor.process(input) } }
            }.value
            processing -= taken.count
            var refused = 0
            var tooLarge = 0
            for (input, result) in zip(taken, results) {
                switch result {
                case .success: break
                case .failure(.tooLarge): tooLarge += 1
                case .failure(.notAnImage): refused += 1
                }
                guard case .success(let image) = result else { continue }
                let name = sanitizeForDisplay(input.name ?? Strings.Attachments.pastedName, max: 80)
                pending.append(Attachment(id: UUID().uuidString, name: name, image: image))
            }
            // One line at a time: too large wins over not an image.
            if tooLarge > 0 {
                attachmentProblem = .tooLarge(tooLarge, someAdded: tooLarge + refused < taken.count)
            } else if refused > 0 && attachmentProblem == nil {
                attachmentProblem = .notImages
            }
        }
    }

    /// The × on a header thumbnail.
    public func removeAttachment(_ id: Thumb.ID) {
        guard pending.contains(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        attachmentProblem = nil
    }

    /// Backspace in an empty prompt removes the last image. True when one was removed, so the
    /// key monitor knows whether it took the key.
    @discardableResult
    public func removeLastAttachment() -> Bool {
        guard let last = pending.last else { return false }
        removeAttachment(last.id)
        return true
    }

    /// The vision notice's Remove image(s).
    func removeAllAttachments() {
        pending = []
        attachmentProblem = nil
    }

    /// The notice's ×.
    public func dismissAttachmentNotice() {
        attachmentProblem = nil
    }

    /// The bar about the attached images, or nil. The vision notice comes first: it lasts while
    /// the model can't see them (UX part 1, §6). The limit notice shows otherwise (addendum 4).
    public var attachmentNotice: AttachmentNotice? {
        if !pending.isEmpty, endpoints.active?.images != true {
            return visionNotice
        }
        switch attachmentProblem {
        case .tooMany(let count):
            return AttachmentNotice(
                text: Strings.Attachments.tooMany(notAdded: count), actions: [], dismiss: Strings.Attachments.close)
        case .notImages:
            return AttachmentNotice(
                text: Strings.Attachments.onlyImages, actions: [], dismiss: Strings.Attachments.close)
        case .tooLarge(let count, let someAdded):
            return AttachmentNotice(
                text: Strings.Attachments.tooLarge(count, someAdded: someAdded), actions: [],
                dismiss: Strings.Attachments.close)
        case nil:
            return nil
        }
    }

    private var visionNotice: AttachmentNotice {
        let openSettings = NoticeAction(kind: .openSettings, title: Strings.Attachments.openSettings)
        guard let active = endpoints.active else {
            return AttachmentNotice(text: Strings.Attachments.addModel, actions: [openSettings], dismiss: nil)
        }
        guard let seeing = endpoints.endpoints.first(where: \.images) else {
            return AttachmentNotice(text: Strings.Attachments.noModelSees, actions: [openSettings], dismiss: nil)
        }
        let remove = pending.count == 1 ? Strings.Attachments.removeImage : Strings.Attachments.removeImages
        return AttachmentNotice(
            text: Strings.Attachments.cantSee(sanitizeForDisplay(active.name, max: 64)),
            actions: [
                NoticeAction(
                    kind: .switchModel(seeing.id),
                    title: Strings.Attachments.switchTo(sanitizeForDisplay(seeing.name, max: 64))),
                NoticeAction(kind: .removeImages, title: remove),
            ], dismiss: nil)
    }

    /// What dropping these items would do: how many images, and how many other things, are
    /// dragged over the HUD.
    public func dropZone(images: Int, others: Int) -> DropZone {
        guard images > 0 else { return DropZone(text: Strings.Attachments.onlyImages, style: .refuse) }
        let room = imageRoom
        guard room > 0 else { return DropZone(text: Strings.Attachments.limitReached, style: .refuse) }
        if images > room { return DropZone(text: Strings.Attachments.dropSome(room, of: images), style: .accept) }
        if others > 0 { return DropZone(text: Strings.Attachments.onlyTheImages, style: .accept) }
        return DropZone(text: Strings.Attachments.dropToAttach, style: .accept)
    }
}
