//
//  AppIconPicker.swift
//  FluxKlang
//
//  A list of the selectable app icons with previews. Rendered inside the
//  Settings form on both platforms.
//

import SwiftUI

struct AppIconPicker: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let manager = appModel.appIcon
        ForEach(AppIconOption.allCases) { option in
            Button {
                manager.select(option)
            } label: {
                row(option, isSelected: manager.selected == option)
            }
            .buttonStyle(.plain)
        }
        .disabled(!manager.canChangeIcon)
    }

    private func row(_ option: AppIconOption, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(option.thumbnail)
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                Text(option.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .imageScale(.large)
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    Form {
        Section("App Icon") {
            AppIconPicker()
        }
    }
    .formStyle(.grouped)
    .environment(AppModel.preview())
}
