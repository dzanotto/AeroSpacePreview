import SwiftUI

struct DiagnosticsHUDView: View {
    let snapshot: DiagnosticsSnapshot

    var body: some View {
        Text(DiagnosticsHUDFormatter.text(for: snapshot))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.92))
            .lineSpacing(2)
            .fixedSize(horizontal: true, vertical: true)
            .frame(width: 600, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
