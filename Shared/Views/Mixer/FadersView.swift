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

    @State private var renamingStrip: FaderStrip?
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
        .alert("Rename Strip", isPresented: isRenaming) {
            TextField("Label", text: $draftLabel)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renamingStrip = nil }
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
                                draftLabel = strip.customLabel ?? ""
                                renamingStrip = strip
                            } label: {
                                Label("Rename…", systemImage: "pencil")
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

    private func commitRename() {
        guard let strip = renamingStrip else { return }
        appModel.faderLayout.setLabel(draftLabel, for: strip.id)
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
