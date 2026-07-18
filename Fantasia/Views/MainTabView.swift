// MainTabView.swift
// Fantasia
// Custom tab bar: Home + Studio + elevated Create + Cast + Library.

import SwiftUI

struct MainTabView: View {
    @Environment(CreditManager.self) private var creditManager
    @Environment(AuthManager.self) private var authManager
    @Environment(GenerationManager.self) private var generationManager
    @Environment(ThemeManager.self) private var theme
    @State private var selectedTab = 2   // open on Create by default
    @State private var showProfileSheet = false
    @State private var drawer = DrawerManager()
    @State private var browsePath: [String] = []
    @State private var selectedPreset: Preset?
    @State private var selectedFormat: Format?
    // SC2: first-use face-input consent hard gate. Local mirror of the server's authoritative
    // `has_face_consent` flag (T-09.2-21 — server also enforces this; the flag here is UX only).
    @AppStorage("hasFaceConsent") private var hasFaceConsent = false
    @State private var pendingFacePreset: Preset?
    // Magic Editor (09.2-10, SC4): the Home "Magic Editor" card routes to MaskEditorView (source
    // photo picker mode) instead of PresetInputSheet — its schema-driven slot UI doesn't apply to
    // a freehand mask paint. Preset identity only drives presentation; MaskEditorView.Source.pick
    // starts its own PhotosPicker.
    @State private var magicEditorPreset: Preset?

    /// Face-input presets require the one-time consent attestation before their PresetInputSheet
    /// ever opens — faceswap and motion-transfer ("avatar") both animate/composite an uploaded face.
    private func isFaceInput(_ preset: Preset) -> Bool {
        preset.mediaType == "faceswap" || preset.mediaType == "avatar"
    }

    /// Single preset-tap route shared by Home and every registry category.
    private func selectPreset(_ preset: Preset) {
        if preset.presetId == "magic-editor" {
            magicEditorPreset = preset
        } else if isFaceInput(preset) && !hasFaceConsent {
            pendingFacePreset = preset
        } else {
            selectedPreset = preset
        }
    }

    private let tabBarHeight: CGFloat = 74
    private let bottomLift: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let drawerWidth = geo.size.width * 0.65

            ZStack(alignment: .bottom) {
                TabView(selection: $selectedTab) {
                    // Home owns the browse NavigationStack: wrapping only this tab (not the whole
                    // TabView) avoids the documented SwiftUI anti-pattern of a NavigationStack
                    // ancestor around a TabView whose tabs also nest their own stacks — that
                    // combo throws AnyNavigationPath.Error.comparisonTypeMismatch on push.
                    NavigationStack(path: $browsePath) {
                        HomeView(
                            onNavigateToGenerate: { selectedTab = 2 },
                            onSelectPreset: selectPreset,
                            onSelectCategory: { browsePath.append($0) },
                            onSelectFormat: { selectedFormat = $0 }
                        )
                        .safeAreaInset(edge: .top, spacing: 0) { topBar() }
                        .navigationDestination(for: String.self) { section in
                            CategoryView(
                                section: section,
                                onSelectPreset: selectPreset,
                                onSelectFormat: { selectedFormat = $0 }
                            )
                        }
                    }
                    .toolbar(.hidden, for: .tabBar)
                    .tag(0)
                    NavigationStack { StudioHubView() }
                        .toolbar(.hidden, for: .tabBar)
                        .tag(1)
                    NavigationStack { GenerateView() }
                        .toolbar(.hidden, for: .tabBar)
                        .tag(2)
                    // Cast never pushes/shows a nav bar (sheet-only) — left bare, no stack needed.
                    CastView()
                        .safeAreaInset(edge: .top, spacing: 0) { topBar() }
                        .toolbar(.hidden, for: .tabBar)
                        .tag(3)
                    // Library sets .navigationTitle, so it needs its own stack now that the
                    // ancestor NavigationStack is gone.
                    NavigationStack {
                        LibraryView()
                            .safeAreaInset(edge: .top, spacing: 0) { topBar(compact: true) }
                    }
                    .toolbar(.hidden, for: .tabBar)
                    .tag(4)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: tabBarHeight + bottomLift)
                }

