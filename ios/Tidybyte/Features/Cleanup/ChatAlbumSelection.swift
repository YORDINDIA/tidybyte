import Foundation

enum ChatAlbumSelection {
    static func isRecognized(_ title: String) -> Bool {
        let normalized = title.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return ["whatsapp", "whatsapp business", "telegram", "signal", "messenger", "viber", "line", "wechat"].contains(normalized)
    }

    static func selectedIDs(in albums: [AlbumInfo], defaults: UserDefaults = .standard) -> Set<String> {
        let available = albums.filter { $0.type == .userAlbum }
        let ids = defaults.stringArray(forKey: AppPreferences.Key.chatAlbumIDs)
            .map(Set.init) ?? Set(available.filter { isRecognized($0.title) }.map(\.id))
        return ids.intersection(available.map(\.id))
    }
}
