enum Profiler {
    static func start(_ name: StaticString) -> UInt64 { 0 }

    static func end(_ name: StaticString, _ start: UInt64) {}

    static func startDynamic(_ name: String) -> UInt64 { 0 }

    static func endDynamic(_ name: String, _ start: UInt64) {}

    static func reset() {}
    static func report(top: Int = 0) -> String { "" }
}
