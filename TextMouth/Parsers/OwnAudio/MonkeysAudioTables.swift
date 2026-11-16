import Foundation

// The tables of Monkey's Audio's range coder, from the Monkey's Audio SDK
// 13.47 (UnBitArrayBase.h and UnBitArray.cpp), Copyright 2000-2026 Matthew
// T. Ashland, used under its BSD 3-clause licence, whose notice the app
// bundles (Licenses/MonkeysAudio).

/// The fixed numbers of the range coder that Monkey's Audio 3.99 and later
/// writes its residuals with.
enum MonkeysAudioTables {
    /// Where each of the 64 overflow symbols starts in the coder's range of
    /// 65,536, and where the last one ends (65 numbers).
    static let rangeTotals: [UInt32] = [
        0, 19578, 36160, 48417, 56323, 60899, 63265, 64435, 64971, 65232, 65351, 65416,
        65447, 65466, 65476, 65482, 65485, 65488, 65490, 65491, 65492, 65493, 65494, 65495,
        65496, 65497, 65498, 65499, 65500, 65501, 65502, 65503, 65504, 65505, 65506, 65507,
        65508, 65509, 65510, 65511, 65512, 65513, 65514, 65515, 65516, 65517, 65518, 65519,
        65520, 65521, 65522, 65523, 65524, 65525, 65526, 65527, 65528, 65529, 65530, 65531,
        65532, 65533, 65534, 65535, 65536,
    ]

    /// How much of the range each overflow symbol takes: each total's
    /// distance to the next.
    static let rangeWidths: [UInt32] = [
        19578, 16582, 12257, 7906, 4576, 2366, 1170, 536, 261, 119, 65, 31,
        19, 10, 6, 3, 3, 2, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1,
    ]

    /// The least sum a residual coder's running sum has at each of its 32
    /// steps; 0 marks a step that is never taken.
    static let sumBoundaries: [UInt32] = [
        0, 32, 64, 128, 256, 512, 1024, 2048,
        4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288,
        1048576, 2097152, 4194304, 8388608, 16777216, 33554432, 67108864, 134217728,
        268435456, 536870912, 1073741824, 2147483648, 0, 0, 0, 0,
    ]
}
