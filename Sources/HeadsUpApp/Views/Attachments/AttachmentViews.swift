import AppKit
import HeadsUpCore
import SwiftUI
import UniformTypeIdentifiers

/// The images waiting to be sent, as 30 × 30 thumbnails before the prompt. Hovering one shows
/// a dark overlay with ×, which removes it; a warning badge marks an image the model can't see.
struct AttachmentThumbs: View {
    let thumbs: [Thumb]
    let remove: @MainActor (Thumb.ID) -> Void

    var body: some View {
        HStack(spacing: HUDStyle.Attachments.gap) {
            ForEach(thumbs, id: \.id) { thumb in
                HeaderThumb(thumb: thumb) { remove(thumb.id) }
            }
        }
    }
}

private struct HeaderThumb: View {
    let thumb: Thumb
    let remove: @MainActor () -> Void

    @State private var isHovered = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HUDStyle.Attachments.headerRadius)
        ThumbImage(preview: thumb.preview)
            .frame(width: HUDStyle.Attachments.headerSize, height: HUDStyle.Attachments.headerSize)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    HUDStyle.Colors.line, lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
            )
            .overlay {
                if isHovered {
                    Button(action: remove) {
                        Image(systemName: Symbols.close)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black.opacity(0.45), in: shape)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(alignment: .topTrailing) {
                if thumb.hasWarning {
                    Circle()
                        .fill(HUDStyle.Colors.warn)
                        .frame(width: HUDStyle.Attachments.badgeSize, height: HUDStyle.Attachments.badgeSize)
                        .offset(x: 3, y: -3)
                        .accessibilityHidden(true)
                }
            }
            .onHover { isHovered = $0 }
            .help(thumb.name)
            .accessibilityElement()
            .accessibilityLabel(thumb.accessibilityLabel)
            .accessibilityAction(named: thumb.removeLabel, remove)
    }
}

/// A thumbnail's picture, cover-fit, or the photo icon when there is no preview.
struct ThumbImage: View {
    let preview: Data?

    var body: some View {
        if let preview, let image = NSImage(data: preview) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: Symbols.photo)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(HUDStyle.Colors.chip)
        }
    }
}

/// The Chat tab's two icon buttons after the prompt: Pinned chats (filled while the list
/// shows) and Attach image.
struct ChatHeaderButtons: View {
    let buttons: ChatButtons
    let togglePinned: @MainActor () -> Void
    let attach: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 2) {
            IconButton(
                symbol: Glyph.pin.symbolName, isOn: buttons.pinned.isOn, help: buttons.pinned.help,
                accessibilityLabel: buttons.pinned.accessibilityLabel, action: togglePinned)
            IconButton(
                symbol: Symbols.paperclip, isOn: false, help: buttons.attach.help,
                accessibilityLabel: buttons.attach.accessibilityLabel, action: attach)
        }
    }
}

/// A 28 × 28 icon button, with the raised fill while on.
private struct IconButton: View {
    let symbol: String
    let isOn: Bool
    let help: String
    let accessibilityLabel: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: HUDStyle.Attachments.buttonSize, height: HUDStyle.Attachments.buttonSize)
                .background(
                    isOn ? HUDStyle.Colors.raise2 : Color.clear,
                    in: RoundedRectangle(cornerRadius: HUDStyle.Keycap.cornerRadius + 2)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// The images of a sent message, above its bubble: 120 × 80, 6 pt apart, right-aligned.
/// Without a preview, the photo icon and the file's name.
struct BubbleImages: View {
    let thumbs: [Thumb]

    var body: some View {
        HStack(spacing: HUDStyle.Attachments.gap) {
            Spacer(minLength: 0)
            ForEach(thumbs, id: \.id) { thumb in
                Group {
                    if thumb.preview != nil {
                        ThumbImage(preview: thumb.preview)
                    } else {
                        VStack(spacing: 2) {
                            Image(systemName: Symbols.photo)
                            Text(thumb.name)
                                .font(.system(size: HUDStyle.Footer.fontSize))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(HUDStyle.Colors.chip)
                    }
                }
                .frame(width: HUDStyle.Attachments.bubbleWidth, height: HUDStyle.Attachments.bubbleHeight)
                .clipShape(RoundedRectangle(cornerRadius: HUDStyle.Attachments.bubbleRadius))
                .accessibilityElement()
                .accessibilityLabel(thumb.accessibilityLabel)
            }
        }
    }
}

/// The image notice in the HUD's notice place: a model that can't see images, a 6th image,
/// or no model. Its buttons switch model, remove the image or open Settings; × closes it.
struct AttachmentNoticeBar: View {
    let model: AppModel
    let notice: AttachmentNotice

    var body: some View {
        NoticeBar(text: notice.text) {
            ForEach(Array(notice.actions.enumerated()), id: \.offset) { _, action in
                Button(action.title) { model.performAttachmentNotice(action.kind) }
                    .buttonStyle(.bordered)
            }
            if let dismiss = notice.dismiss {
                Button {
                    model.chat.dismissAttachmentNotice()
                } label: {
                    Image(systemName: Symbols.close)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(dismiss)
            }
        }
    }
}

/// Dragging images over the HUD: the drop zone the core describes, an accent ring around the
/// HUD when the drop would be taken, and the images handed to `chat.attach` on drop.
struct ImageDropTarget: DropDelegate {
    let chat: ChatStore
    @Binding var zone: DropZone?

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: zone?.style == .accept ? .copy : .forbidden)
    }

    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { zone = nil }
        guard zone?.style == .accept else { return false }
        let providers = info.itemProviders(for: [.item])
        let offered = ImageDropReader.count(providers).images
        Task { @MainActor in
            chat.attach(await ImageDropReader.read(providers), offered: offered)
        }
        return true
    }

    private func update(_ info: DropInfo) {
        let counts = ImageDropReader.count(info.itemProviders(for: [.item]))
        zone = chat.dropZone(images: counts.images, others: counts.others)
    }
}

/// What the HUD shows while something is dragged over it: a 2 pt accent ring when the drop is
/// taken, and a centred photo icon with the core's text ("Drop to attach").
struct DropZoneOverlay: View {
    let zone: DropZone

    var body: some View {
        ZStack {
            if zone.style == .accept {
                RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius)
                    .strokeBorder(Color.accentColor, lineWidth: HUDStyle.Attachments.dropRing)
            }
            VStack(spacing: HUDStyle.Footer.keyGap) {
                Image(systemName: Symbols.photo)
                    .font(.system(size: HUDStyle.Attachments.dropIconSize))
                    .accessibilityHidden(true)
                Text(zone.text)
                    .font(.system(size: HUDStyle.Settings.labelSize, weight: .semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(zone.style == .accept ? Color.primary : Color.secondary)
            .padding(HUDStyle.Welcome.padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: HUDStyle.Notice.cornerRadius))
        }
        .allowsHitTesting(false)
    }
}
