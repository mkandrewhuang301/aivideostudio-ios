import XCTest
@testable import Fantasia

final class HappyHorseModelTests: XCTestCase {
    func testCatalogSurfacesTextToVideoWithLockedAudio() {
        let option = ModelCatalog.video.first { $0.id == "alibaba/happyhorse-1.1" }

        XCTAssertNotNil(option)
        XCTAssertEqual(option?.name, "HappyHorse 1.1")
        XCTAssertEqual(option?.requiresImage, false)
        XCTAssertEqual(option?.forcedAudio, true)
    }

    func testFallbackRatesMatchBackendCentsRule() {
        let rates = RatesManager()

        XCTAssertEqual(
            rates.cost(
                model: "alibaba/happyhorse-1.1",
                durationSeconds: 5,
                resolution: "720p",
                hasVideoReference: false
            ),
            70
        )
        XCTAssertEqual(
            rates.cost(
                model: "alibaba/happyhorse-1.1",
                durationSeconds: 5,
                resolution: "1080p",
                hasVideoReference: false
            ),
            90
        )
    }
}
