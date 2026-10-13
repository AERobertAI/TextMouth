import Foundation

extension Array {
    /// The element at `index`, or nil when there is none.
    ///
    /// A test that subscripts a list it has not proven long enough traps when
    /// the code under test breaks, and the crash takes the whole test host
    /// down. Reading through this subscript instead turns the same break into
    /// an ordinary failed assertion (compare `list[safe: 2]?.title`), or a
    /// failed `try XCTUnwrap(list[safe: 2])`.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
