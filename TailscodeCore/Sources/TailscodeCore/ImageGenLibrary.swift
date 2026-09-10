import Foundation

/// One picture the machine is keeping. ComfyUI writes every render into one output directory and
/// lists that directory newest first, so this is the durable account of what has been made there
/// — by this device, by another, by the machine's own browser tab — and a picture made this
/// session is simply the newest entry in it.
///
/// What is known about a picture arrives in two steps. The listing gives a name and nothing else;
/// the file's own head, read on demand, gives the rest: its size on disk, when it was written,
/// its pixel dimensions, and — for a picture ComfyUI made — the graph that made it, which is
/// where the words, the seed and the model come from.
public struct ImageGenLibraryItem: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let filename: String
    public let subfolder: String

    public init(filename: String, subfolder: String = "") {
        self.filename = filename
        self.subfolder = subfolder
    }

    public var id: String { subfolder.isEmpty ? filename : subfolder + "/" + filename }

    public var kind: ImageGenFileKind? { ImageGenFileKind.of(filename) }

    /// What a reference graph calls a file that is already in the machine's output directory:
    /// `LoadImage` reads an annotated name straight out of it, so a kept picture becomes the
    /// next render's reference without a byte travelling.
    public var annotatedName: String { id + " [output]" }
}

/// The picture formats a gallery draws. Everything else in the output directory — the forge's
/// clips, a stray text file — is another surface's business.
public enum ImageGenFileKind: String, Sendable, Equatable, Codable, CaseIterable {
    case png
    case jpeg
    case webp

    public static func of(_ filename: String) -> ImageGenFileKind? {
        switch (filename as NSString).pathExtension.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "webp": return .webp
        default: return nil
        }
    }

    public var mime: String {
        switch self {
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        case .webp: return "image/webp"
        }
    }
}

/// Everything the head of the file says about a kept picture. Cached on the device once read,
/// because a file ComfyUI wrote is never rewritten under the same name.
public struct ImageGenLibraryFacts: Sendable, Equatable, Hashable, Codable {
    public var bytes: Int?
    public var modifiedAt: Date?
    public var width: Int?
    public var height: Int?
    public var recipe: ComfyRecipe?

    public init(
        bytes: Int? = nil, modifiedAt: Date? = nil, width: Int? = nil, height: Int? = nil,
        recipe: ComfyRecipe? = nil
    ) {
        self.bytes = bytes
        self.modifiedAt = modifiedAt
        self.width = width
        self.height = height
        self.recipe = recipe
    }

    /// The nearest of the shapes this app offers, so a kept picture can be asked for again at the
    /// size it was — or, when its size is nothing this app draws, at the closest one.
    public var aspect: ImageGenAspect? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        let ratio = Double(width) / Double(height)
        return ImageGenAspect.allCases.min {
            abs(log(Double($0.pixels.width) / Double($0.pixels.height)) - log(ratio))
                < abs(log(Double($1.pixels.width) / Double($1.pixels.height)) - log(ratio))
        }
    }

    public var dimensions: String? {
        guard let width, let height else { return nil }
        return "\(width)×\(height)"
    }
}

/// What the graph in a picture's own metadata says made it. ComfyUI stamps the API-format graph
/// into every PNG it writes, whoever queued it, so the words behind a picture made from the
/// machine's own browser read back here just as well as this app's own.
///
/// It is read by following wires rather than by node id, because ids are whoever-drew-the-graph's:
/// the sampler's positive input is walked back through every conditioning wrapper until a node
/// that holds a string of words, which is the prompt however many nodes stand between them.
public struct ComfyRecipe: Sendable, Equatable, Hashable, Codable {
    public var prompt: String?
    public var negative: String?
    public var seed: UInt64?
    public var steps: Int?
    /// The diffusion model's file name, which is the truest thing to say about a picture this app
    /// cannot name an engine for.
    public var model: String?
    public var engine: ImageGenEngine?
    public var mode: ImageGenMode
    /// What the render started from, when it started from a picture.
    public var reference: String?
    public var width: Int?
    public var height: Int?

