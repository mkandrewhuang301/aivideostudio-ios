// LanguageLessonFormatSheet.swift
// Fantasia
// Server-driven input sheet for the Language Lessons format (format_id "language-lessons").
// Layout per the locked 7/16 design note §10 + 7/18 amendments:
//   template grid (3 big cards + More teaser) → merged prompt box → paired cast+duration row →
//   languages row → Generate bar with live credits.
// This is a standalone view tree like ExplainerFormatSheet — it does NOT share the Generate
// composer, and the frozen-composer rules do not apply here. Everything it renders (templates,
// teachers, languages, duration tiers) comes from the formats registry; placeholder rows carry
// the UI until real art/voice samples land server-side (v1 placeholder principle, D-2/D-4).

import SwiftUI
import AVFoundation

private let lessonAccent = Color(red: 0.545, green: 0.427, blue: 0.839)
private let lessonSelectedTeal = Color(red: 0.369, green: 0.918, blue: 0.831)
private let lessonTemplateTileHeight: CGFloat = 118

// Distinct placeholder gradients per template/art-style/teacher id — same convention as
// ExplainerFormatSheet's `explainerStylePlaceholders`: fallback-only, AsyncImage wins the moment
// real art lands behind the registry URLs.
private let lessonTemplatePlaceholders: [String: [Color]] = [
    "teacher": [Color(red: 0.204, green: 0.596, blue: 0.859), Color(red: 0.298, green: 0.796, blue: 0.643)],
    "cartoon": [Color(red: 0.976, green: 0.451, blue: 0.086), Color(red: 0.996, green: 0.729, blue: 0.153)],
    "mini_drama": [Color(red: 0.945, green: 0.353, blue: 0.588), Color(red: 0.702, green: 0.427, blue: 0.937)],
]

private let lessonArtStylePlaceholders: [String: [Color]] = [
    "doodle": [Color(red: 0.169, green: 0.180, blue: 0.204), Color(red: 0.412, green: 0.427, blue: 0.451)],
    "storybook": [Color(red: 0.867, green: 0.435, blue: 0.404), Color(red: 0.937, green: 0.663, blue: 0.443)],
    "anime": [Color(red: 0.31, green: 0.43, blue: 0.78), Color(red: 0.61, green: 0.38, blue: 0.76)],
    "paper": [Color(red: 0.20, green: 0.57, blue: 0.55), Color(red: 0.28, green: 0.38, blue: 0.72)],
]

