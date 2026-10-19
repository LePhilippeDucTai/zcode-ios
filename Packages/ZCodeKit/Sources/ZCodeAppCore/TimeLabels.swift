import Foundation

/// Heures et durées affichées dans la conversation (lot 13F). Horodatages en millisecondes depuis l'époque Unix,
/// comme l'hôte. Fuseau de l'iPhone, noms en français, toujours 24 h (motifs explicites).
public struct TimeLabels: Sendable {
    public static let current = TimeLabels()

    private let calendar: Calendar
    private let shortDate: Date.VerbatimFormatStyle       // « mar. 13 oct., 11:52 »
    private let shortDateYear: Date.VerbatimFormatStyle   // « 13 oct. 2025, 11:52 »
    private let exactDate: Date.VerbatimFormatStyle       // « mardi 13 octobre, 11:52:41 »
    private let exactDateYear: Date.VerbatimFormatStyle   // « mardi 13 octobre 2025, 11:52:41 »
    private let hourMinute: Date.VerbatimFormatStyle      // « 22:05 »
    private let hourMinuteSecond: Date.VerbatimFormatStyle // « 14:32:05 »

    public init(timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = Locale(identifier: "fr_FR")) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        self.calendar = calendar
        func style(_ format: Date.FormatString) -> Date.VerbatimFormatStyle {
            Date.VerbatimFormatStyle(format: format, locale: locale, timeZone: timeZone, calendar: calendar)
        }
        let hour = Date.FormatStyle.Symbol.VerbatimHour.twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)
        shortDate = style("\(weekday: .abbreviated) \(day: .defaultDigits) \(month: .abbreviated), \(hour: hour):\(minute: .twoDigits)")
        shortDateYear = style("\(day: .defaultDigits) \(month: .abbreviated) \(year: .defaultDigits), \(hour: hour):\(minute: .twoDigits)")
        exactDate = style("\(weekday: .wide) \(day: .defaultDigits) \(month: .wide), \(hour: hour):\(minute: .twoDigits):\(second: .twoDigits)")
        exactDateYear = style("\(weekday: .wide) \(day: .defaultDigits) \(month: .wide) \(year: .defaultDigits), \(hour: hour):\(minute: .twoDigits):\(second: .twoDigits)")
        hourMinute = style("\(hour: hour):\(minute: .twoDigits)")
        hourMinuteSecond = style("\(hour: hour):\(minute: .twoDigits):\(second: .twoDigits)")
    }

    private static func date(_ milliseconds: Double) -> Date { Date(timeIntervalSince1970: milliseconds / 1000) }

    /// « à l'instant », « il y a 12 min », « il y a 3 h 12 », « hier 22:05 », « mar. 13 oct., 11:52 ».
    /// Une date dans le futur (horloges décalées) vaut « à l'instant ».
    public func relative(_ milliseconds: Double, now: Date) -> String {
        let date = Self.date(milliseconds)
        let seconds = Int(now.timeIntervalSince(date).rounded(.down))
        if seconds < 60 { return "à l'instant" }
        if seconds < 3600 { return "il y a \(seconds / 60) min" }
        if seconds < 86_400 {
            let minutes = (seconds % 3600) / 60
            return minutes == 0 ? "il y a \(seconds / 3600) h" : "il y a \(seconds / 3600) h \(Self.twoDigits(minutes))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "hier \(date.formatted(hourMinute))"
        }
        return date.formatted(sameYear(date, now) ? shortDate : shortDateYear)
    }

    /// « mardi 13 octobre, 11:52:41 » (année ajoutée si ce n'est pas celle de `now`).
    public func exact(_ milliseconds: Double, now: Date) -> String {
        let date = Self.date(milliseconds)
        return date.formatted(sameYear(date, now) ? exactDate : exactDateYear)
    }

    /// « 14:32:05 ».
    public func clock(_ milliseconds: Double) -> String { Self.date(milliseconds).formatted(hourMinuteSecond) }

    /// « créée il y a 3 h 12 », « créée hier 22:05 », « créée le mar. 13 oct., 11:52 ».
    public func created(_ milliseconds: Double, now: Date) -> String {
        let relative = relative(milliseconds, now: now)
        let isPhrase = relative.hasPrefix("il y a") || relative.hasPrefix("à l'instant") || relative.hasPrefix("hier")
        return isPhrase ? "créée \(relative)" : "créée le \(relative)"
    }

    /// Durée d'une carte d'outil, arrondie vers le bas (un compteur ne recule jamais) : « < 1 s », « 3,2 s », « 42 s »,
    /// « 2 min 05 s », « 1 h 04 min ». Négative (horloges décalées) ⇒ « < 1 s ».
    public static func toolDuration(milliseconds: Double) -> String {
        let milliseconds = max(0, milliseconds)
        if milliseconds < 1000 { return "< 1 s" }
        if milliseconds < 10_000 {
            let tenths = Int(milliseconds / 100)
            return "\(tenths / 10),\(tenths % 10) s"
        }
        let seconds = Int(milliseconds / 1000)
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min \(twoDigits(seconds % 60)) s" }
        return "\(seconds / 3600) h \(twoDigits((seconds % 3600) / 60)) min"
    }

    /// Temps de travail d'une session : « 9 s », « 47 min », « 1 h 04 » (arrondi vers le bas).
    public static func workDuration(milliseconds: Double) -> String {
        let seconds = Int(max(0, milliseconds) / 1000)
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \(twoDigits((seconds % 3600) / 60))"
    }

    private func sameYear(_ date: Date, _ now: Date) -> Bool {
        calendar.component(.year, from: date) == calendar.component(.year, from: now)
    }

    private static func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
}
