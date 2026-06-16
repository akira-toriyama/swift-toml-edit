// The strict, fully-typed value model — the M2 decode layer's output.
//
// This is deliberately SEPARATE from the lossy `Toml.Value` (in Toml.swift),
// which is the frozen, consumer-facing projection the five family apps import:
// `Toml.Value` has no datetime case and folds every integer radix into `.int`,
// because that is all the apps need. The official toml-test conformance suite,
// by contrast, REQUIRES distinguishing the four TOML datetime kinds (offset /
// local datetime / local date / local time) and emitting canonical typed
// scalars, which the lossy model structurally cannot express. So `TypedValue`
// is the richer model the strict decoder (`decodeStrict`) produces and the
// tagged-JSON emitter walks.
//
// Datetimes carry plain calendar/clock COMPONENTS (ints + the fractional-second
// digits as written), never `Foundation.Date`: toml-test needs the exact
// RFC 3339 component round-trip and the local-vs-offset distinction, both of
// which `Date` (a single instant) would erase.

public extension Toml {

    /// A fully-typed TOML value (the strict decode result).
    indirect enum TypedValue: Sendable, Equatable {
        case string(String)
        case integer(Int64)
        case float(Double)
        case boolean(Bool)
        case offsetDateTime(DateTime)   // tagged "datetime"       in toml-test JSON
        case localDateTime(DateTime)    // tagged "datetime-local"
        case localDate(LocalDate)       // tagged "date-local"
        case localTime(LocalTime)       // tagged "time-local"
        case array([TypedValue])
        /// An inline table or a parsed sub-table. Insertion order is kept for
        /// determinism; the toml-test comparator treats tables as unordered.
        case table([(key: String, value: TypedValue)])

        public static func == (lhs: TypedValue, rhs: TypedValue) -> Bool {
            switch (lhs, rhs) {
            case let (.string(a), .string(b)):                 return a == b
            case let (.integer(a), .integer(b)):               return a == b
            case let (.float(a), .float(b)):
                // Treat NaN == NaN so test expectations are stable (TOML/JSON
                // give NaN no canonical sign, and the suite compares NaN loosely).
                return a == b || (a.isNaN && b.isNaN)
            case let (.boolean(a), .boolean(b)):               return a == b
            case let (.offsetDateTime(a), .offsetDateTime(b)): return a == b
            case let (.localDateTime(a), .localDateTime(b)):   return a == b
            case let (.localDate(a), .localDate(b)):           return a == b
            case let (.localTime(a), .localTime(b)):           return a == b
            case let (.array(a), .array(b)):                   return a == b
            case let (.table(a), .table(b)):
                return a.count == b.count
                    && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
            default:                                           return false
            }
        }
    }

    /// `YYYY-MM-DD`.
    struct LocalDate: Sendable, Equatable {
        public var year: Int
        public var month: Int
        public var day: Int
        public init(year: Int, month: Int, day: Int) {
            self.year = year; self.month = month; self.day = day
        }
    }

    /// `HH:MM:SS[.fraction]`. `fraction` is the digits AS WRITTEN after the
    /// decimal point (no point, no leading/trailing normalization), or "".
    struct LocalTime: Sendable, Equatable {
        public var hour: Int
        public var minute: Int
        public var second: Int
        public var fraction: String
        public init(hour: Int, minute: Int, second: Int, fraction: String = "") {
            self.hour = hour; self.minute = minute; self.second = second
            self.fraction = fraction
        }
    }

    /// A time-zone offset on an offset date-time: `Z`, or `±HH:MM`.
    enum Offset: Sendable, Equatable {
        case utc                                   // `Z`
        case hours(sign: Int, hour: Int, minute: Int)   // sign is +1 / -1
    }

    /// A date + time, with an optional offset. `offset == nil` is a LOCAL
    /// date-time (`datetime-local`); a non-nil offset is an OFFSET date-time
    /// (`datetime`).
    struct DateTime: Sendable, Equatable {
        public var date: LocalDate
        public var time: LocalTime
        public var offset: Offset?
        public init(date: LocalDate, time: LocalTime, offset: Offset? = nil) {
            self.date = date; self.time = time; self.offset = offset
        }
    }
}