struct LanguageLessonFormatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme
    @Environment(GenerationManager.self) private var generationManager
    @Environment(CreditManager.self) private var creditManager

    let format: Format

    @State private var promptText = ""
    @State private var selectedTemplateId: String
    @State private var selectedArtStyleId: String?

    // Remembered defaults (design note 5: rarely-changed choices persist across sessions).
    @AppStorage("lessonTeacherId") private var selectedTeacherId = ""
    @AppStorage("lessonLearningLang") private var learningLanguage = ""
    @AppStorage("lessonSpeakLang") private var speakLanguage = ""
    @AppStorage("lessonDuration") private var selectedDuration = 30

    @State private var showsTeacherPicker = false
    @State private var showsLanguagePicker = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    // Voice sample preview (teacher cards). Placeholder rows ship relative URLs — the ▶ button
    // stays dimmed until a real http(s) sample exists server-side.
    @State private var previewPlayer: AVPlayer?
    @State private var previewingTeacherId: String?

    // Same posture as ExplainerFormatSheet: the affordance ships dark until APIClient exposes a
    // stable enhance method; the lesson flow must never depend on it.
    private let enhanceAvailable = false

    init(format: Format) {
        self.format = format
        _selectedTemplateId = State(initialValue: format.templates.first?.id ?? "")
    }

    // MARK: - Derived selections

    private var selectedTemplate: FormatTemplate? {
        format.templates.first { $0.id == selectedTemplateId } ?? format.templates.first
    }

    private var selectedTeacher: FormatTeacher? {
        format.teachers.first { $0.id == selectedTeacherId } ?? format.teachers.first
    }

    private var selectedTierCredits: Int {
        format.durationTiers.first { $0.seconds == selectedDuration }?.credits ?? 0
    }

    private func languageLabel(_ id: String) -> String {
        format.languages.first { $0.id == id }?.label ?? id
    }

    var body: some View {
        ZStack(alignment: .top) {
            theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    headerSection
                    templateSection
                    artStyleSection
                    promptSection
                    castAndDurationRow
                    languagesRow
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 150)
            }

            HStack {
                Spacer()
                closeButton
            }
            .padding(.top, 8)
            .padding(.trailing, 18)

            VStack(spacing: 0) {
                Spacer()
                generateBar
            }
        }
        .sheet(isPresented: $showsTeacherPicker) {
            teacherPickerSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.background)
        }
        .sheet(isPresented: $showsLanguagePicker) {
            languagePickerSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.background)
        }
        .alert("Couldn't complete that", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .onAppear {
            normalizeRememberedChoices()
        }
        .onDisappear {
            stopVoicePreview()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(format.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .padding(.trailing, 44) // clear the floating close button

            Text(format.sheet.description)
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 34, height: 34)
                .background(theme.surfaceStrong, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Close")
    }

    // MARK: - Template grid (decision 1 — the look, picked by seeing it)

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionCaption("Template")

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ],
                spacing: 12
            ) {
                ForEach(format.templates) { template in
                    templateCell(template)
                }
            }

            // Fast-follow teaser (§1 launch set: Word Pills + Vlog live behind "More ›" later).
            HStack(spacing: 8) {
                Text("More templates")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Text("Word Pills · Vlog")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("SOON")
                    .font(.system(size: 8.5, weight: .heavy))
                    .tracking(0.7)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.surfaceBorder, lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("More templates, Word Pills and Vlog, coming soon")
        }
    }

    private func templateCell(_ template: FormatTemplate) -> some View {
        let isSelected = selectedTemplateId == template.id
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                selectedTemplateId = template.id
                syncArtStyleSelection()
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    Color.clear
                        .overlay {
                            templateArt(template)
                                .allowsHitTesting(false)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 13))

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.78)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                    .clipShape(RoundedRectangle(cornerRadius: 13))

                    Text(template.label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 7)
                        .padding(.bottom, 8)
                }
                .frame(height: lessonTemplateTileHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(isSelected ? lessonSelectedTeal : theme.surfaceBorder, lineWidth: isSelected ? 2.5 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(lessonSelectedTeal, in: Circle())
                            .padding(6)
                    }
                }

                if let blurb = template.blurb {
                    Text(blurb)
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(template.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Cartoon art style (D-4 — full picker in v1, flat-priced look, placeholder presets)

    @ViewBuilder
    private var artStyleSection: some View {
        if let template = selectedTemplate, !template.artStyles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionCaption("Art Style")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(template.artStyles) { style in
                            artStyleCell(style)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private func artStyleCell(_ style: FormatStyle) -> some View {
        let isSelected = selectedArtStyleId == style.id
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedArtStyleId = style.id
            }
        } label: {
            ZStack(alignment: .bottom) {
                Color.clear
                    .overlay {
                        artStyleArt(style)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 13))

                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 13))

                Text(style.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 7)
                    .padding(.bottom, 8)
            }
            .frame(width: 104, height: 88)
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(isSelected ? lessonSelectedTeal : theme.surfaceBorder, lineWidth: isSelected ? 2.5 : 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(style.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Prompt (decision 2 — one free-text box; topic + direction + setting merged)

    private var promptSection: some View {
        ZStack(alignment: .trailing) {
            TextField(
                "",
                text: $promptText,
                prompt: Text("Ordering at a restaurant — polite phrases, set in a Madrid café")
                    .foregroundStyle(theme.textTertiary),
                axis: .vertical
            )
            .font(.body)
            .foregroundStyle(theme.textPrimary)
            .lineLimit(3...6)
            .frame(minHeight: 88, alignment: .topLeading)
            .padding(.trailing, enhanceAvailable ? 36 : 0)

            if enhanceAvailable {
                Button(action: improvePrompt) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(lessonAccent)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Improve prompt")
            }
        }
        .padding(14)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.surfaceBorder, lineWidth: 1)
        )
    }

    // MARK: - Paired row (§10): cast slot + compact duration wheel, equal heights

    private var castAndDurationRow: some View {
        HStack(spacing: 10) {
            castSlot
            durationWheel
        }
    }

    private var castSlot: some View {
        Button { showsTeacherPicker = true } label: {
            HStack(spacing: 10) {
                teacherAvatar(selectedTeacher, diameter: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text((selectedTemplate?.castLabel ?? "Teacher").uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .kerning(0.4)
                        .foregroundStyle(theme.textTertiary)
                    Text(selectedTeacher?.name ?? "Choose")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 2)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(height: 96)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(selectedTemplate?.castLabel ?? "Teacher"), \(selectedTeacher?.name ?? "none chosen")")
        .accessibilityHint("Opens the \(selectedTemplate?.castLabel.lowercased() ?? "teacher") picker")
    }

    /// The mockup's compact wheel rotator — total seconds only; the orchestrator divides scenes
    /// internally and the bill is exactly this total (never per-scene overage).
    private var durationWheel: some View {
        VStack(spacing: 0) {
            Text("DURATION")
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(theme.textTertiary)
                .padding(.top, 8)

            Picker("Duration", selection: $selectedDuration) {
                ForEach(format.durationTiers, id: \.seconds) { tier in
                    Text("\(tier.seconds)s").tag(tier.seconds)
                }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .accessibilityLabel("Duration")
            .accessibilityValue("\(selectedDuration) seconds")
        }
        .frame(width: 104, height: 96)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))
    }

    // MARK: - Languages row (Learning + I speak — speak defaults from locale, never None)

    private var languagesRow: some View {
        Button { showsLanguagePicker = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(lessonAccent)
                    .frame(width: 34, height: 34)
                    .background(lessonAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))

                Text("Learning \(languageLabel(learningLanguage)) · I speak \(languageLabel(speakLanguage))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 2)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Languages, learning \(languageLabel(learningLanguage)), I speak \(languageLabel(speakLanguage))")
        .accessibilityHint("Opens language choices")
    }

    /// Two side-by-side vertical columns with equal-height headers (§1 locked). Neither column
    /// has a None option — "immersion" is a template property (Mini Drama), never a language.
    private var languagePickerSheet: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 10) {
                languageColumn(
                    header: "Learning",
                    selection: learningLanguage,
                    onSelect: setLearningLanguage
                )
                languageColumn(
                    header: "I speak",
                    selection: speakLanguage,
                    onSelect: setSpeakLanguage
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .background(theme.background)
            .navigationTitle("Languages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showsLanguagePicker = false }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(lessonAccent)
                }
            }
        }
    }

    private func languageColumn(
        header: String,
        selection: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header.uppercased())
                .font(.system(size: 11.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(theme.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(format.languages) { language in
                        let isSelected = selection == language.id
                        Button {
                            onSelect(language.id)
                        } label: {
                            HStack {
                                Text(language.label)
                                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Spacer(minLength: 4)
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(lessonAccent)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(isSelected ? lessonAccent.opacity(0.14) : theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11)
                                    .stroke(isSelected ? lessonAccent.opacity(0.6) : theme.surfaceBorder, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Teacher picker (card-based, face + ▶ voice preview, single-select v1 — D-2/D-3)

    private var teacherPickerSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                        ],
                        spacing: 12
                    ) {
                        ForEach(format.teachers) { teacher in
                            teacherCard(teacher)
                        }
                    }

                    // "Your own characters" split — the Cast store integration is a fast-follow;
                    // until then this section is a static placeholder card (D-2).
                    VStack(alignment: .leading, spacing: 10) {
                        sectionCaption("Your Characters")

                        HStack(spacing: 12) {
                            Image(systemName: "person.2.badge.plus")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(lessonAccent)
                                .frame(width: 42, height: 42)
                                .background(lessonAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Your cast lives here")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                Text("Cast your own characters in lessons when the Cast store launches.")
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(theme.background)
            .navigationTitle(selectedTemplate?.castLabel ?? "Teacher")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showsTeacherPicker = false }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(lessonAccent)
                }
            }
        }
        .onDisappear {
            stopVoicePreview()
        }
    }

    private func teacherCard(_ teacher: FormatTeacher) -> some View {
        let isSelected = selectedTeacherId == teacher.id
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedTeacherId = teacher.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                teacherAvatar(teacher, cornerRadius: 13)
                    .frame(maxWidth: .infinity)
                    .frame(height: 132)

                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(teacher.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Text(teacher.voiceLabel)
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)

                    voicePreviewButton(teacher)
                }
            }
            .padding(8)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? lessonSelectedTeal : theme.surfaceBorder, lineWidth: isSelected ? 2.5 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(lessonSelectedTeal, in: Circle())
                        .padding(12)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(teacher.name), voice \(teacher.voiceLabel)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func voicePreviewButton(_ teacher: FormatTeacher) -> some View {
        let playable = voiceSampleURL(for: teacher) != nil
        let isPlaying = previewingTeacherId == teacher.id
        return Button {
            toggleVoicePreview(teacher)
        } label: {
            Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(playable ? lessonAccent : theme.textTertiary)
                .frame(width: 30, height: 30)
                .background(
                    (playable ? lessonAccent.opacity(0.14) : theme.surfaceStrong),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!playable)
        .accessibilityLabel(isPlaying ? "Stop voice preview" : "Play voice preview")
    }

    // MARK: - Generate

    private var generateBar: some View {
        VStack(spacing: 8) {
            if isSubmitting {
                Text(format.sheet.preparingLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }

            Button {
                Task { await generate() }
            } label: {
                ZStack {
                    Group {
                        if isSubmitting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("Generate")
                                .font(.headline.weight(.bold))
                        }
                    }
                    .frame(maxWidth: .infinity)

                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .bold))
                            Text("\(selectedTierCredits)")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(.snappy, value: selectedTierCredits)
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background {
                    if isValid && !isSubmitting {
                        Capsule().fill(LinearGradient.brandPrimary)
                    } else {
                        Capsule().fill(theme.surfaceStrong)
                    }
                }
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!isValid || isSubmitting)
            .accessibilityLabel("Generate, \(selectedTierCredits) credits")
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(
            theme.elevatedBackground
                .shadow(color: .black.opacity(0.12), radius: 12, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var isValid: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedTemplate != nil
            && selectedTeacher != nil
            && !learningLanguage.isEmpty
            && !speakLanguage.isEmpty
    }

    private func generate() async {
        guard isValid,
              let template = selectedTemplate,
              let teacher = selectedTeacher else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        let trimmedPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let artStyleId = template.artStyles.isEmpty ? nil : selectedArtStyleId

        let placeholderId = "local-" + UUID().uuidString
        generationManager.insertLocalPlaceholder(GenerationItem(
            localPlaceholderId: placeholderId,
            model: "",
            mediaType: .video,
            prompt: trimmedPrompt,
            params: GenerationParams(
                resolution: nil,
                duration: selectedDuration,
                aspectRatio: format.defaultAspectRatio,
                audioEnabled: true,
                hasReference: nil,
                width: nil,
                height: nil
            ),
            costCredits: selectedTierCredits,
            referenceUrls: nil,
            createdAt: Date()
        ))

        do {
            let submitted = try await APIClient.shared.submitLessonGeneration(
                formatId: format.formatId,
                templateId: template.id,
                prompt: trimmedPrompt,
                durationSeconds: selectedDuration,
                learningLanguage: learningLanguage,
                speakLanguage: speakLanguage,
                teacherId: teacher.id,
                artStyleId: artStyleId
            )

            generationManager.promoteLocalPlaceholder(
                localId: placeholderId,
                toRealId: submitted.generationId
            )
            generationManager.startPolling(forceRefresh: true)
            await creditManager.fetchBalance()
            NotificationCenter.default.post(name: .generationSubmitted, object: nil)
            dismiss()
        } catch let apiError as APIError {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            if case .unexpectedResponse(_, let code) = apiError, code == "INSUFFICIENT_CREDITS" {
                errorMessage = "Insufficient credits."
                await creditManager.fetchBalance()
            } else if case .unexpectedResponse(_, let code) = apiError,
                      code == "content_policy_violation" {
                errorMessage = "This may not adhere to our community guidelines. Please try again."
            } else if case .unexpectedResponse(_, let code?) = apiError,
                      ["INVALID_FORMAT", "INVALID_TEMPLATE", "INVALID_LANGUAGE",
                       "INVALID_TEACHER", "INVALID_ART_STYLE", "INVALID_DURATION"].contains(code) {
                errorMessage = "One of these format options is no longer available. Reopen the sheet and try again."
            } else {
                errorMessage = "An error has occurred. Please try again."
            }
        } catch {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            errorMessage = "An error has occurred. Please try again."
        }
    }

    // MARK: - Helpers

    private func sectionCaption(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11.5, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(theme.textTertiary)
    }

    /// Seeds remembered choices from the registry on first appear: teacher defaults to the first
    /// roster row, "I speak" defaults from the device locale (never None, fallback English), and
    /// any stale stored id that no longer exists in the registry is reset.
    private func normalizeRememberedChoices() {
        if !format.teachers.contains(where: { $0.id == selectedTeacherId }) {
            selectedTeacherId = format.teachers.first?.id ?? ""
        }
        if !format.languages.contains(where: { $0.id == learningLanguage }) {
            learningLanguage = Self.defaultLearningLanguage(from: format)
        }
        if !format.languages.contains(where: { $0.id == speakLanguage }) {
            speakLanguage = Self.defaultSpeakLanguage(from: format)
        }
        if learningLanguage == speakLanguage {
            speakLanguage = Self.defaultSpeakLanguage(from: format, excluding: learningLanguage)
        }
        if !format.durationTiers.contains(where: { $0.seconds == selectedDuration }) {
            selectedDuration = format.durationTiers.contains(where: { $0.seconds == 30 })
                ? 30
                : (format.durationTiers.first?.seconds ?? 30)
        }
        syncArtStyleSelection()
    }

    /// Keeps the art-style selection valid for the newly selected template: first style of the
    /// template's list, or nil when the template has no art picker (Teacher/Mini Drama).
    private func syncArtStyleSelection() {
        let styles = selectedTemplate?.artStyles ?? []
        if styles.isEmpty {
            selectedArtStyleId = nil
        } else if !styles.contains(where: { $0.id == selectedArtStyleId }) {
            selectedArtStyleId = styles.first?.id
        }
    }

    /// Language-pair swap guard: picking the language the other column already holds swaps the
    /// two, so Learning and I speak can never end up equal.
    private func setLearningLanguage(_ id: String) {
        if id == speakLanguage {
            speakLanguage = learningLanguage
        }
        learningLanguage = id
    }

    private func setSpeakLanguage(_ id: String) {
        if id == learningLanguage {
            learningLanguage = speakLanguage
        }
        speakLanguage = id
    }

    static func defaultLearningLanguage(from format: Format) -> String {
        if format.languages.contains(where: { $0.id == "es" }) { return "es" }
        return format.languages.first?.id ?? ""
    }

    static func defaultSpeakLanguage(from format: Format, excluding excludedId: String? = nil) -> String {
        let available = format.languages.filter { $0.id != excludedId }
        let locale = Locale.current
        let baseCode = locale.language.languageCode?.identifier ?? "en"

        // Chinese needs the script to pick between zh-Hans / zh-Hant.
        if baseCode == "zh" {
            let script = locale.language.script?.identifier
            let zhId = script == "Hant" ? "zh-Hant" : "zh-Hans"
            if available.contains(where: { $0.id == zhId }) { return zhId }
        }
        if let exact = available.first(where: { $0.id == baseCode }) {
            return exact.id
        }
        // Regional ids ("pt-BR" style) fall back to their base code.
        if let prefixMatch = available.first(where: { $0.id.hasPrefix(baseCode + "-") || baseCode.hasPrefix($0.id + "-") }) {
            return prefixMatch.id
        }
        if let english = available.first(where: { $0.id == "en" }) {
            return english.id
        }
        return available.first?.id ?? ""
    }

    private func templateArt(_ template: FormatTemplate) -> some View {
        placeholderArt(
            urlString: template.thumbUrl,
            colors: lessonTemplatePlaceholders[template.id]
                ?? [lessonAccent.opacity(0.8), Color(red: 0.357, green: 0.561, blue: 0.851).opacity(0.75)]
        )
    }

    private func artStyleArt(_ style: FormatStyle) -> some View {
        placeholderArt(
            urlString: style.thumbUrl,
            colors: lessonArtStylePlaceholders[style.id]
                ?? [lessonAccent.opacity(0.8), Color(red: 0.357, green: 0.561, blue: 0.851).opacity(0.75)]
        )
    }

    private func placeholderArt(urlString: String?, colors: [Color]) -> some View {
        let fallback = LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        return Group {
            if let urlString,
               let url = URL(string: urlString),
               let scheme = url.scheme?.lowercased(),
               scheme == "https" || scheme == "http" {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
    }

    /// Teacher face art: real art via AsyncImage when the registry ships an http(s) URL,
    /// otherwise a person-glyph gradient placeholder (CastView's CharacterArtView idiom).
    private func teacherAvatar(_ teacher: FormatTeacher?, diameter: CGFloat) -> some View {
        teacherAvatarContent(teacher)
            .frame(width: diameter, height: diameter)
            .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private func teacherAvatar(_ teacher: FormatTeacher?, cornerRadius: CGFloat) -> some View {
        teacherAvatarContent(teacher)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private func teacherAvatarContent(_ teacher: FormatTeacher?) -> some View {
        let placeholder = LinearGradient(
            colors: [Color(red: 0.60, green: 0.34, blue: 0.66), Color(red: 0.32, green: 0.36, blue: 0.72)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "person.crop.square.fill")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.68))
        }

        return Group {
            if let raw = teacher?.artUrl,
               let url = URL(string: raw),
               let scheme = url.scheme?.lowercased(),
               scheme == "https" || scheme == "http" {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
    }

    // MARK: - Voice preview

    private func voiceSampleURL(for teacher: FormatTeacher) -> URL? {
        guard let raw = teacher.voiceSampleUrl,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    private func toggleVoicePreview(_ teacher: FormatTeacher) {
        if previewingTeacherId == teacher.id {
            stopVoicePreview()
            return
        }
        guard let url = voiceSampleURL(for: teacher) else { return }
        previewPlayer?.pause()
        let player = AVPlayer(url: url)
        previewPlayer = player
        previewingTeacherId = teacher.id
        player.play()
    }

    private func stopVoicePreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        previewingTeacherId = nil
    }

    private func improvePrompt() {
        // Unreachable while enhanceAvailable is false. The optional sibling feature owns the API.
    }
}

// Canvas preview decodes a trimmed registry row so the sheet renders with realistic placeholder
// data without a network fetch (the bundled formats.json fallback carries the full row).
private extension Format {
    static var languageLessonPreview: Format {
        let json = """
        {
          "format_id": "language-lessons",
          "title": "Language Lessons",
          "subtitle": "Short visual lessons that make a new language stick",
          "section": "formats",
          "badge": "NEW",
          "sort_order": 30,
          "status": "live",
          "tile": {},
          "templates": [
            { "id": "teacher", "label": "Teacher", "blurb": "A friendly teacher breaks it down",
              "thumb_url": "", "cast_label": "Teacher" },
            { "id": "cartoon", "label": "Cartoon", "blurb": "Slow, simple cartoon dialogue",
              "thumb_url": "", "cast_label": "Characters",
              "art_styles": [
                { "id": "doodle", "label": "Doodle", "thumb_url": "" },
                { "id": "storybook", "label": "Storybook", "thumb_url": "" },
                { "id": "anime", "label": "Anime", "thumb_url": "" },
                { "id": "paper", "label": "Paper", "thumb_url": "" }
              ] },
            { "id": "mini_drama", "label": "Mini Drama", "blurb": "Immersive scenes, natural speed",
              "thumb_url": "", "cast_label": "Characters" }
          ],
          "teachers": [
            { "id": "marisol", "name": "Marisol", "voice_label": "Warm · Female" },
            { "id": "leo", "name": "Leo", "voice_label": "Friendly · Male" },
            { "id": "sofia", "name": "Sofia", "voice_label": "Bright · Female" },
            { "id": "kenji", "name": "Kenji", "voice_label": "Calm · Male" }
          ],
          "languages": [
            { "id": "en", "label": "English" },
            { "id": "es", "label": "Spanish" },
            { "id": "zh-Hans", "label": "Chinese (Simplified)" },
            { "id": "zh-Hant", "label": "Chinese (Traditional)" },
            { "id": "ja", "label": "Japanese" },
            { "id": "ko", "label": "Korean" }
          ],
          "duration_tiers": [
            { "seconds": 15, "scene_count": 2, "credits": 245 },
            { "seconds": 30, "scene_count": 4, "credits": 470 },
            { "seconds": 60, "scene_count": 9, "credits": 930 }
          ],
          "aspect_ratios": ["9:16"],
          "sheet": {
            "description": "Pick a template, a teacher, and a topic — get a short lesson that sticks.",
            "preparing_label": "Writing your lesson…"
          }
        }
        """
        // Force-try is safe: this literal is compile-time constant and exercised by every canvas.
        return try! JSONDecoder().decode(Format.self, from: Data(json.utf8))
    }
}

#Preview {
    LanguageLessonFormatSheet(format: .languageLessonPreview)
        .environment(ThemeManager())
        .environment(GenerationManager())
        .environment(CreditManager())
}
