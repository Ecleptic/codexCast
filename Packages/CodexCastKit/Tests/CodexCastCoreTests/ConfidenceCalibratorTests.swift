import Foundation
import Testing

@testable import CodexCastCore

@Suite("Confidence calibration — §5.7")
struct ConfidenceCalibratorTests {
    @Test("Calibrated confidence is the smoothed empirical precision")
    func smoothing() {
        // 8 confirms, 2 rejects in the 0.8 decile → Beta(2,2): 10/14 ≈ 0.71.
        let calibrator = ConfidenceCalibrator(bins: [
            .init(stage: "onDeviceModel", decile: 8, proposals: 10, confirms: 8, rejects: 2)
        ])
        let calibrated = calibrator.calibrated(stage: "onDeviceModel", rawConfidence: 0.85)
        #expect(abs(calibrated - 10.0 / 14.0) < 0.001)
    }

    @Test("A decile with no history sits at 0.5 — unproven, not trusted")
    func unproven() {
        let calibrator = ConfidenceCalibrator(bins: [])
        #expect(calibrator.calibrated(stage: "onDeviceModel", rawConfidence: 0.9) == 0.5)
        #expect(!calibrator.hasHistory(stage: "onDeviceModel"))
    }

    @Test("Never reports certainty, however lopsided the history")
    func capped() {
        let calibrator = ConfidenceCalibrator(bins: [
            .init(stage: "patternMatch", decile: 9, proposals: 500, confirms: 500, rejects: 0)
        ])
        #expect(calibrator.calibrated(stage: "patternMatch", rawConfidence: 0.95) <= 0.98)
    }

    @Test("Near-identical model scores are recognized as uninformative")
    func degeneracy() {
        let flat = Array(repeating: 0.9, count: 50) + [0.88, 0.92]
        #expect(ConfidenceCalibrator.isDegenerate(recentRawConfidences: flat))

        let spread = (0..<50).map { 0.3 + Double($0 % 7) * 0.1 }
        #expect(!ConfidenceCalibrator.isDegenerate(recentRawConfidences: spread))

        // Too few samples to judge either way.
        #expect(!ConfidenceCalibrator.isDegenerate(recentRawConfidences: [0.9, 0.9, 0.9]))
    }

    @Test("Agreement confidence scales with window consensus, bounded")
    func agreement() {
        #expect(ConfidenceCalibrator.agreementConfidence(agreeing: 2, possible: 2) == 0.85)
        #expect(ConfidenceCalibrator.agreementConfidence(agreeing: 1, possible: 2) == 0.6)
        #expect(ConfidenceCalibrator.agreementConfidence(agreeing: 0, possible: 2) == 0.35)
    }
}
