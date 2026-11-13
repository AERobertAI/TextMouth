import SwiftUI

/// What the import slice presents over every screen: the Add to Library sheet,
/// when the Library asks for it (`PhoneImportCopier.showAddToLibrary(inFolder:)`),
/// and the import question waiting, which can't be swiped away. The progress
/// card isn't here: it sits at the top of the Library's list
/// (`PhoneImportProgressCard`), as the spec places it.
///
/// It starts the process's copier as the root first appears, which takes the
/// files other apps send from then on.
struct PhoneImportPresentations: ViewModifier {
    /// The app's one model.
    let model: PhoneAppModel
    /// The process's copier, whose requests and questions are presented.
    @ObservedObject private var copier: PhoneImportCopier

    /// The presentations over `model`.
    init(model: PhoneAppModel) {
        self.model = model
        copier = PhoneImportCopier.shared
    }

    func body(content: Content) -> some View {
        content
            // A question that arose while this sheet showed couldn't be
            // presented over it; it is offered again once the sheet is gone.
            .sheet(item: $copier.addToLibraryFolder, onDismiss: { copier.presentQuestionAgain() }) { request in
                PhoneAddToLibrarySheet(folderPath: request.folderPath, copier: copier)
            }
            .sheet(item: questionBinding) { question in
                PhoneImportQuestionSheet(question: question) { answer in
                    await copier.answer(question, with: answer)
                }
            }
            .onAppear {
                copier.rootAppeared()
            }
    }

    /// The question to present. Only an answer settles a question, which the
    /// copier then hears from the library, so the sheet's own attempts to
    /// clear it are ignored.
    private var questionBinding: Binding<PhoneImportQuestion?> {
        Binding(get: { copier.question }, set: { _ in })
    }
}

extension View {
    /// The import slice's presentations, over this view.
    func phoneImportPresentations(_ model: PhoneAppModel) -> some View {
        modifier(PhoneImportPresentations(model: model))
    }
}
