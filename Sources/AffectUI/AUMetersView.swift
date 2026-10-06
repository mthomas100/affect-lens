//
//  AUMetersView.swift
//  AffectLens
//
//  The "science" panel: live FACS Action Unit intensities feeding the
//  classifier, so you can see exactly why an emotion was chosen.
//

import SwiftUI

#if os(visionOS)
struct AUMetersView: View {
    let au: AUVector

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Action Units (FACS)")
                .font(.footnote.bold())
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 9) {
                ForEach(ActionUnit.allCases) { unit in
                    let value = au[unit] ?? 0
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(unit.shortName)
                                .font(.caption.bold())
                            Text(unit.facsName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text("\(Int((value * 100).rounded()))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        ProgressView(value: value)
                            .tint(value > 0.35 ? Color.cyan : Color.gray)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .animation(.smooth(duration: 0.2), value: au)
    }
}
#endif
