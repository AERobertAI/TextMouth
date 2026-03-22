import Foundation

// Helper
extension String {
    static func *(lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}

print("=" * 60)
print("TextMouth Parser & Model Test Suite")
print("=" * 60)
print("Test data directory: \(testDataDir)\n")

runEPUBParserTests()
runHTMLParserTests()
runPlainTextParserTests()
runMarkdownParserTests()
runMD5Tests()
runLibraryModelTests()
runDocumentContentTests()
runEPUBMetadataTests()
runTimeFormattingTests()
runAudioEngineTests()
runKeyboardShortcutTests()
runWhereAmITests()
runNavigationTests()
runPlaybackTests()
runSleepTimerTests()
runBookStateTests()
runParserEdgeCaseTests()
runTextSubstitutionTests()
runFeatureTests()
runAudioMetadataTests()
runWindowFocusTests()
runFolderMoveTests()
runVoiceSettingsTests()
runHTMLToMarkdownTests()
runDOCXParserTests()
runDAISYParserTests()
runMarkdownCacheTests()
runOrphanAdoptionTests()
runFolderNavigationHistoryTests()
runManualOrderTests()
runFolderSortSettingTests()
runMenuVisibilityTests()
runRelocationTests()
runEmptyDirectoryCleanupTests()
runOrphanNonReAdoptionTests()
runIntegrationTests()

// ---- Summary ----
print("\n" + "=" * 60)
print("RESULTS: \(passedTests)/\(totalTests) passed, \(failedTests) failed")
print("=" * 60)

if failedTests > 0 {
    exit(1)
}
