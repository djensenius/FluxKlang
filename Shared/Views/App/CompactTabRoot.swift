import SwiftUI
#if os(iOS)
import UIKit

struct CompactTabRoot: View {
    @Environment(AppModel.self) private var appModel
    let window: WindowID
    let newProject: () -> Void
    @State private var selectedTab = CompactTab.studio
    @State private var morePath: [AppSection] = []
    @State private var isShowingConnection = false
    @State private var isKeyboardVisible = false
    @State private var composerIsFocused = false
    @State private var showsKeyboardNavigation = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                SectionDetail(section: .studio, window: window, newProject: newProject)
            }
            .toolbar(showsKeyboardNavigation ? .hidden : .automatic, for: .tabBar)
            .tabItem { Label("Studio", systemImage: AppSection.studio.systemImage) }
            .tag(CompactTab.studio)

            NavigationStack {
                SectionDetail(section: .assistant, window: window, newProject: newProject)
            }
            .toolbar(showsKeyboardNavigation ? .hidden : .automatic, for: .tabBar)
            .tabItem { Label("Assistant", systemImage: AppSection.assistant.systemImage) }
            .tag(CompactTab.assistant)

            NavigationStack {
                MixView()
            }
            .toolbar(showsKeyboardNavigation ? .hidden : .automatic, for: .tabBar)
            .tabItem { Label("Mix", systemImage: AppSection.mix.systemImage) }
            .tag(CompactTab.mix)

            NavigationStack(path: $morePath) {
                MoreView(window: window, newProject: newProject)
            }
            .toolbar(showsKeyboardNavigation ? .hidden : .automatic, for: .tabBar)
            .tabItem { Label("More", systemImage: "ellipsis.circle") }
            .tag(CompactTab.more)
        }
        // Avoid racing the native tab-bar visibility animation against keyboard/tab transitions.
        .transaction(value: showsKeyboardNavigation) {
            $0.animation = nil
            $0.disablesAnimations = true
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !showsKeyboardNavigation {
                ConnectionStatusButton { isShowingConnection = true }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
        .environment(
            \.compactKeyboardNavigation,
            showsKeyboardNavigation ? CompactKeyboardNavigation(selectedTab: $selectedTab) : nil
        )
        .onPreferenceChange(AssistantComposerFocusKey.self) { focused in
            composerIsFocused = focused
            if focused && isKeyboardVisible { showsKeyboardNavigation = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
            if composerIsFocused { showsKeyboardNavigation = true }
        }
        // Keep navigation reachable until dismissal completes, including canceled interactive swipes.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            isKeyboardVisible = false
            showsKeyboardNavigation = false
        }
        .sheet(isPresented: $isShowingConnection) {
            NavigationStack {
                ConnectionView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingConnection = false }
                        }
                    }
            }
        }
        .onAppear { synchronizeSelection(appModel.section) }
        .onChange(of: appModel.section) { _, section in
            synchronizeSelection(section)
        }
        .onChange(of: morePath) { previous, path in
            appModel.section = appModel.section.updatingCompactMorePath(
                from: previous, to: path, isSelected: selectedTab == .more
            )
        }
        .onChange(of: selectedTab) { _, tab in
            switch tab {
            case .studio:
                appModel.section = .studio
            case .assistant:
                appModel.section = .assistant
            case .mix:
                appModel.section = .mix
            case .more:
                appModel.section = appModel.section.selectingCompactMore(path: morePath)
            }
        }
    }

    private func synchronizeSelection(_ section: AppSection) {
        let tab = compactTab(for: section)
        selectedTab = tab
        // Selecting More alone cannot restore a destination after an adaptive-width change.
        if section == .workspace || section == .more || (tab == .more && morePath.last == .workspace) {
            morePath = section.compactMorePath
        }
    }

    private func compactTab(for section: AppSection) -> CompactTab {
        switch section {
        case .studio:
            return .studio
        case .assistant:
            return .assistant
        case .mix:
            return .mix
        case .workspace, .more, .patchbay, .connection, .tutorial, .advanced:
            return .more
        }
    }
}

extension EnvironmentValues {
    @Entry var compactKeyboardNavigation: CompactKeyboardNavigation?
}

struct AssistantComposerFocusKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// Composer and controls share one inset inside the selected stack, not an overlapping root inset/accessory.
struct AssistantKeyboardControls: View {
    @Environment(\.compactKeyboardNavigation) private var navigation
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let navigation { navigation } else { Spacer() }
            Button(action: dismiss) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide Keyboard")
            .accessibilityIdentifier("assistant.hideKeyboard")
        }
        .padding(.horizontal, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard controls")
    }
}

struct CompactKeyboardNavigation: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Binding fileprivate var selectedTab: CompactTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CompactTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.systemImage)
                        if !dynamicTypeSize.isAccessibilitySize && verticalSizeClass != .compact {
                            Text(tab.title)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                .accessibilityIdentifier("navigation.keyboard.\(tab.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Primary navigation")
    }
}

private enum CompactTab: String, CaseIterable, Identifiable {
    case studio
    case assistant
    case mix
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .studio: "Studio"
        case .assistant: "Assistant"
        case .mix: "Mix"
        case .more: "More"
        }
    }

    var systemImage: String {
        switch self {
        case .studio: AppSection.studio.systemImage
        case .assistant: AppSection.assistant.systemImage
        case .mix: AppSection.mix.systemImage
        case .more: "ellipsis.circle"
        }
    }
}
#endif
