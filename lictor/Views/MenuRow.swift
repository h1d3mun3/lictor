//
//  MenuRow.swift
//  lictor
//
//  Rows for the dropdown, styled like the menu bar panels macOS ships (Wi-Fi,
//  Bluetooth, Control Center) rather than like bordered buttons.
//
//  Bordered buttons are what made the panel read as a small application window
//  instead of a menu bar item. The visual language of a menu extra is rows that
//  highlight on hover, not controls with visible edges.
//
//  The highlight is a subtle fill rather than the accent-coloured, white-text
//  inversion of a real NSMenu. This is a custom window, not a menu, and matching
//  NSMenu exactly would invite comparisons it cannot win -- Control Center uses
//  the same restrained treatment.
//

import SwiftUI

/// Shared chrome so a plain row and a disclosure row cannot drift apart.
private struct RowSurface: ViewModifier {
    let isHovering: Bool
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // Without this the row only responds where text actually is
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering && isEnabled
                          ? AnyShapeStyle(.quaternary)
                          : AnyShapeStyle(.clear))
            )
            .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: -

struct MenuRow: View {
    let title: String
    var systemImage: String?
    var trailing: String?
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 14)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .modifier(RowSurface(isHovering: isHovering, isEnabled: isEnabled))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
    }
}

// MARK: -

/// A row that expands to reveal its choices, in the manner of "Other Networks"
/// in the Wi-Fi panel.
///
/// This exists to stop every option competing for attention at once, but it also
/// reinforces the asymmetry the whole design rests on (principle 3).
/// Turning SSH **off** stays a single click at the top level. Turning it **on**,
/// or keeping it on longer, now costs an extra one. Friction lands on the
/// dangerous direction and nowhere else.
///
/// Collapsed state is not persisted. Reopening the panel starts closed, so the
/// resting appearance is always the quiet one.
struct MenuDisclosure<Content: View>: View {
    let title: String
    var systemImage: String?
    var isEnabled = true
    @ViewBuilder var content: () -> Content

    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .frame(width: 14)
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .modifier(RowSurface(isHovering: isHovering, isEnabled: isEnabled))
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .onHover { isHovering = $0 }

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                // Indented so the choices read as belonging to the row above
                .padding(.leading, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
}

// MARK: -

/// Explanatory text tied to the row above it, indented to match.
struct MenuRowCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.top, 1)
            .padding(.bottom, 3)
    }
}
