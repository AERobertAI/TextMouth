import CoreGraphics
import Foundation
@testable import TextMouth

/// A recognizer that answers each picture it is asked about with the next of
/// its answers, in order (no lines once they run out), and records each
/// picture's size and the gray of its top left pixel, so a test of pictures
/// of pages (FMT34) can see what the reader asked, and on what background,
/// without Vision.
///
/// `@unchecked Sendable`: every variable is read and changed only under `lock`.
final class ScriptedPageRecognizer: PageImageTextRecognizer, @unchecked Sendable {
    /// What the recognizer gives for one picture.
    enum Answer {
        /// These lines.
        case lines([RecognizedTextLine])
        /// This error.
        case failure(Error)
    }

    /// One picture asked about.
    struct Asked: Equatable {
        var width: Int
        var height: Int
        /// The gray, from 0 to 255, of the picture's top left pixel.
        var cornerGray: UInt8
    }

    private let lock = NSLock()
    private var answers: [Answer]
    private var asked: [Asked] = []

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    /// The pictures asked about so far.
    var pictures: [Asked] {
        lock.withLock { asked }
    }

    func lines(in image: CGImage) throws -> [RecognizedTextLine] {
        let corner = (try? PageImageFixtures.gray(of: image, x: 0, y: 0)) ?? 0
        let answer: Answer? = lock.withLock {
            asked.append(Asked(width: image.width, height: image.height, cornerGray: corner))
            return answers.isEmpty ? nil : answers.removeFirst()
        }
        switch answer {
        case .lines(let lines)?: return lines
        case .failure(let error)?: throw error
        case nil: return []
        }
    }
}