    public init(
        prompt: String? = nil, negative: String? = nil, seed: UInt64? = nil, steps: Int? = nil,
        model: String? = nil, engine: ImageGenEngine? = nil, mode: ImageGenMode = .generate,
        reference: String? = nil, width: Int? = nil, height: Int? = nil
    ) {
        self.prompt = prompt
        self.negative = negative
        self.seed = seed
        self.steps = steps
        self.model = model
        self.engine = engine
        self.mode = mode
        self.reference = reference
        self.width = width
        self.height = height
    }

    private static let samplers: Set<String> = [
        "KSampler", "KSamplerAdvanced", "SamplerCustomAdvanced", "SamplerCustom",
    ]

    private static let modelLoaders: [(node: String, field: String)] = [
        ("UNETLoader", "unet_name"), ("CheckpointLoaderSimple", "ckpt_name"),
        ("UnetLoaderGGUF", "unet_name"),
    ]

    private static let emptyLatents: Set<String> = [
        "EmptySD3LatentImage", "EmptyLatentImage", "EmptyFlux2LatentImage",
        "EmptyHunyuanLatentVideo",
    ]

    /// The engine a model file answers for. Named by what the file is rather than by what this app
    /// would have chosen, so a picture Klein painted from somebody's own graph still reads Klein.
    public static func engine(forModel file: String) -> ImageGenEngine? {
        let lower = file.lowercased()
        if lower.contains("qwen_image") || lower.contains("qwen-image") { return .quality }
        if lower.contains("klein") { return .fast }
        return nil
    }

    public static func read(graph: [String: Any]) -> ComfyRecipe? {
        var nodes: [String: (type: String, inputs: [String: Any])] = [:]
        for (id, value) in graph {
            guard let node = value as? [String: Any], let type = node["class_type"] as? String
            else { continue }
            nodes[id] = (type, node["inputs"] as? [String: Any] ?? [:])
        }
        guard !nodes.isEmpty else { return nil }
        var recipe = ComfyRecipe()
        for (_, node) in nodes {
            for loader in modelLoaders where node.type == loader.node {
                recipe.model = node.inputs[loader.field] as? String
            }
            if node.type == "LoadImage", let name = node.inputs["image"] as? String {
                recipe.mode = .edit
                recipe.reference = name
            }
            if emptyLatents.contains(node.type) {
                recipe.width = whole(node.inputs["width"])
                recipe.height = whole(node.inputs["height"])
            }
        }
        recipe.engine = recipe.model.flatMap(engine(forModel:))
        let sampler = nodes.sorted { $0.key < $1.key }.first { samplers.contains($0.value.type) }
        guard let sampler else { return recipe }
        recipe.seed = seed(of: sampler.value, in: nodes)
        recipe.steps = steps(of: sampler.value, in: nodes)
        let (positive, negative) = conditioning(of: sampler.value, in: nodes)
        recipe.prompt = positive.flatMap { words(from: $0, in: nodes) }
        recipe.negative = negative.flatMap { words(from: $0, in: nodes) }
        return recipe
    }

