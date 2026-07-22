import XCTest
@testable import Fantasia

final class PresetCostTests: XCTestCase {
    func testDecodesAndReencodesFrameMeteredCost() throws {
        let json = Data(#"{"type":"per_30_frames","credits_per_unit":3}"#.utf8)

        let decoded = try JSONDecoder().decode(PresetCost.self, from: json)
        XCTAssertEqual(decoded, .per30Frames(creditsPerUnit: 3))

        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "per_30_frames")
        XCTAssertEqual(object["credits_per_unit"] as? Int, 3)
    }

    func testExistingCostShapesRemainCompatible() throws {
        let flat = try JSONDecoder().decode(
            PresetCost.self,
            from: Data(#"{"type":"flat","credits":2}"#.utf8)
        )
        let perSecond = try JSONDecoder().decode(
            PresetCost.self,
            from: Data(#"{"type":"per_second","credits_per_sec":5,"max_seconds":30}"#.utf8)
        )

        XCTAssertEqual(flat, .flat(credits: 2))
        XCTAssertEqual(perSecond, .perSecond(creditsPerSec: 5, maxSeconds: 30))
    }

    func testPresetGenerationRequestEncodesSelectedStyle() throws {
        var request = GenerationRequestBody(
            prompt: "",
            model: "",
            mediaType: "image",
            duration: nil,
            resolution: nil,
            aspectRatio: nil,
            audioEnabled: nil,
            imageAspectRatio: "1:1",
            imageQuality: nil,
            referenceImages: nil,
            referenceVideos: nil,
            referenceUploadIds: nil,
            referenceImageUploadIds: nil,
            referenceVideoUploadIds: nil,
            referenceImageGenerationIds: nil,
            referenceVideoGenerationIds: nil,
            presetId: "hairstyle",
            presetInputUploadIds: ["upload-photo"]
        )
        request.styleId = "bob"

        let encoded = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["preset_id"] as? String, "hairstyle")
        XCTAssertEqual(object["style_id"] as? String, "bob")
    }

    func testGenerationParamsDecodesPresetReplayChoices() throws {
        let json = Data(
            #"{"preset_id":"hairstyle","preset_input_upload_ids":["upload-photo"],"style_id":"bob","aspect_ratio":"2:3"}"#.utf8
        )

        let params = try JSONDecoder().decode(GenerationParams.self, from: json)
        XCTAssertEqual(params.presetId, "hairstyle")
        XCTAssertEqual(params.presetInputUploadIds, ["upload-photo"])
        XCTAssertEqual(params.styleId, "bob")
        XCTAssertEqual(params.aspectRatio, "2:3")
    }
}
