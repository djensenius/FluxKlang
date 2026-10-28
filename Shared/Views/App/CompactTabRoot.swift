import SwiftUI
#if os(iOS)
import UIKit

struct CompactTabRoot: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedTab = CompactTab.studio
    @State private var isShowingConnection = false
    @State private var isKeyboardVisible = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                SectionDetail(section: .studio)
            }
            .toolbar(isKeyboardVisible ? .hidden : .automatic, for: .tabBar)
            .tabItem { Label("Studio", systemImage: AppSection.studio.systemImage) }
            .tag(CompactTab.studio)

            NavigationStack {
                SectionDetail(section: .assistant)
            }
            .toolbar(isKeyboardVisible ? .hidden : .automatic, for: .tabBar)
            .tabItem { Label("Assistant", systemImage: AppSection.assistant.systemImage) }
            .tag(CompactTab.assistant)

            NavigationStack {
                MixView()
            }
            .toolbar(isKeyboardVisible ? .hidden : .automatic, for: .tabBar)
            .tabItem { Label("Mix", systemImage: AppSection.mix.systemImage) }
            .tag(CompactTab.mix)

            NavigationStack {
                MoreView()
            }
            .toolbar(isKeyboardVisible ? .hidden : .automatic, for: .tabBar)
            .tabItem { Label("More", systemImage: "ellipsis.circle") }
            .tag(CompactTab.more)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isKeyboardVisible {
                ConnectionStatusButton { isShowingConnection = true }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isKeyboardVisible {
                keyboardNavigation
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        // Keep navigation reachable until dismissal completes, including canceled interactive swipes.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            isKeyboardVisible = false
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
        .onAppear { selectedTab = compactTab(for: appModel.section) }
        .onChange(of: appModel.section) { _, section in
            selectedTab = compactTab(for: section)
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
                break
            }
        }
    }

    // Native tabs can disappear during editing. Replace, rather than duplicate, them in
    // the keyboard-adjusted safe area while keeping the same selection and navigation stacks.
    private var keyboardNavigation: some View {
        HStack(spacing: 0) {
            ForEach(CompactTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.systemImage)
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text(tab.title)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                .accessibilityIdentifier("navigation.keyboard.\(tab.rawValue)")
            }
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Primary navigation")
    }

    private func compactTab(for section: AppSection) -> CompactTab {
        switch section {
        case .studio:
            return .studio
        case .assistant:
            return .assistant
        case .mix:
            return .mix
        case .patchbay, .connection, .tutorial, .advanced:
            return .more
        }
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
