import Testing
@testable import InputInjectionKit

@Test @MainActor func accessibilityTrustReflectsSystemState() {
    // Just exercises the call path; CI/dev machines won't have this app trusted.
    _ = TextInserter.isAccessibilityTrusted
}
