import Foundation
import Testing

@testable import TailscodeCore

@Suite("Setup formatting")
struct SetupFormatTests {
    private let english = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")

    @Test("Bytes read in the unit a person thinks in, whole from ten up and one decimal below")
    func bytes() {
        #expect(SetupFormat.bytes(46_868_000_000, locale: english) == "44 GB")
        #expect(SetupFormat.bytes(23_622_320_128, locale: english) == "22 GB")
        #expect(SetupFormat.bytes(1_610_612_736, locale: english) == "1.5 GB")
        #expect(SetupFormat.bytes(820 * 1_048_576, locale: english) == "820 MB")
        #expect(SetupFormat.bytes(3 * 1_048_576, locale: english) == "3 MB")
        #expect(SetupFormat.bytes(0, locale: english) == "0 KB")
        #expect(SetupFormat.bytes(-5, locale: english) == "0 KB")
        #expect(SetupFormat.bytes(2 * 1_099_511_627_776, locale: english) == "2 TB")
    }

    @Test("Decimals follow the reader's locale")
    func localeAware() {
        #expect(SetupFormat.bytes(1_610_612_736, locale: german) == "1,5 GB")
        #expect(SetupFormat.percent(0.31, locale: english) == "31%")
        #expect(SetupFormat.percent(0.31, locale: german).contains("31"))
    }

    @Test("Machine memory is reported in mebibytes and read as a size")
    func megabytes() {
        #expect(SetupFormat.megabytes(97_887, locale: english) == "96 GB")
        #expect(SetupFormat.megabytes(81_920, locale: english) == "80 GB")
        #expect(SetupFormat.megabytes(2_048, locale: english) == "2 GB")
    }

    @Test("Progress is two figures in the total's unit")
    func progress() {
        #expect(SetupFormat.progress(done: 14_529_000_000, total: 46_868_000_000, locale: english) == "14 of 44 GB")
        #expect(SetupFormat.progress(done: 500_000_000, total: 1_610_612_736, locale: english) == "0.5 of 1.5 GB")
        #expect(SetupFormat.progress(done: 99, total: 10, locale: english) == "0 of 0 KB")
    }

    @Test("A wait is rounded to a figure the machine's rate can honestly back")
    func durations() {
        #expect(SetupFormat.duration(seconds: 10, locale: english) == "less than a minute")
        #expect(SetupFormat.duration(seconds: 44, locale: english) == "less than a minute")
        #expect(SetupFormat.duration(seconds: 60, locale: english) == "about 1 minute")
        #expect(SetupFormat.duration(seconds: 12 * 60 + 20, locale: english) == "about 12 minutes")
        #expect(SetupFormat.duration(minutes: 12, locale: english) == "about 12 minutes")
        #expect(SetupFormat.duration(seconds: 89 * 60, locale: english) == "about 89 minutes")
        #expect(SetupFormat.duration(seconds: 3 * 3600, locale: english) == "about 3 hours")
        #expect(SetupFormat.duration(seconds: 100 * 60, locale: english) == "about 2 hours")
        #expect(SetupFormat.duration(seconds: -4, locale: english) == "less than a minute")
    }

    @Test("A fraction outside zero to one, or not a number, is clamped")
    func percentClamps() {
        #expect(SetupFormat.percent(1.7, locale: english) == "100%")
        #expect(SetupFormat.percent(-1, locale: english) == "0%")
        #expect(SetupFormat.percent(.nan, locale: english) == "0%")
    }
}
