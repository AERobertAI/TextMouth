import Foundation

/// One copy of the standard library's sort for the whole app (audit C10).
///
/// Each `sorted { … }` the app writes makes the compiler copy the standard
/// library's merge sort (`_stableSortImpl`, `_merge`, `_mergeTopRuns`,
/// `_insertionSort`) for that closure and element type: 87 copies, hundreds
/// of kilobytes of the executable. The functions here call the same
/// `sort(by:)`, so every order is identical, ties included (Swift's sort is
/// a stable merge sort in every current release), but are kept from being
/// specialized, so the app holds one copy of the sort for every call.
///
/// What it costs: a comparison goes through the closure's generic entry
/// instead of an inlined one, which is slower per comparison. Use these for
/// small and occasional sorts. A sort of the whole library on a hot path
/// (`LibraryBookSorter`) keeps the standard library's, which the performance
/// baselines time.
extension Sequence {
    /// The elements sorted by `areInIncreasingOrder`, as `sorted(by:)` sorts
    /// them: equal elements keep their order.
    ///
    /// `@inline(never)` and the specialization semantics keep the compiler
    /// from cloning this body, and so the sort inside it, for each caller.
    @inline(never)
    @_semantics("optimize.sil.specialize.generic.never")
    func sortedStably(
        by areInIncreasingOrder: (Element, Element) throws -> Bool
    ) rethrows -> [Element] {
        try sorted(by: areInIncreasingOrder)
    }
}

extension Sequence where Element: Comparable {
    /// The elements in ascending order, as `sorted()` orders them.
    @inline(never)
    @_semantics("optimize.sil.specialize.generic.never")
    func sortedStably() -> [Element] {
        sorted()
    }
}

extension MutableCollection where Self: RandomAccessCollection {
    /// Sorts the collection in place by `areInIncreasingOrder`, as
    /// `sort(by:)` does: equal elements keep their order.
    @inline(never)
    @_semantics("optimize.sil.specialize.generic.never")
    mutating func sortStably(
        by areInIncreasingOrder: (Element, Element) throws -> Bool
    ) rethrows {
        try sort(by: areInIncreasingOrder)
    }
}

extension MutableCollection where Self: RandomAccessCollection, Element: Comparable {
    /// Sorts the collection in place in ascending order, as `sort()` does.
    @inline(never)
    @_semantics("optimize.sil.specialize.generic.never")
    mutating func sortStably() {
        sort()
    }
}
