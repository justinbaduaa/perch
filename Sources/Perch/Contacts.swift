import AppKit
import Contacts

/// Resolves iMessage handles (phone numbers, emails) to Contacts names and photos.
@Observable final class ContactBook {
    struct Entry: Sendable {
        let name: String
        let shortName: String
        let photo: Data?
    }

    private var entries: [String: Entry] = [:]
    private(set) var me: Entry?
    @ObservationIgnored private var photos: [String: NSImage] = [:]

    /// Loads names and photos if Contacts is allowed. The setup window asks for it, so this never prompts.
    func load() async {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        (entries, me) = await Task.detached { Self.fetchAll() }.value
    }

    func name(_ handle: String) -> String { entries[Self.key(handle)]?.name ?? handle }
    func shortName(_ handle: String) -> String { entries[Self.key(handle)]?.shortName ?? handle }

    /// `nil` handle means the user themselves.
    func photo(_ handle: String?) -> NSImage? {
        let key = handle.map(Self.key) ?? "me"
        if let cached = photos[key] { return cached }
        guard let data = (handle == nil ? me : entries[key])?.photo, let image = NSImage(data: data) else { return nil }
        photos[key] = image
        return image
    }

    /// Emails compare case-insensitively; phones by their last 10 digits, which ignores formatting and country code.
    nonisolated static func key(_ handle: String) -> String {
        handle.contains("@") ? handle.lowercased() : String(handle.filter(\.isNumber).suffix(10))
    }

    nonisolated private static func fetchAll() -> ([String: Entry], Entry?) {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        func entry(_ c: CNContact) -> Entry {
            let name = CNContactFormatter.string(from: c, style: .fullName) ?? ""
            return Entry(name: name, shortName: c.givenName.isEmpty ? name : c.givenName, photo: c.thumbnailImageData)
        }
        var out: [String: Entry] = [:]
        try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
            let e = entry(c)
            guard !e.name.isEmpty else { return }
            for p in c.phoneNumbers { out[key(p.value.stringValue)] = e }
            for m in c.emailAddresses { out[key(m.value as String)] = e }
        }
        return (out, (try? store.unifiedMeContactWithKeys(toFetch: keys)).map(entry))
    }
}
