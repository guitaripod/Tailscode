import Foundation

/// What a picture should cost before it is asked for, learned from the ones this session already
/// made on the same engine at the same size. There is no model of the card here and none is
/// invented: with nothing comparable behind it the answer is nil and the surface says nothing,
/// because a figure nobody measured is the one thing an estimate may not be. Like the video
/// forge's `ForgeClock`, it is always spoken as "about" — a cold card loads the model before the
/// first step and a queue ahead is somebody else's time.
public enum ImageGenEstimate {
    /// How many of the most recent comparable renders are averaged, so a morning that woke the
    /// card cold is forgotten after a few pictures rather than remembered all week.
    public static let window = 4

    /// The seconds the next render of this shape is expected to take, or nil when this session has
    /// not made one like it. Comparable means the same engine, the same size and the same mode — an
    /// edit reads and encodes a picture first, so it is never priced from a render of words alone.
    public static func seconds(
        engine: ImageGenEngine, size: ImageGenSize, mode: ImageGenMode,
        among pictures: [ImageGenPicture]
    ) -> TimeInterval? {
        let comparable = pictures.filter {
            $0.engine == engine && $0.size == size && $0.mode == mode && $0.seconds > 0
        }
        .prefix(window)
        guard !comparable.isEmpty else { return nil }
        return comparable.map(\.seconds).reduce(0, +) / Double(comparable.count)
    }

    /// The quiet line beside the Generate control: the estimate and where the work happens, or
    /// nil while there is nothing measured to say.
    public static func line(
        machine: String, engine: ImageGenEngine, size: ImageGenSize, mode: ImageGenMode,
        among pictures: [ImageGenPicture]
    ) -> String? {
        guard
            let seconds = seconds(engine: engine, size: size, mode: mode, among: pictures)
        else { return nil }
        return Localized.text("about %@ on %@", ForgeClock.words(seconds), machine)
    }
}