    private static func whole(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func link(_ value: Any?) -> String? {
        guard let pair = value as? [Any], pair.count == 2 else { return nil }
        if let id = pair[0] as? String { return id }
        if let number = pair[0] as? NSNumber { return number.stringValue }
        return nil
    }

    private static func seed(
        of sampler: (type: String, inputs: [String: Any]),
        in nodes: [String: (type: String, inputs: [String: Any])]
    ) -> UInt64? {
        if let number = sampler.inputs["seed"] as? NSNumber ?? sampler.inputs["noise_seed"] as? NSNumber {
            return number.uint64Value
        }
        guard let noise = link(sampler.inputs["noise"]), let node = nodes[noise],
            let number = node.inputs["noise_seed"] as? NSNumber
        else { return nil }
        return number.uint64Value
    }

    private static func steps(
        of sampler: (type: String, inputs: [String: Any]),
        in nodes: [String: (type: String, inputs: [String: Any])]
    ) -> Int? {
        if let steps = whole(sampler.inputs["steps"]) { return steps }
        guard let sigmas = link(sampler.inputs["sigmas"]), let node = nodes[sigmas] else {
            return nil
        }
        return whole(node.inputs["steps"])
    }

    /// The nodes the sampler's positive and negative wires lead to. A guider stands between a
    /// custom sampler and its conditioning, so one hop through it is taken before the walk.
    private static func conditioning(
        of sampler: (type: String, inputs: [String: Any]),
        in nodes: [String: (type: String, inputs: [String: Any])]
    ) -> (String?, String?) {
        if let positive = link(sampler.inputs["positive"]) {
            return (positive, link(sampler.inputs["negative"]))
        }
        guard let guider = link(sampler.inputs["guider"]), let node = nodes[guider] else {
            return (nil, nil)
        }
        if let positive = link(node.inputs["positive"]) {
            return (positive, link(node.inputs["negative"]))
        }
        return (link(node.inputs["conditioning"]), nil)
    }

    /// Walks a conditioning wire back to the words on it: through every node that merely wraps
    /// conditioning until one holds a `text` or `prompt` string. Bounded, because a graph is a
    /// thing somebody drew and a cycle in it must not hang a gallery.
    private static func words(
        from start: String, in nodes: [String: (type: String, inputs: [String: Any])]
    ) -> String? {
        var current = start
        for _ in 0..<16 {
            guard let node = nodes[current] else { return nil }
            if let text = node.inputs["text"] as? String { return text }
            if let text = node.inputs["prompt"] as? String { return text }
            let next = ["conditioning", "positive", "clip_l", "t5xxl"].lazy
                .compactMap { link(node.inputs[$0]) }.first
            guard let next else { return nil }
            current = next
        }
        return nil
    }
}

/// The head of a PNG, read without decoding it: the signature, the dimensions in IHDR, and the
/// text chunks that come before the picture data — which is where ComfyUI puts the graph. A range
/// of the first sixty-four kilobytes is enough for every file the machine writes, so what would be
/// a megabyte per tile to learn a caption is a few packets.
public enum PNGHead {
    public static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// How much of the file is asked for. The graph rides between the header and the first picture
    /// chunk, and the largest graph the machine has ever stamped fits many times over.
    public static let probeBytes = 65_536

    public static func isPNG(_ data: Data) -> Bool {
        data.count >= 8 && [UInt8](data.prefix(8)) == signature
    }

    public static func dimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard isPNG(data), data.count >= 24 else { return nil }
        let bytes = [UInt8](data[data.startIndex + 8..<data.startIndex + 24])
        guard bytes[4] == 0x49, bytes[5] == 0x48, bytes[6] == 0x44, bytes[7] == 0x52 else {
            return nil
        }
        let width = Int(bytes[8]) << 24 | Int(bytes[9]) << 16 | Int(bytes[10]) << 8 | Int(bytes[11])
        let height = Int(bytes[12]) << 24 | Int(bytes[13]) << 16 | Int(bytes[14]) << 8 | Int(bytes[15])
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Every uncompressed text chunk before the picture data, keyed by its keyword. Both the
    /// Latin-1 `tEXt` PIL writes for plain words and the UTF-8 `iTXt` it falls back to when a
    /// prompt carries a character Latin-1 cannot hold. Tolerates a truncated tail, because the
    /// data handed in is a range of the file rather than the file.
    public static func texts(_ data: Data) -> [String: String] {
        guard isPNG(data) else { return [:] }
        var found: [String: String] = [:]
        let bytes = [UInt8](data)
        var position = 8
        while position + 8 <= bytes.count {
            let length = Int(bytes[position]) << 24 | Int(bytes[position + 1]) << 16
                | Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
            let type = String(decoding: bytes[position + 4..<position + 8], as: UTF8.self)
            if type == "IDAT" || type == "IEND" { break }
            let start = position + 8
            let end = start + length
            guard end <= bytes.count else { break }
            let body = Array(bytes[start..<end])
            switch type {
            case "tEXt":
                if let split = body.firstIndex(of: 0) {
                    let keyword = String(decoding: body[..<split], as: UTF8.self)
                    found[keyword] = String(body[(split + 1)...].map { Character(Unicode.Scalar($0)) })
                }
            case "iTXt":
                if let text = internationalText(body) { found[text.keyword] = text.value }
            default:
                break
            }
            position = end + 4
        }
        return found
    }

