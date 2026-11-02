import AppKit
import Observation
import SupermoleCore
import SwiftUI

/// The Apps space: uninstall apps with what they leave behind (`mo uninstall`),
/// or slim the ones that carry Intel code (`mo slim`).
@MainActor
@Observable
final class AppsModel {
    enum Section: String, CaseIterable, Identifiable {
        case uninstall
        case slim

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .uninstall: return "Uninstall apps"
            case .slim: return "Slim apps"
            }
        }

        var subtitle: String {
            switch self {
            case .uninstall: return String(localized: "Remove apps with everything they leave behind.")
            case .slim: return String(localized: "Remove the Intel code your Mac never runs from universal apps.")
            }
        }
    }

    var section: Section = .uninstall
    let uninstall = UninstallModel()
    let slim = SlimModel()
}

struct AppsView: View {
    let runner: MoleRunner
    @Bindable var model: AppsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                PageHeader(title: "Apps", subtitle: model.section.subtitle)
                    .entrance()
                Picker("Apps", selection: $model.section) {
                    ForEach(AppsModel.Section.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .entrance(1)
                switch model.section {
                case .uninstall:
                    UninstallSection(runner: runner, model: model.uninstall)
                case .slim:
                    SlimSection(runner: runner, model: model.slim)
                }
            }
            .padding(Theme.pagePadding)
        }
    }
}

/// An app in a list to tick: a box, its icon and name, a line under the name,
/// and a size on the right.
struct SelectableAppRow<Detail: View>: View {
    let name: String
    let path: String
    /// Nil while `mo` has not measured it yet.
    let bytes: Int64?
    @Binding var isSelected: Bool
    @ViewBuilder let detail: () -> Detail

    private var sizeText: String { bytes.map { Formatting.bytes($0) } ?? "…" }

    var body: some View {
        Button {
            withAnimation(Motion.hover) { isSelected.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.teal) : AnyShapeStyle(.secondary))
                AppIcon(path: path)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name).font(.body.weight(.medium))
                    detail()
                }
                Spacer()
                Text(verbatim: sizeText)
                    .monospacedDigit()
                    .foregroundStyle(bytes == nil ? .secondary : .primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.teal.opacity(0.1) : .clear, in: .rect(cornerRadius: Theme.rowRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(Text(verbatim: sizeText))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The app's own icon, as the Finder shows it, read off the main thread.
struct AppIcon: View {
    let path: String
    var size: CGFloat = 32

    @Environment(\.displayScale) private var scale
    @State private var icon: CGImage?

    var body: some View {
        Group {
            if let icon {
                Image(decorative: icon, scale: scale)
                    .resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: path) {
            icon = await AppIconStore.shared.icon(for: path, pixels: Int(size * scale))
        }
    }
}

/// App icons drawn once per app and size, then kept for the app's life, so
/// scrolling a list never asks the Finder again.
@MainActor
final class AppIconStore {
    static let shared = AppIconStore()

    private var icons: [String: CGImage] = [:]

    func icon(for path: String, pixels: Int) async -> CGImage? {
        let key = "\(pixels)@\(path)"
        if let icon = icons[key] { return icon }
        let icon = await Self.draw(path: path, pixels: pixels)
        icons[key] = icon
        return icon
    }

    nonisolated private static func draw(path: String, pixels: Int) async -> CGImage? {
        var rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        return NSWorkspace.shared.icon(forFile: path).cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

extension Binding where Value == Set<String> {
    /// Whether the set holds the element, as a box to tick.
    func contains(_ element: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.contains(element) },
            set: { isOn in
                if isOn {
                    wrappedValue.insert(element)
                } else {
                    wrappedValue.remove(element)
                }
            }
        )
    }
}
