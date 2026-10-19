import Foundation

/// Libellés de la lecture hors ligne (lot 13E-1) : bandeau de copie et taille du cache.
public enum OfflineLabels {
    /// « Copie du 17/10 à 14:32 — connexion à l'hôte… » (`connecting`) ou « Hors ligne — copie du 17/10 à 14:32 ».
    public static func banner(savedAt: Date, connecting: Bool, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let locale = Locale(identifier: "fr_FR")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        let hour = Date.FormatStyle.Symbol.VerbatimHour.twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)
        let style = Date.VerbatimFormatStyle(
            format: "\(day: .twoDigits)/\(month: .twoDigits) à \(hour: hour):\(minute: .twoDigits)",
            locale: locale, timeZone: timeZone, calendar: calendar)
        let when = savedAt.formatted(style)
        return connecting ? "Copie du \(when) — connexion à l'hôte…" : "Hors ligne — copie du \(when)"
    }

    /// « 1,2 Mo », « 340 Ko », « Vide » (`ByteCountFormatStyle`, style fichier, locale fr_FR).
    public static func size(_ bytes: Int) -> String {
        guard bytes > 0 else { return "Vide" }
        return Int64(bytes).formatted(.byteCount(style: .file).locale(Locale(identifier: "fr_FR")))
    }
}
