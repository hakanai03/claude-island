//
//  ProcessingSpinner.swift
//  ClaudeIsland
//
//  Animated symbol spinner for processing state
//

import SwiftUI

struct ProcessingSpinner: View {
    private let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let color = Color(red: 0.85, green: 0.47, blue: 0.34) // Claude orange
    private let interval: TimeInterval = 0.15

    var body: some View {
        TimelineView(.animation(minimumInterval: interval)) { timeline in
            let phase = Int(timeline.date.timeIntervalSinceReferenceDate / interval) % symbols.count
            Text(symbols[phase])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(color)
                .frame(width: 12, alignment: .center)
        }
    }
}

#Preview {
    ProcessingSpinner()
        .frame(width: 30, height: 30)
        .background(.black)
}
