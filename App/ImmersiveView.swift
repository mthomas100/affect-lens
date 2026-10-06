//
//  ImmersiveView.swift
//  AffectLens
//
//  The optional mixed-immersion space: an inward-facing sphere around the wearer,
//  tinted by the live reading, so the real room takes on the emotion's colour
//  through passthrough. The window keeps the camera; this space only reads the
//  shared engine (and runs ARKit hand and head tracking while it is open).
//

import RealityKit
import SwiftUI
import UIKit

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel

    /// The optional FUSED-aura mapping (PRD v2 §6.4). DEFAULT FALSE — when off/absent the
    /// aura is byte-identical to the original face-driven behavior (the guard below). When
    /// on, hue follows fused valence, the aura pulses on combined arousal, and its dimness
    /// follows confidence. Never a reward loop — it reflects the reading, it doesn't praise it.
    @AppStorage(FusedAura.enabledKey) private var fusedMode = false

    var body: some View {
        RealityView { content in
            // Emotion aura: an inward-facing sphere around the user, tinted by
            // the currently detected emotion. In mixed immersion this gently
            // tints the passthrough view of the real room rather than replacing
            // it — no SkyDome, so the user's environment stays visible.
            let aura = ModelEntity(
                mesh: .generateSphere(radius: 7),
                materials: [ImmersiveView.auraMaterial(color: .white, opacity: 0)]
            )
            aura.name = "EmotionAura"
            aura.scale = SIMD3<Float>(-1, 1, 1) // flip winding so the interior renders
            aura.position = [0, 1.5, 0]
            content.add(aura)
        } update: { content in
            if let aura = content.entities.first(where: { $0.name == "EmotionAura" }) as? ModelEntity {
                if fusedMode {
                    // Fused mapping (§6.4): hue = valence, pulse = combined arousal, dimness =
                    // confidence, with a brief swell on a BOCPD state shift. Reads the shared
                    // hub — so the aura follows whatever the window is fusing.
                    ImmersiveView.updateFusedAura(aura, appModel: appModel, now: Date())
                } else {
                    // DEFAULT (toggle off/absent) — UNCHANGED face-driven aura, byte-identical.
                    let reading = appModel.emotionEngine.reading
                    // Aura strength follows expression INTENSITY (gated by
                    // confidence) — the sky burns brighter the harder you emote.
                    let strength = reading.intensity * min(1, reading.confidence * 1.6)
                    let opacity: Float = reading.faceDetected ? Float(0.04 + 0.16 * strength) : 0
                    aura.model?.materials = [
                        ImmersiveView.auraMaterial(color: UIColor(reading.dominant.color), opacity: opacity)
                    ]
                }
            }
        }
        .onAppear {
            appModel.auraState = .open
            // US-D13a: the immersive space is the ONE surface where ARKit hand / world
            // tracking runs. Opening it starts the sensing coordinator (K1: HandTracking
            // alongside the Persona camera), which feeds the hands channel; closing it stops
            // + flips the channel `.unavailable`. Idempotent + defensive — the simulator has no
            // hand-tracking provider, so this degrades to a typed-unavailable state, never a
            // crash, and never touches the face pipeline.
            appModel.affectHub.immersiveSensing.startIfNeeded()
        }
        .onDisappear {
            appModel.affectHub.immersiveSensing.stop()
            appModel.auraState = .closed
        }
    }

    static func auraMaterial(color: UIColor, opacity: Float) -> UnlitMaterial {
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return material
    }

    /// The FUSED aura update (PRD v2 §6.4) — used ONLY while `aura.fusedMode.enabled` is on:
    ///  • HUE follows fused VALENCE on the State-of-Mind purple→blue→orange ramp (the face is
    ///    the only valence owner).
    ///  • The aura PULSES in opacity between `FusedAura.pulseMinHz`…`pulseMaxHz` (0.2–1.2 Hz),
    ///    rate + depth scaling with COMBINED arousal across the live channels (the face's own
    ///    arousal + each enabled aux channel's). The pulse phase is driven by wall-clock time
    ///    and this closure's ~15 Hz re-invocation while a face is present. "Size" is folded
    ///    into the opacity pulse — modulating a 7 m passthrough shell's scale is visually
    ///    negligible, and leaving `scale` untouched keeps the OFF path byte-identical.
    ///  • OPACITY (the envelope the pulse rides) follows CONFIDENCE — low ⇒ dim + soft
    ///    ("blurry is honestly unsure"; edge-softness folds into opacity, the blur knob being heavy).
    ///  • A recent BOCPD `.stateShift` adds a brief, subtle SWELL.
    /// It NEVER rewards — the aura reflects the reading, it does not praise it.
    static func updateFusedAura(_ aura: ModelEntity, appModel: AppModel, now: Date) {
        let faceR = appModel.emotionEngine.reading
        guard faceR.faceDetected else {
            aura.model?.materials = [auraMaterial(color: .white, opacity: 0)]
            return
        }
        let hub = appModel.affectHub

        // HUE — fused valence on the State-of-Mind ramp (face owns valence).
        let ramp = StateOfMindRamp.color(valence: faceR.valence)

        // PULSE — combined arousal across the live channels (r-weighted; r = 0 excluded).
        let (meters, reliabilities) = liveArousal(hub: hub, face: faceR)
        let combined = CombinedArousal.compute(meters: meters, reliabilities: reliabilities)
        let arousal01 = min(1, max(0, ((combined?.value ?? faceR.arousal) + 1) / 2))
        let arousalConf = min(1, max(0, combined?.confidence ?? faceR.confidence))
        let rateHz = FusedAura.pulseMinHz + arousal01 * (FusedAura.pulseMaxHz - FusedAura.pulseMinHz)
        let depth = FusedAura.pulseMaxDepth * arousal01 * arousalConf
        let phase = now.timeIntervalSinceReferenceDate * rateHz * 2 * .pi
        let pulse = 1 + depth * sin(phase)

        // OPACITY envelope — confidence (dim + soft when unsure) — plus a recent-shift swell.
        let conf = min(1, max(0, faceR.confidence))
        let base = FusedAura.opacityFloor + FusedAura.opacitySpan * conf
        let swell = recentStateShiftSwell(hub: hub, now: now)
        let opacity = min(FusedAura.opacityCeiling, max(0, base * pulse + swell))

        let color = UIColor(hue: CGFloat(ramp.h), saturation: CGFloat(ramp.s),
                            brightness: CGFloat(ramp.b), alpha: 1)
        aura.model?.materials = [auraMaterial(color: color, opacity: Float(opacity))]
    }

    /// The live channels' arousal meters + reliabilities for `CombinedArousal`: the face's own
    /// circumplex arousal always, plus each ENABLED aux channel's published arousal meter
    /// (reliability = that meter's own confidence). A disabled / dark channel isn't added, so
    /// it can't vote.
    private static func liveArousal(hub: AffectHub, face: EmotionReading)
        -> (meters: [Channel: Meter?], reliabilities: [Channel: Double]) {
        var present: [Channel: Meter] = [:]
        var reliabilities: [Channel: Double] = [:]
        present[.face] = Meter(value: face.arousal, confidence: face.confidence)
        reliabilities[.face] = face.confidence
        func add(_ channel: Channel, _ enabled: Bool, _ meter: Meter?) {
            guard enabled, let m = meter else { return }
            present[channel] = m
            reliabilities[channel] = m.confidence
        }
        add(.eyes, hub.eyes.isEnabled, hub.eyes.reading.arousal)
        add(.hands, hub.hands.isEnabled, hub.hands.reading.arousal)
        add(.head, hub.head.isEnabled, hub.head.reading.arousal)
        add(.voice, hub.voice.isEnabled, hub.voice.reading.arousal)
        return (present.mapValues { Optional($0) }, reliabilities)
    }

    /// A brief opacity SWELL if a BOCPD `.stateShift` fired within `FusedAura.swellDuration`
    /// (1.5 s), decaying with `FusedAura.swellTau` (0.5 s); 0 otherwise. Subtle — the aura
    /// acknowledges a state change without announcing it.
    private static func recentStateShiftSwell(hub: AffectHub, now: Date) -> Double {
        guard let last = hub.events.last(where: { $0.kind == .stateShift }) else { return 0 }
        let age = now.timeIntervalSince(last.t)
        guard age >= 0, age < FusedAura.swellDuration else { return 0 }
        return FusedAura.swellPeak * exp(-age / FusedAura.swellTau)
    }
}
