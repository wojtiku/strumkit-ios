import Testing
import Foundation
@testable import StrumKit

/// The audio lifecycle of the tuner, observed through something that is not a
/// microphone. One test here proves the seam is real: a denied permission never
/// reaches the source at all. The rest of the lifecycle's breadth is ticket 5.
@Suite("Microphone Seam Tests")
struct MicrophoneSeamTests {

    @Test("A denied microphone is never started")
    @MainActor
    func testDeniedPermissionNeverStartsTheSource() async {
        let source = ScriptedMicrophone(permissionStatus: .denied)
        let viewModel = TestTuner.viewModel(source: source)

        await viewModel.start()

        #expect(viewModel.engineStatus == .denied)
        #expect(source.startCount == 0)
        #expect(source.isStarted == false)
        #expect(source.permissionRequestCount == 0)
    }
}
