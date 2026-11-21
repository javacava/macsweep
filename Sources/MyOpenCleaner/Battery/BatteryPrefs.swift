import Foundation

enum Prefs {
    static let fahrenheit = "tempFahrenheit"
    static let macInterval = "batteryMacInterval"
    static let iosInterval = "batteryIOSInterval"
    static let autoHistory = "batteryAutoHistory"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [fahrenheit: false, macInterval: 3.0, iosInterval: 10.0, autoHistory: true])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func double(_ key: String) -> Double { UserDefaults.standard.double(forKey: key) }
}

enum Fmt {
    /// Fixed-point number with the user's decimal separator.
    static func num(_ v: Double, _ digits: Int = 1, signed: Bool = false) -> String {
        String(format: "%\(signed ? "+" : "").\(digits)f", locale: .current, v)
    }

    static func temp(_ celsius: Double?) -> String {
        guard let c = celsius else { return "—" }
        if Prefs.bool(Prefs.fahrenheit) { return num(c * 9 / 5 + 32) + " °F" }
        return num(c) + " °C"
    }

    static func mAh(_ v: Int) -> String { "\(v) mAh" }

    static func watts(_ w: Double) -> String { num(abs(w)) + " W" }

    static func percent(_ v: Double) -> String { num(v) + "%" }

    static func volts(_ v: Double, _ digits: Int = 2) -> String { num(v, digits) + " V" }

    static func duration(minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static func date(_ d: Date) -> String {
        d.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year())
    }

    static func dateTime(_ d: Date) -> String {
        d.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().hour().minute())
    }

    /// "4 yr 3 mo" style age.
    static func age(since date: Date, now: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date, to: now)
        let y = c.year ?? 0, m = c.month ?? 0, d = c.day ?? 0
        if y > 0 { return m > 0 ? "\(y) yr \(m) mo" : "\(y) yr" }
        if m > 0 { return "\(m) mo" }
        return "\(max(d, 0)) days"
    }
}
