// OnboardingQuestionBankTests.swift
// FantasiaTests
// Unit tests for OnboardingQuestionBank static questions and conditionalQuestion(for:) branching logic.

import XCTest
@testable import Fantasia

final class OnboardingQuestionBankTests: XCTestCase {

    // MARK: - Static question structure

    func testQ1HasFourOptions() {
        XCTAssertEqual(OnboardingQuestionBank.q1.options.count, 4)
    }

    func testQ2HasFiveOptions() {
        XCTAssertEqual(OnboardingQuestionBank.q2.options.count, 5)
    }

    func testQ3HasFourOptions() {
        XCTAssertEqual(OnboardingQuestionBank.q3.options.count, 4)
    }

    func testQuestionIdsAreStable() {
        XCTAssertEqual(OnboardingQuestionBank.q1.id, "familiarity")
        XCTAssertEqual(OnboardingQuestionBank.q2.id, "useCase")
        XCTAssertEqual(OnboardingQuestionBank.q3.id, "style")
    }

    func testAllOptionsHaveNonEmptyLabelsAndIcons() {
        let allStaticQuestions = [
            OnboardingQuestionBank.q1,
            OnboardingQuestionBank.q2,
            OnboardingQuestionBank.q3,
        ]
        for question in allStaticQuestions {
            for option in question.options {
                XCTAssertFalse(option.label.isEmpty,
                    "Option in \(question.id) has empty label")
                XCTAssertFalse(option.icon.isEmpty,
                    "Option '\(option.label)' in \(question.id) has empty icon")
            }
        }
    }

    // MARK: - conditionalQuestion(for:) — single-branch triggers

    func testConditionalQ4WithSocialMedia_returnsPlatformQuestion() {
        let q4 = OnboardingQuestionBank.conditionalQuestion(for: ["Social media"])
        XCTAssertEqual(q4.prompt, "Which platform?")
        let labels = q4.options.map(\.label)
        XCTAssertTrue(labels.contains("TikTok"), "Expected TikTok in platform options")
        XCTAssertTrue(labels.contains("Instagram"))
        XCTAssertTrue(labels.contains("YouTube"))
        XCTAssertTrue(labels.contains("X"))
    }

    func testConditionalQ4WithAIInfluencer_returnsContentTypeQuestion() {
        let q4 = OnboardingQuestionBank.conditionalQuestion(for: ["AI influencer/UGC"])
        XCTAssertEqual(q4.prompt, "What kind of content?")
        let labels = q4.options.map(\.label)
        XCTAssertTrue(labels.contains("Brand deals"))
        XCTAssertTrue(labels.contains("Personal brand"))
        XCTAssertTrue(labels.contains("Memes & trends"))
        XCTAssertTrue(labels.contains("All of it"))
    }

    func testConditionalQ4WithCinematic_returnsScenesQuestion() {
        let q4 = OnboardingQuestionBank.conditionalQuestion(for: ["Cinematic/filmmaking"])
        XCTAssertEqual(q4.prompt, "What kind of scenes?")
        let labels = q4.options.map(\.label)
        XCTAssertTrue(labels.contains("Action"))
        XCTAssertTrue(labels.contains("Drama"))
        XCTAssertTrue(labels.contains("Fantasy"))
        XCTAssertTrue(labels.contains("Sci-fi"))
    }

    func testConditionalQ4WithCreateForFun_returnsInspirationQuestion() {
        let q4 = OnboardingQuestionBank.conditionalQuestion(for: ["Create for fun"])
        XCTAssertEqual(q4.prompt, "What inspires you?")
    }

    func testConditionalQ4WithVideoEditing_returnsInspirationQuestion() {
        let q4 = OnboardingQuestionBank.conditionalQuestion(for: ["Video editing"])
        XCTAssertEqual(q4.prompt, "What inspires you?")
    }

    func testConditionalQ4WithEmptySet_returnsInspirationQuestion() {
        let q4 = OnboardingQuestionBank.conditionalQuestion(for: [])
        XCTAssertEqual(q4.prompt, "What inspires you?")
    }

    func testConditionalQ4WithUnknownValue_returnsInspirationQuestion() {
        let q4 = OnboardingQuestionBank.conditionalQuestion(for: ["Something entirely unknown"])
        XCTAssertEqual(q4.prompt, "What inspires you?")
    }

    // MARK: - Priority ordering

    func testConditionalQ4PriorityWithSocialMediaAndInfluencer_returnsSocialMediaBranch() {
        // "Social media" is checked before "AI influencer/UGC" in the implementation.
        // If both are selected, Social media wins.
        let q4 = OnboardingQuestionBank.conditionalQuestion(for: ["Social media", "AI influencer/UGC"])
        XCTAssertEqual(q4.prompt, "Which platform?",
            "Social media branch should win when both Social media and AI influencer/UGC are selected")
    }

    func testConditionalQ4PriorityWithSocialMediaAndCinematic_returnsSocialMediaBranch() {
        let q4 = OnboardingQuestionBank.conditionalQuestion(for: ["Social media", "Cinematic/filmmaking"])
        XCTAssertEqual(q4.prompt, "Which platform?")
    }

    func testConditionalQ4PriorityWithInfluencerAndCinematic_returnsInfluencerBranch() {
        // "AI influencer/UGC" is checked before "Cinematic/filmmaking".
        let q4 = OnboardingQuestionBank.conditionalQuestion(for: ["AI influencer/UGC", "Cinematic/filmmaking"])
        XCTAssertEqual(q4.prompt, "What kind of content?",
            "AI influencer/UGC branch should win when both AI influencer/UGC and Cinematic/filmmaking are selected")
    }

    // MARK: - Stable id for all branches

    func testConditionalQ4HasStableConditionalId() {
        let allBranchInputs: [Set<String>] = [
            ["Social media"],
            ["AI influencer/UGC"],
            ["Cinematic/filmmaking"],
            ["Create for fun"],
            [],
        ]
        for input in allBranchInputs {
            let q4 = OnboardingQuestionBank.conditionalQuestion(for: input)
            XCTAssertEqual(q4.id, "conditional",
                "All Q4 branches must return id == 'conditional', got '\(q4.id)' for input \(input)")
        }
    }

    // MARK: - Options integrity for conditional branches

    func testConditionalQ4AllBranchOptionsHaveNonEmptyLabelsAndIcons() {
        let allBranchInputs: [Set<String>] = [
            ["Social media"],
            ["AI influencer/UGC"],
            ["Cinematic/filmmaking"],
            ["Create for fun"],
            [],
        ]
        for input in allBranchInputs {
            let q4 = OnboardingQuestionBank.conditionalQuestion(for: input)
            for option in q4.options {
                XCTAssertFalse(option.label.isEmpty,
                    "Conditional Q4 for \(input) has empty label")
                XCTAssertFalse(option.icon.isEmpty,
                    "Conditional Q4 option '\(option.label)' for \(input) has empty icon")
            }
        }
    }

    func testConditionalQ4AllBranchesHaveFourOptions() {
        let allBranchInputs: [Set<String>] = [
            ["Social media"],
            ["AI influencer/UGC"],
            ["Cinematic/filmmaking"],
            ["Create for fun"],
            [],
        ]
        for input in allBranchInputs {
            let q4 = OnboardingQuestionBank.conditionalQuestion(for: input)
            XCTAssertEqual(q4.options.count, 4,
                "Conditional Q4 for \(input) should have 4 options, got \(q4.options.count)")
        }
    }
}
