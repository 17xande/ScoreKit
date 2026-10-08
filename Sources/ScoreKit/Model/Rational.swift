/// An exact fraction, always in lowest terms with a positive denominator.
/// Used for positions and durations in quarter notes, so tuplets and
/// `<forward>`/`<backup>` arithmetic never accumulate rounding error.
///
/// The operators trap on overflow; code fed by untrusted input uses the
/// optional-returning `adding` / `subtracting` / `multiplied` instead.
public struct Rational: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let num: Int
    public let den: Int

    /// `den` must not be 0.
    public init(_ num: Int, _ den: Int = 1) {
        precondition(den != 0, "Rational with zero denominator")
        var n = num, d = den
        if d < 0 {
            precondition(n != .min && d != .min, "Rational overflow")
            n = -n; d = -d
        }
        let g = Rational.gcd(n.magnitude, UInt(d))
        if g > 1 {
            n /= Int(g)
            d /= Int(g)
        }
        self.num = n
        self.den = d
    }

    public static let zero = Rational(0)

    public var double: Double { Double(num) / Double(den) }
    public var description: String { den == 1 ? "\(num)" : "\(num)/\(den)" }

    private static func gcd(_ a: UInt, _ b: UInt) -> UInt {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a == 0 ? 1 : a
    }

    /// The sum, or nil if it doesn't fit in `Int`.
    public func adding(_ o: Rational) -> Rational? {
        let g = Int(Rational.gcd(UInt(den), UInt(o.den)))
        let (d, o1) = (den / g).multipliedReportingOverflow(by: o.den)
        let (a, o2) = num.multipliedReportingOverflow(by: o.den / g)
        let (b, o3) = o.num.multipliedReportingOverflow(by: den / g)
        let (n, o4) = a.addingReportingOverflow(b)
        guard !(o1 || o2 || o3 || o4) else { return nil }
        return Rational(n, d)
    }

    public func subtracting(_ o: Rational) -> Rational? {
        guard o.num != .min else { return nil }
        return adding(Rational(-o.num, o.den))
    }

    public func multiplied(by o: Rational) -> Rational? {
        // Cross-reduce first so the products stay as small as possible.
        let g1 = Int(Rational.gcd(num.magnitude, UInt(o.den)))
        let g2 = Int(Rational.gcd(o.num.magnitude, UInt(den)))
        let (n, o1) = (num / g1).multipliedReportingOverflow(by: o.num / g2)
        let (d, o2) = (den / g2).multipliedReportingOverflow(by: o.den / g1)
        guard !(o1 || o2) else { return nil }
        return Rational(n, d)
    }

    public static func + (a: Rational, b: Rational) -> Rational {
        guard let r = a.adding(b) else { preconditionFailure("Rational overflow") }
        return r
    }
    public static func - (a: Rational, b: Rational) -> Rational {
        guard let r = a.subtracting(b) else { preconditionFailure("Rational overflow") }
        return r
    }
    public static func * (a: Rational, b: Rational) -> Rational {
        guard let r = a.multiplied(by: b) else { preconditionFailure("Rational overflow") }
        return r
    }
    /// `b` must not be zero.
    public static func / (a: Rational, b: Rational) -> Rational {
        precondition(b.num != 0, "Rational division by zero")
        return a * Rational(b.den, b.num)
    }
    public static func += (a: inout Rational, b: Rational) { a = a + b }
    public static func -= (a: inout Rational, b: Rational) { a = a - b }

    public static func < (a: Rational, b: Rational) -> Bool {
        // Compare num/den by full-width cross products: exact, never overflows.
        let l = a.num.multipliedFullWidth(by: b.den)
        let r = b.num.multipliedFullWidth(by: a.den)
        return l.high != r.high ? l.high < r.high : l.low < r.low
    }
}
