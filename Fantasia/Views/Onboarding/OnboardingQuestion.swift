// OnboardingQuestion.swift
// Fantasia
// Data models for the 4-question bubble-picker onboarding flow.
// Q4 is conditional on the Q2 selection per CONTEXT.md branching rules.

import Foundation

struct OnboardingOption: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let icon: String // SF Symbol name
}

struct OnboardingQuestion: Identifiable {
    let id: String // stable key used as the answer dictionary key, e.g. "familiarity"
    let prompt: String
    let options: [OnboardingOption]
}

enum OnboardingQuestionBank {
    static let q1 = OnboardingQuestion(
        id: "familiarity",
        prompt: "How familiar are you with AI tools?",
        options: [
            OnboardingOption(label: "Just starting out", icon: "sparkles"),
            OnboardingOption(label: "Some experience", icon: "wand.and.stars"),
            OnboardingOption(label: "Pretty familiar", icon: "slider.horizontal.3"),
            OnboardingOption(label: "Power user", icon: "bolt.fill"),
        ]
    )

    static let q2 = OnboardingQuestion(
        id: "useCase",
        prompt: "What are you using this for?",
        options: [
            OnboardingOption(label: "Create for fun", icon: "face.smiling"),
            OnboardingOption(label: "Social media", icon: "bubble.left.and.bubble.right.fill"),
            OnboardingOption(label: "AI influencer/UGC", icon: "person.fill.viewfinder"),
            OnboardingOption(label: "Cinematic/filmmaking", icon: "film.fill"),
            OnboardingOption(label: "Video editing", icon: "scissors"),
        ]
    )

    static let q3 = OnboardingQuestion(
        id: "style",
        prompt: "What style do you like?",
        options: [
            OnboardingOption(label: "Photorealistic", icon: "camera.fill"),
            OnboardingOption(label: "Anime", icon: "eye.fill"),
            OnboardingOption(label: "3D Animation", icon: "cube.fill"),
            OnboardingOption(label: "Cartoon", icon: "paintbrush.fill"),
        ]
    )

    /// Q4 is conditional on the Q2 selection. Per CONTEXT.md:
    /// - "Social media" -> platform question
    /// - "AI influencer/UGC" -> content type question
    /// - "Cinematic/filmmaking" -> scene type question
    /// - "Create for fun" / "Video editing" / no Q2 selection -> generic inspiration question
    static func conditionalQuestion(for q2Selections: Set<String>) -> OnboardingQuestion {
        if q2Selections.contains("Social media") {
            return OnboardingQuestion(
                id: "conditional",
                prompt: "Which platform?",
                options: [
                    OnboardingOption(label: "TikTok", icon: "music.note"),
                    OnboardingOption(label: "Instagram", icon: "camera.fill"),
                    OnboardingOption(label: "YouTube", icon: "play.rectangle.fill"),
                    OnboardingOption(label: "X", icon: "bird.fill"),
                ]
            )
        } else if q2Selections.contains("AI influencer/UGC") {
            return OnboardingQuestion(
                id: "conditional",
                prompt: "What kind of content?",
                options: [
                    OnboardingOption(label: "Brand deals", icon: "tag.fill"),
                    OnboardingOption(label: "Personal brand", icon: "person.fill"),
                    OnboardingOption(label: "Memes & trends", icon: "flame.fill"),
                    OnboardingOption(label: "All of it", icon: "infinity"),
                ]
            )
        } else if q2Selections.contains("Cinematic/filmmaking") {
            return OnboardingQuestion(
                id: "conditional",
                prompt: "What kind of scenes?",
                options: [
                    OnboardingOption(label: "Action", icon: "flame.fill"),
                    OnboardingOption(label: "Drama", icon: "theatermasks.fill"),
                    OnboardingOption(label: "Fantasy", icon: "wand.and.stars"),
                    OnboardingOption(label: "Sci-fi", icon: "atom"),
                ]
            )
        } else {
            // "Create for fun" / "Video editing" / Q2 skipped entirely
            return OnboardingQuestion(
                id: "conditional",
                prompt: "What inspires you?",
                options: [
                    OnboardingOption(label: "Movies & TV", icon: "tv.fill"),
                    OnboardingOption(label: "Music videos", icon: "music.note.list"),
                    OnboardingOption(label: "Social media", icon: "bubble.left.and.bubble.right.fill"),
                    OnboardingOption(label: "Just my imagination", icon: "sparkles"),
                ]
            )
        }
    }
}
