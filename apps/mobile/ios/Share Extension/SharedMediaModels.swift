import UniformTypeIdentifiers

let kSchemePrefix = "ShareMedia"
let kUserDefaultsKey = "ShareKey"
let kUserDefaultsMessageKey = "ShareMessageKey"
let kAppGroupIdKey = "AppGroupId"

final class SharedMediaFile: Codable {
    let path: String
    let mimeType: String?
    let thumbnail: String?
    let duration: Double?
    let message: String?
    let type: SharedMediaType

    init(
        path: String,
        mimeType: String? = nil,
        thumbnail: String? = nil,
        duration: Double? = nil,
        message: String? = nil,
        type: SharedMediaType
    ) {
        self.path = path
        self.mimeType = mimeType
        self.thumbnail = thumbnail
        self.duration = duration
        self.message = message
        self.type = type
    }
}

enum SharedMediaType: String, Codable, CaseIterable {
    case image, video, text, file, url

    var toUTTypeIdentifier: String {
        if #available(iOS 14.0, *) {
            switch self {
            case .image: return UTType.image.identifier
            case .video: return UTType.movie.identifier
            case .text: return UTType.text.identifier
            case .file: return UTType.fileURL.identifier
            case .url: return UTType.url.identifier
            }
        }
        switch self {
        case .image: return "public.image"
        case .video: return "public.movie"
        case .text: return "public.text"
        case .file: return "public.file-url"
        case .url: return "public.url"
        }
    }
}
