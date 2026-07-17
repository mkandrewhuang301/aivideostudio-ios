import XCTest
@testable import Fantasia

final class CharacterRegistryTests: XCTestCase {
    func testDecodesClientSafeCharacterResponse() throws {
        let data = Data(
            """
            {
              "version": 1,
              "characters": [{
                "character_id": "nova",
                "name": "Nova",
                "category": "popular",
                "status": "soon",
                "art_url": "https://assets.fantasia.example/characters/nova/card-v1.jpg",
                "bio": "A cinematic adventurer.",
                "voice_label": "Kore — warm, grounded",
                "sort_order": 1
              }]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(CharactersResponse.self, from: data)

        XCTAssertEqual(response.version, 1)
        XCTAssertEqual(response.characters.first?.characterId, "nova")
        XCTAssertEqual(response.characters.first?.categoryTitle, "Popular")
        XCTAssertTrue(response.characters.first?.isSoon == true)
    }

    func testFormatsThreeDimensionalCategoryTitle() throws {
        let data = Data(
            """
            {
              "version": 1,
              "characters": [{
                "character_id": "byte",
                "name": "Byte",
                "category": "3d_generated",
                "status": "soon",
                "art_url": "https://assets.fantasia.example/characters/byte/card-v1.jpg",
                "bio": "A curious robot.",
                "voice_label": "Puck — lively, curious",
                "sort_order": 1
              }]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(CharactersResponse.self, from: data)
        XCTAssertEqual(response.characters.first?.categoryTitle, "3D Generated")
    }
}