    private static func internationalText(_ body: [UInt8]) -> (keyword: String, value: String)? {
        guard let keywordEnd = body.firstIndex(of: 0), keywordEnd + 3 <= body.count else {
            return nil
        }
        let keyword = String(decoding: body[..<keywordEnd], as: UTF8.self)
        let compressed = body[keywordEnd + 1] != 0
        guard !compressed else { return nil }
        var cursor = keywordEnd + 3
        guard let languageEnd = body[cursor...].firstIndex(of: 0) else { return nil }
        cursor = languageEnd + 1
        guard let translatedEnd = body[cursor...].firstIndex(of: 0) else { return nil }
        cursor = translatedEnd + 1
        return (keyword, String(decoding: body[cursor...], as: UTF8.self))
    }

    /// The graph ComfyUI stamped, when there is one.
    public static func graph(_ data: Data) -> [String: Any]? {
        guard let text = texts(data)["prompt"], let json = text.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }

    /// Everything a gallery wants from the head of a file, in one read.
    public static func facts(_ data: Data) -> ImageGenLibraryFacts {
        var facts = ImageGenLibraryFacts()
        if let size = dimensions(data) {
            facts.width = size.width
            facts.height = size.height
        }
        facts.recipe = graph(data).flatMap(ComfyRecipe.read(graph:))
        return facts
    }
}

/// How the listing and the file head are read off the server's answers, kept apart from the
/// client so the shapes can be pinned in a test against real payloads.
public enum ImageGenLibraryReading {
    /// The listing route answers `["name [output]", …]`, newest first. Anything that is not a
    /// picture is left out here rather than drawn as a broken tile.
    public static func items(fromListing object: Any) -> [ImageGenLibraryItem] {
        guard let lines = object as? [String] else { return [] }
        return lines.compactMap { line in
            var name = line
            if let bracket = name.range(of: " [", options: .backwards), name.hasSuffix("]") {
                name = String(name[..<bracket.lowerBound])
            }
            guard ImageGenFileKind.of(name) != nil else { return nil }
            let parts = name.split(separator: "/", omittingEmptySubsequences: true)
            guard let last = parts.last else { return nil }
            let folder = parts.dropLast().joined(separator: "/")
            return ImageGenLibraryItem(filename: String(last), subfolder: folder)
        }
    }

    public static func date(fromHTTP text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    /// The whole file's length off a ranged answer: `bytes 0-65535/1158316` names the file, not
    /// the range.
    public static func total(fromContentRange text: String?, contentLength: String?) -> Int? {
        if let text, let slash = text.lastIndex(of: "/"),
            let total = Int(text[text.index(after: slash)...].trimmingCharacters(in: .whitespaces))
        {
            return total
        }
        return contentLength.flatMap { Int($0) }
    }
}

/// Where a gallery keeps what it has learned, so the second opening costs nothing and a machine
/// that is asleep still has a gallery to show. Under the platform's cache directory, because every
/// byte here is a copy of something the server holds.
public struct ImageGenLibraryCache: Sendable {
    public let root: URL

    public init(endpoint: ImageGenEndpoint) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let key = endpoint.displayHost.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        root = base.appendingPathComponent("Tailscode", isDirectory: true)
            .appendingPathComponent("library", isDirectory: true)
            .appendingPathComponent(String(key), isDirectory: true)
    }

    private func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func flat(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "__")
    }

    public func thumbnailURL(_ item: ImageGenLibraryItem, format: ImageGenFileKind) -> URL {
        directory("thumbs").appendingPathComponent(Self.flat(item.id) + "." + format.rawValue)
    }

    public func originalURL(_ item: ImageGenLibraryItem) -> URL {
        directory("originals").appendingPathComponent(Self.flat(item.id))
    }

    private func factsURL(_ item: ImageGenLibraryItem) -> URL {
        directory("facts").appendingPathComponent(Self.flat(item.id) + ".json")
    }

    private var listingURL: URL { directory("").appendingPathComponent("listing.json") }

    public func facts(_ item: ImageGenLibraryItem) -> ImageGenLibraryFacts? {
        guard let data = FileManager.default.contents(atPath: factsURL(item).path) else {
            return nil
        }
        return try? JSONDecoder().decode(ImageGenLibraryFacts.self, from: data)
    }