                customTabBar
                    .padding(.bottom, bottomLift)

                // T16: was a plain recessedBackground fill, which reads as a darker band under
                // the (lighter) tab bar — same fill recipe as customTabBar's own background
                // Rectangle so the bar and this under-bar strip read as one continuous surface.
                Rectangle()
                    .fill(theme.recessedBackground.opacity(0.9))
                    .background(.regularMaterial)
                    .frame(height: bottomLift)
                    .ignoresSafeArea(edges: .bottom)
            }
            // Dim overlay
            .overlay {
                Color.black.opacity(drawer.isOpen ? 0.5 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(drawer.isOpen)
                    .onTapGesture { drawer.close() }
                    .animation(.easeInOut(duration: 0.22), value: drawer.isOpen)
            }
            // Side drawer
            .overlay(alignment: .leading) {
                SideDrawerView { section in
                    selectedTab = 0   // jump to Home first — browse always opens there
                    browsePath.append(section)
                }
                .environment(drawer)
                .environment(creditManager)
                .environment(authManager)
                .environment(theme)
                .frame(width: drawerWidth)
                .ignoresSafeArea()
                .offset(x: drawer.isOpen ? 0 : -drawerWidth)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: drawer.isOpen)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .environment(drawer)
        .onReceive(NotificationCenter.default.publisher(for: .remixGenerationRequested)) { _ in
            selectedTab = 2
        }
        .onReceive(NotificationCenter.default.publisher(for: .referenceGenerationRequested)) { _ in
            selectedTab = 2
        }
        // D-D (09.2-13): any preset submit redirects to the Generate feed so the loading card shows.
        // Also close the Magic Editor cover here (it no longer self-dismisses — presenter-driven
        // close avoids a double-dismiss bounce; no-op for other presets whose item is already nil).
        .onReceive(NotificationCenter.default.publisher(for: .generationSubmitted)) { _ in
            magicEditorPreset = nil
            selectedTab = 2
        }
        .nameAsReferenceAlert()
        .sheet(isPresented: $showProfileSheet) {
            ProfileCreditSheet(isPresented: $showProfileSheet)
                .environment(creditManager)
                .environment(authManager)
                .presentationDetents([.fraction(0.62)])
                .presentationDragIndicator(.hidden)
        }
        // .sheet (not .fullScreenCover) so it swipe-down-dismisses like the generation detail
        // pullup (GenerationDetailPagerView) — user request 2026-07-08.
        .sheet(item: $selectedPreset) { preset in
            PresetInputSheet(preset: preset)
                .environment(creditManager)
                .environment(generationManager)
                .environment(theme)
                .presentationBackground(theme.background)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        .sheet(item: $selectedFormat) { format in
            ExplainerFormatSheet(format: format)
                .presentationBackground(theme.background)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        // Magic Editor (09.2-10, SC4): "pick a source photo" mode — MaskEditorView owns its own
        // PhotosPicker + paint canvas, unlike every other preset's schema-driven PresetInputSheet.
        .fullScreenCover(item: $magicEditorPreset) { _ in
            MaskEditorView(source: .pick)
                .environment(creditManager)
                .environment(generationManager)
                .environment(theme)
        }
        // SC2: first-use face-input consent hard gate — shown once per user in front of
        // faceswap/motion-transfer presets (see isFaceInput/onSelectPreset above).
        .fullScreenCover(item: $pendingFacePreset) { preset in
            ConsentAttestationView(
                onAgree: {
                    try? await APIClient.shared.updateConsent()
                    hasFaceConsent = true
                    pendingFacePreset = nil
                    selectedPreset = preset   // proceed into the preset sheet
                },
                onCancel: { pendingFacePreset = nil }
            )
            .environment(theme)
        }
        .task {
            // Best-effort sync of server truth on launch, so consent granted on another device
            // (or a prior install) is respected without re-prompting.
            if let me = try? await APIClient.shared.fetchMe() {
                hasFaceConsent = me.hasFaceConsent
            }
        }
    }

    // MARK: - Shared top bar (used by all non-Generate tabs)

    // The bar itself (icons, logo, title, credit ring, tap targets) is identical everywhere —
    // Home, Generate, and Library must look the same. `compact` ONLY trims the vertical padding
    // for Library, whose date-header grid sits directly under the bar and otherwise reads as an
    // oversized gap above the first date row. It must never shrink the controls.
    private func topBar(compact: Bool = false) -> some View {
        let topPad: CGFloat = compact ? 0 : 2
        let bottomPad: CGFloat = compact ? 4 : 10

        return HStack(alignment: .center, spacing: 11) {
            Button { drawer.open() } label: {
                VStack(spacing: 5) {
                    Rectangle().frame(width: 22, height: 2)
                    Rectangle().frame(width: 22, height: 2)
                    Rectangle().frame(width: 22, height: 2)
                }
                .foregroundStyle(theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Image("LogoMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                Text("Fantasia")
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .kerning(-0.16)
            }

            Spacer()

            Button { showProfileSheet = true } label: {
                CircularCreditIndicator(fillRatio: creditManager.fillRatio, size: 32)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Credits — tap to manage")
        }
        .padding(.horizontal, 18)
        .padding(.top, topPad)
        .padding(.bottom, bottomPad)
        .background(theme.elevatedBackground.ignoresSafeArea(edges: .top))
    }

    // MARK: - Custom tab bar

    private var customTabBar: some View {
        GeometryReader { geo in
            let slotWidth = geo.size.width / 5
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(theme.recessedBackground.opacity(0.9))
                    .background(.regularMaterial)
                    .frame(height: tabBarHeight)

                HStack(spacing: 0) {
                    tabButton(0, "Home", "house").frame(width: slotWidth)
                    tabButton(1, "Studio", "slider.horizontal.3").frame(width: slotWidth)
                    Color.clear.frame(width: slotWidth)
                    tabButton(3, "Cast", "person.2").frame(width: slotWidth)
                    tabButton(4, "Library", "square.grid.2x2").frame(width: slotWidth)
                }
                .frame(height: tabBarHeight)

                // Separate all five destinations consistently while keeping the dividers subtle.
                ForEach(1..<5, id: \.self) { boundary in
                    Rectangle()
                        .fill(theme.textTertiary)
                        .frame(width: 0.5, height: 36)
                        .position(
                            x: slotWidth * CGFloat(boundary),
                            y: tabBarHeight / 2
                        )
                        .allowsHitTesting(false)
                }

                VStack {
                    Spacer()
                    Text("Create")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(selectedTab == 2 ? theme.textPrimary : theme.textTertiary)
                        .padding(.bottom, 7)
                }
                .frame(height: tabBarHeight)

                HStack {
                    Spacer()
                    Button { selectedTab = 2 } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 13)
                                .fill(LinearGradient(
                                    colors: [Color(red: 0.608, green: 0.490, blue: 0.906),
                                             Color(red: 0.416, green: 0.561, blue: 0.878)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ))
                                .frame(width: 42, height: 42)
                                .overlay(RoundedRectangle(cornerRadius: 13)
                                    .stroke(Color.white.opacity(0.25), lineWidth: 1.5))
                                .shadow(color: Color(red: 0.47, green: 0.39, blue: 0.90).opacity(0.45), radius: 8, x: 0, y: 4)
                                .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1)
                                .rotationEffect(.degrees(45))
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 54, height: 54)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Create")
                    Spacer()
                }
                .offset(y: -14)
            }
        }
        .frame(height: tabBarHeight)
    }

    private func tabButton(_ index: Int, _ label: String, _ icon: String) -> some View {
        Button { selectedTab = index } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 20, height: 20)
                Text(label)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(selectedTab == index ? theme.textPrimary : theme.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: tabBarHeight)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MainTabView()
        .environment(CreditManager())
        .environment(AuthManager())
        .environment(GenerationManager())
        .environment(MediaLibraryManager())
        .environment(ProjectManager())
        .environment(CharacterRegistryManager())
        .environment(ThemeManager())
}
