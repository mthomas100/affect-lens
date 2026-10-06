//
//  TemporalSmoother.swift
//  AffectLens
//
//  Temporal stabilization of per-frame emotion distributions: exponential
//  moving average over the distribution plus hysteresis on the announced
//  dominant label, so the readout is stable instead of flickering between
//  neighboring emotions at their decision boundary.
//

import Foundation

#if os(visionOS) || os(macOS)

struct TemporalSmoother: Sendable {

    /// Weight of each new frame in the EMA (at ~12 Hz, 0.35 ≈ 250 ms time constant).
    var alpha: Double = 0.35
    /// A challenger must lead the incumbent by this probability margin…
    var switchMargin: Double = 0.06
    /// …for this many consecutive updates before the label switches.
    var switchFrames: Int = 3

    private(set) var smoothed: EmotionDistribution = .neutralRest
    private(set) var stableDominant: Emotion = .neutral

    private var challenger: Emotion?
    private var challengerStreak = 0

    /// Feed one per-frame distribution; returns the smoothed distribution and
    /// the hysteresis-stabilized dominant emotion.
    mutating func update(with frame: EmotionDistribution) -> (distribution: EmotionDistribution, dominant: Emotion) {
        smoothed = smoothed.lerp(toward: frame, alpha: alpha)

        let leader = smoothed.dominant
        let incumbentP = smoothed[stableDominant]

        if leader.emotion == stableDominant {
            challenger = nil
            challengerStreak = 0
        } else if leader.probability > incumbentP + switchMargin || incumbentP < 0.15 {
            if challenger == leader.emotion {
                challengerStreak += 1
            } else {
                challenger = leader.emotion
                challengerStreak = 1
            }
            if challengerStreak >= switchFrames {
                stableDominant = leader.emotion
                challenger = nil
                challengerStreak = 0
            }
        } else {
            challenger = nil
            challengerStreak = 0
        }

        return (smoothed, stableDominant)
    }

    /// Decay toward rest when no face is visible.
    mutating func decayTowardRest() {
        smoothed = smoothed.lerp(toward: .neutralRest, alpha: 0.15)
        if smoothed[.neutral] > 0.6 {
            stableDominant = .neutral
            challenger = nil
            challengerStreak = 0
        }
    }

    mutating func reset() {
        smoothed = .neutralRest
        stableDominant = .neutral
        challenger = nil
        challengerStreak = 0
    }
}
#endif