    public func store(_ facts: ImageGenLibraryFacts, for item: ImageGenLibraryItem) {
        guard let data = try? JSONEncoder().encode(facts) else { return }
        try? data.write(to: factsURL(item), options: .atomic)
    }

    /// The last listing the machine gave, so a gallery opened while it sleeps shows what was there
    /// rather than nothing — marked as such by whoever draws it.
    public func listing() -> (items: [ImageGenLibraryItem], at: Date)? {
        guard let data = FileManager.default.contents(atPath: listingURL.path),
            let stored = try? JSONDecoder().decode(StoredListing.self, from: data)
        else { return nil }
        return (stored.items, stored.at)
    }

    public func store(listing items: [ImageGenLibraryItem], at: Date = Date()) {
        guard let data = try? JSONEncoder().encode(StoredListing(items: items, at: at)) else {
            return
        }
        try? data.write(to: listingURL, options: .atomic)
    }

    private struct StoredListing: Codable {
        let items: [ImageGenLibraryItem]
        let at: Date
    }

    /// Originals are full renders and a phone's cache is not a disk: the oldest go once more than
    /// a few dozen are held.
    public func pruneOriginals(keeping limit: Int = 48) {
        let folder = directory("originals")
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        guard urls.count > limit else { return }
        let dated = urls.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url, date)
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(urls.count - limit) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Why a listing could not be had, each a sentence rather than a status code. A server too old
/// for the route is its own case, because "nothing here" and "cannot say" must never read alike.
public enum ImageGenLibraryFailure: Error, Sendable, Equatable {
    case unreachable
    case unsupported
    case refused(String)

    public func reason(machine: String) -> String {
        switch self {
        case .unreachable:
            return Localized.text("%@ was not answering", machine)
        case .unsupported:
            return Localized.text("%@'s ComfyUI is too old to list what it has made", machine)
        case .refused(let detail):
            return detail
        }
    }
}

/// Every word the gallery says that is not a picture. Held in Core so the phone, the Mac and the
/// GTK studio draw the same shelf.
public enum ImageGenLibraryWords {
    public static var title: String { Localized.text("Library") }

    /// The heading over the grid, naming the machine because that is where the pictures are.
    public static func heading(machine: String) -> String {
        Localized.text("On %@", machine)
    }

    public static func count(_ count: Int) -> String {
        switch count {
        case 0: return Localized.text("No pictures")
        case 1: return Localized.text("1 picture")
        default: return Localized.text("%@ pictures", "\(count)")
        }
    }

    /// The line under the heading: how many, and — when the listing is a remembered one rather
    /// than the machine's answer just now — when it was last true.
    public static func line(count: Int, staleSince: Date?, now: Date = Date()) -> String {
        guard let staleSince else { return Self.count(count) }
        return Localized.text("%@ · as of %@", Self.count(count), ago(staleSince, now: now))
    }

    public static var loading: String { Localized.text("Asking the machine what it has made…") }

    public static var emptyTitle: String { Localized.text("Nothing made here yet") }

    public static var emptyBody: String {
        Localized.text("Every picture rendered on this machine will be kept here.")
    }

    public static var refresh: String { Localized.text("Refresh") }

    /// A picture whose head carried no graph — dropped into the folder by hand, or made by a
    /// program that stamps nothing. It is still a picture; it just has no words.
    public static var noWords: String { Localized.text("No words recorded for this picture") }

    public static var fromLibraryHint: String {
        Localized.text("Kept on the machine — the words, seed and model are read from the file")
    }

    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return Localized.text("just now") }
        if seconds < 3600 { return Localized.text("%@ min ago", "\(Int(seconds / 60))") }
        if seconds < 86_400 { return Localized.text("%@ h ago", "\(Int(seconds / 3600))") }
        let days = Int(seconds / 86_400)
        return days == 1 ? Localized.text("yesterday") : Localized.text("%@ days ago", "\(days)")
    }

    /// The day a picture was made, said the way a person says it.
    public static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return Localized.text("Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return Localized.text("Yesterday")
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEE d MMM" : "d MMM yyyy")
        return formatter.string(from: date)
    }
}
