import Foundation

/// The shape one picture of a conversation is drawn at, whatever is drawing it: a picture a person
/// clipped to a prompt, and every tile of the gallery an agent's pictures rest in.
public enum PictureShape: Sendable {
    /// The shapes a picture may take, width over height: a very tall or very wide picture is
    /// cropped to these rather than made a sliver or a banner.
    public static let aspectRange: ClosedRange<Double> = 0.55...2.4

    /// The shape assumed for a picture whose bytes have not arrived, so the tile has a height to
    /// stand in before the picture does.
    public static let placeholderAspect = 1.4

    public static func shape(of aspect: Double?) -> Double {
        let raw = aspect ?? placeholderAspect
        guard raw.isFinite, raw > 0 else { return placeholderAspect }
        return min(max(raw, aspectRange.lowerBound), aspectRange.upperBound)
    }
}
