//
//  FadersView.swift
//  FluxKlang
//
//  A configurable, scrollable bank of mixer strips bound to WING nodes. The
//  layout is user-editable (add/remove/rename strips) and persisted, so the
//  mixer comes back exactly as left. When nothing is connected it offers a
//  one-tap route into Demo Mode.
//

import SwiftUI

struct FadersView: View {
    @Environment(AppModel.self) private var appModel

    /// Whether a rename edits the shared console name or a local-only label.
    private enum RenameMode { case console, local }

    @State private var renamingStrip: FaderStrip?
    @State private var renameMode: RenameMode = .console
    @State private var draftLabel = ""

    private var controller: WingController { appModel.wing }
    private var layout: FaderLayout { appModel.faderLayout.layout }

    var body: some View {
        Group {
            if controller.connection.isConnected {
                bank
            } else {
                unavailable
            }
        }
        .navigationTitle("Faders")
        .toolbar { addStripMenu }
        .alert(renameTitle, isPresented: isRenaming) {
            TextField(renameFieldPrompt, text: $draftLabel)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renamingStrip = nil }
        } message: {
            Text(renameMessage)
        }
    }

    private var bank: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(layout.strips) { strip in
                    FaderStripView(
                        controller: controller,
                        strip: strip,
                        isSelected: appModel.selectedFaderID == strip.id,
                        onSelect: { appModel.selectStrip(strip) }
                    )
                        .contextMenu {
                            Button {
                                appModel.selectStrip(strip)
                            } label: {
                                Label("Show in Inspector", systemImage: "sidebar.right")
                            }
                            Button {
                                beginRename(strip, mode: .console)
                            } label: {
                                Label("Rename on Console…", systemImage: "pencil")
                            }
                            Button {
                                beginRename(strip, mode: .local)
                            } label: {
                                Label("Set Local Label…", systemImage: "tag")
                            }
                            Button(role: .destructive) {
                                appModel.faderLayout.remove(strip)
                            } label: {
                                Label("Remove Strip", systemImage: "trash")
                            }
                        }
                }
            }
            .padding()
        }
    }

    @ToolbarContentBuilder
    private var addStripMenu: some ToolbarContent {
        ToolbarItem {
            Menu {
                stereoPairMenu
                Divider()
                ForEach(WingNodeKind.allCases, id: \.self) { kind in
                    kindMenu(kind)
                }
            } label: {
                Label("Add Strip", systemImage: "plus")
            }
            .disabled(!controller.connection.isConnected)
        }
    }

    private var stereoPairMenu: some View {
        Menu("Stereo Pair") {
            ForEach(availableStereoLefts, id: \.self) { left in
                Button("Channels \(left) & \(left + 1)") {
                    addStereoPair(left: left)
                }
            }
        }
    }

    private func addStereoPair(left: Int) {
        let leftNode = WingNodeRef.channel(left)
        let rightNode = WingNodeRef.channel(left + 1)
        appModel.faderLayout.addStereoStrip(left: leftNode, right: rightNode)
        Task { await controller.hardPanPair(leftNode, rightNode) }
    }

    private var availableStereoLefts: [Int] {
        (1..<WingNodeKind.channel.count).filter {
            !layout.contains(.channel($0)) && !layout.contains(.channel($0 + 1))
        }
    }

    private func kindMenu(_ kind: WingNodeKind) -> some View {
        Menu(kind.label) {
            ForEach(availableIndices(for: kind), id: \.self) { index in
                Button("\(kind.label) \(index)") {
                    appModel.faderLayout.addStrip(WingNodeRef(kind: kind, index: index))
                }
            }
        }
    }

    private func availableIndices(for kind: WingNodeKind) -> [Int] {
        (1...kind.count).filter { !layout.contains(WingNodeRef(kind: kind, index: $0)) }
    }

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { renamingStrip != nil },
            set: { if !$0 { renamingStrip = nil } }
        )
    }

    private var renameTitle: String {
        renameMode == .console ? "Rename on Console" : "Set Local Label"
    }

    private var renameFieldPrompt: String {
        renameMode == .console ? "Console Name" : "Local Label"
    }

    private var renameMessage: String {
        renameMode == .console
            ? "Renames the strip on the WING, shared with every connected client."
            : "Sets a FluxKlang-only label that overrides the console name in this layout."
    }

    private func beginRename(_ strip: FaderStrip, mode: RenameMode) {
        renameMode = mode
        switch mode {
        case .console:
            draftLabel = consoleBaseName(for: strip)
        case .local:
            draftLabel = strip.customLabel ?? ""
        }
        renamingStrip = strip
    }

    /// The editable base name for a console rename. For a stereo strip the left
    /// node's ` L` suffix (added by ``WingController/setNamePair``) is dropped so
    /// re-saving doesn't compound into `Name L L`.
    private func consoleBaseName(for strip: FaderStrip) -> String {
        let name = controller.name(strip.node.kind, strip.node.index) ?? ""
        if strip.rightNode != nil, name.hasSuffix(" L") {
            return String(name.dropLast(2))
        }
        return name
    }

    private func commitRename() {
        guard let strip = renamingStrip else { return }
        switch renameMode {
        case .console:
            // Push to the console (the broadcast echo updates the cache) and drop
            // any local override so the shared name shows through.
            appModel.faderLayout.setLabel(nil, for: strip.id)
            Task { await controller.setNamePair(strip.node, strip.rightNode, to: draftLabel) }
        case .local:
            appModel.faderLayout.setLabel(draftLabel, for: strip.id)
        }
        renamingStrip = nil
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label("Not Connected", systemImage: "slider.vertical.3")
        } description: {
            Text("Connect to your WING, or try Demo Mode to explore offline.")
        } actions: {
            Button {
                Task { await appModel.enterDemoMode() }
            } label: {
                Label("Enter Demo Mode", systemImage: "play.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    NavigationStack { FadersView() }
        .environment(AppModel.preview())
}
