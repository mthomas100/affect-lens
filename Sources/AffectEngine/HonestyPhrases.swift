//
//  HonestyPhrases.swift
//  AffectLens
//
//  The LINTED copy-constants library (US-B7, PRD v2 §6.7) — so no view or narrator
//  can overclaim. Every user-facing affect string must come FROM this file or be
//  checked AGAINST it (`containsBanned`). It encodes:
//    • the required framings ("from your Persona", "expression estimate"),
//    • the ONE honesty grammar for a fused/narrated readout —
//        [expression-estimate] + [channel attribution] + [confound being ruled out]
//        + [confidence, separate from intensity],
//    • the confidence WORD scale (rendered separately from any intensity), and
//    • `bannedSubstrings` — the words a readout may never contain.
//
//  This is the human-readable half of metric M7 (§9.1): the template narrator draws
//  its sentences only from here, and `EmotionSelfTests.narratorHonesty()` asserts
//  every narrated line is banned-substring-clean, cites a present signal, and states
//  a confidence word. When the FoundationModels narrator lands, its post-generation
//  filter reuses `containsBanned` as the same deterministic backstop.
//

import Foundation

/// Namespace of honesty-bounded copy constants and templates. Pure and
/// `nonisolated`; holds no state.
nonisolated enum HonestyPhrases {

    // MARK: Required framings

    /// The mandatory grounding: everything the app reads comes off the rendered
    /// Persona avatar, never the real face.
    static let personaFraming = "from your Persona"
    /// What the face reading IS — an estimate of an expression, never a felt emotion.
    static let expressionEstimate = "expression estimate"

    // MARK: Banned substrings (case-insensitive; the linted floor)

    /// Substrings that must NEVER appear in a user-facing affect string. Matched
    /// case-insensitively by `containsBanned`. This is the deterministic honesty
    /// floor shared by the template narrator, the (future) FM post-filter, and the
    /// self-test. Covers: reading the real face; concealment/deception framings;
    /// genuine-vs-fake smile; and clinical labels.
    static let bannedSubstrings: [String] = [
        "your face",
        "concealing",
        "concealment",
        "genuine",
        "fake",
        "lying",
        "deception",
        "stress",
        "anxiety",
        "depression",
        "diagnos"        // matches diagnose / diagnosis / diagnostic
    ]

    /// True if `text` contains any banned substring (case-insensitive). The single
    /// linter every affect string is held to.
    static func containsBanned(_ text: String) -> Bool {
        let lower = text.lowercased()
        return bannedSubstrings.contains { lower.contains($0) }
    }

    // MARK: Confidence word (epistemic — always rendered SEPARATE from intensity)

    /// The confidence words, in ascending order (also the self-test's allow-list).
    static let confidenceWords = ["low", "moderate", "high"]

    /// Map a 0…1 epistemic confidence to a word. Deliberately a WORD, never a number
    /// glued to intensity — intensity and confidence are different signals (§5.4).
    static func confidenceWord(_ c: Double) -> String {
        switch c {
        case ..<0.4: return "low"
        case ..<0.7: return "moderate"
        default: return "high"
        }
    }

    /// The confidence clause that closes every narrated line.
    static func confidencePhrase(_ c: Double) -> String {
        "Confidence: \(confidenceWord(c))."
    }

    // MARK: Direction (for axis shifts)

    /// Direction of an axis move.
    nonisolated enum Direction { case up, down }

    /// Plain-language phrasing of a move on a specific axis. Valence and arousal get
    /// honest, axis-appropriate words; anything else falls back to higher/lower.
    static func directionPhrase(axis: SignalRef, _ dir: Direction) -> String {
        switch axis {
        case .valence: return dir == .up ? "toward more positive" : "toward more negative"
        case .arousal: return dir == .up ? "toward more activated" : "toward calmer"
        default: return dir == .up ? "higher" : "lower"
        }
    }

    // MARK: The grammar — templates

    /// The confound clause for a dimensional change-point: a shift in the estimate
    /// is not a claim about felt emotion.
    static let stateShiftConfound = "A change in the reading, not a claim about how you feel."

    /// State-shift narration (BOCPD). Grammar: estimate framing + axis attribution +
    /// confound + confidence-separate-from-intensity.
    static func stateShift(axis: SignalRef, direction: Direction, confidence: Double) -> String {
        "Your Persona's \(expressionEstimate) shifted just now — "
        + "\(axis.displayName) moved \(directionPhrase(axis: axis, direction)). "
        + "\(stateShiftConfound) \(confidencePhrase(confidence))"
    }

    /// Generic narration for the other event kinds. Grammar preserved: an honest
    /// verb for the kind + the attributed present signals + the Persona framing +
    /// a confidence word. Never asserts a felt emotion.
    static func generic(kind: EventKind, evidence: [SignalRef], confidence: Double) -> String {
        let attribution = evidence.isEmpty
            ? ""
            : " — " + evidence.map(\.displayName).joined(separator: ", ")
        return "\(verb(for: kind))\(attribution), \(personaFraming). \(confidencePhrase(confidence))"
    }

    /// The honest verb phrase for an event kind — names the mechanical signal event,
    /// never a felt state. (`.stateShift` normally routes through `stateShift(...)`;
    /// its entry here is a safe fallback.)
    static func verb(for kind: EventKind) -> String {
        switch kind {
        case .blink: return "Registered a blink"
        case .eyeClosureProlonged: return "Eyes stayed closed longer than a blink"
        case .selfTouch: return "Hand-to-face contact ticked up"
        case .gestureBurst: return "Hand movement spiked"
        case .postureShift: return "Posture shifted"
        case .headMotionSpike: return "Head motion spiked"
        case .vocalEvent: return "A voice event registered"
        case .congruenceBreak: return "Channels diverged"
        case .arousalConsensus: return "Arousal signals agreed"
        case .stateShift: return "The expression estimate shifted"
        case .constructStateChanged: return "A named state changed"
        case .calibrationStarted: return "Started learning your neutral baseline"
        case .calibrationCompleted: return "Finished learning your neutral baseline"
        case .channelAvailabilityChanged: return "A lens changed availability"
        case .lowExpresserFlag: return "Your expressions read subtly, so uncertainty is widened"
        case .baselineRetrack: return "Nudged your neutral baseline"
        }
    }

    // MARK: UI copy (checked against the linter by construction)

    /// Honest empty-state for the insight feed.
    static let insightFeedEmpty =
        "No state shifts yet — the feed narrates detected changes from your Persona and enabled lenses."

    // MARK: Interaction lens (US-B8, PRD v2 §3.6)

    /// The interaction lens's persistent "what this can / can't tell you" scope
    /// (PRD §3.6 science note — Doherty-Sneddon & Phelps 2005: effort ≠ affect).
    /// Effort / load framing ONLY — never "stress", never "frustration" as a state
    /// (F7 Frustration is the LATER fusion construct; this lens alone shows load).
    static let interactionScope =
        "Reads how you manipulate this app's controls — effort and engagement with the task, not an emotion. Task difficulty and feeling are indistinguishable here."

    /// The DESIGNED low-signal (starvation) copy: passive viewing produces too little
    /// manipulation to read, so the lens says so honestly instead of fabricating a
    /// value (PRD §4.2 F7 signal-density caveat).
    static let interactionStarved =
        "Not enough interaction to read — this lens needs you to actually use controls."

    /// The interaction lens's forked-ambiguity note: load is not a feeling, and the
    /// two confounds (task difficulty vs. engagement) look alike here.
    static let interactionAmbiguity =
        "Effort and task difficulty look alike here — this is a load / engagement signal, not a feeling."

    // MARK: Voice lens (US-D12, PRD v2 §3.5 — arousal ONLY)

    /// The voice lens's persistent "what this can / can't tell you" — arousal ONLY
    /// (Juslin & Laukka 2003: arousal is robust in prosody, valence markedly
    /// inconsistent). NEVER valence, NEVER a discrete emotion, NEVER words.
    static let voiceScope =
        "Voice carries arousal — how activated you sound — reliably; it does not reliably carry which emotion. This lens never infers valence or a category from your voice, and never recognizes words."

    /// The on-device guarantee line (the App-Review moat), surfaced in the lens.
    static let voiceOnDevice =
        "Analyzed entirely on-device — pitch, loudness and tempo only. Audio never leaves the device and is never transcribed."

    /// The voice arousal ambiguity note (forked interpretation): a high vocal-arousal
    /// level does not say positive or negative — direction is the face lens's job.
    static let voiceAmbiguity =
        "High vocal arousal can be excitement OR agitation — arousal is a level, not a direction. Valence comes only from the face lens."

    /// The corroboration-only narration for an on-device laughter sound event (US-D12;
    /// F6 Corroborated-Positivity consumes it later). Cites the present vocal signal and
    /// keeps the Persona-grounding (it corroborates the Persona's expression estimate),
    /// states a confidence word, and is NEVER an emotion verdict. Banned-clean.
    static func vocalEvent(evidence: [SignalRef], confidence: Double) -> String {
        let cue = evidence.first?.displayName ?? "a vocal sound"
        return "A laugh-like sound registered on-device (\(cue)) — corroboration for your "
            + "Persona's \(expressionEstimate), not an emotion verdict. \(confidencePhrase(confidence))"
    }

    // MARK: Hands lens (US-D13a, PRD v2 §3.3 — arousal / agitation / load)

    /// The hands lens's persistent "what this can / can't tell you" scope. Hands own the
    /// AROUSAL / agitation / load axis ONLY — never valence, never a discrete emotion. There is
    /// NO gesture dictionary and self-touch is a RATE, never a single gesture (§3.3 / §4.5 #10).
    static let handsScope =
        "Reads how much and how fast your hands move, and how often they touch your head — an agitation / load signal on the arousal axis, measured against your own resting baseline. Never a gesture dictionary, never valence, never an emotion; self-touch is read as a rate over time, never a single gesture."

    /// The hands lens's forked-ambiguity note: motion energy is a level, not a direction.
    static let handsAmbiguity =
        "More hand motion means more arousal, not which emotion — this is a level, not a direction. Valence comes only from the face lens."

    /// Self-touch EVENT narration (US-D13a). A neutral observation of a RATE change, never a
    /// single-touch verdict and never an anxiety framing (the banlist traps "anxiety"). Cites
    /// the present self-touch-rate signal, keeps the Persona-session framing, states a
    /// confidence word separate from intensity.
    static func selfTouch(confidence: Double) -> String {
        "Your hands reached toward your head more often — self-touch rate ticked up, "
        + "read alongside your Persona. A rate over time, never a single gesture. "
        + "\(confidencePhrase(confidence))"
    }

    /// Gesture-burst EVENT narration (US-D13a). A motion-energy spike, NEVER a named pose (no
    /// gesture dictionary). Cites the present gesture-energy signal + the Persona-session
    /// framing + a confidence word.
    static func gestureBurst(confidence: Double) -> String {
        "Hand movement spiked — gesture energy rose above your resting baseline, "
        + "read alongside your Persona. \(confidencePhrase(confidence))"
    }

    // MARK: Head lens (US-D13b, PRD v2 §3.4 — dominance / approach + arousal, NEVER valence)

    /// The head lens's persistent "what this can / can't tell you" scope. Head owns the
    /// DOMINANCE / APPROACH + AROUSAL axes ONLY — never valence, never a discrete emotion,
    /// and there is NO head-tilt or nod/shake dictionary (§3.4 caveats / refused list §5).
    static let headScope =
        "Reads your head pose and how much it moves — a dominance / approach and arousal signal, measured against your own neutral pose. Never valence, never an emotion, and never a head-tilt or nod dictionary."

    /// The head lens's forked-ambiguity note: head motion is a level, not a direction.
    static let headAmbiguity =
        "More head motion means more arousal, not which emotion — a level, not a direction. Valence comes only from the face lens."

    /// THE mandated honesty paragraph (§3.4): head orientation is NOT gaze, the shame-vs-
    /// concentration split is unresolved, roll (lateral tilt) is the least reliable cue, and
    /// nod / shake meanings are refused (culture-coded). Banlist-clean by construction.
    static let headHonesty =
        "Head orientation only — we can't see your gaze or your torso. Head-down with direct gaze often means concentration, not withdrawal, so readings here stay low-confidence. Lateral tilt is the least reliable cue of all, and head nods and shakes are never given a meaning."

    /// The hedged dominance-lean line (§3.4). The felt words "pride" / "shame" appear ONLY
    /// as hedged glosses, never asserted, and the withdrawal side keeps the gaze caveat.
    /// Banlist-clean.
    static func headDominanceLine(lean: Double) -> String {
        if lean > 0.15 {
            return "Head-back and level — an expansion / higher-dominance lean (sometimes glossed \"pride\"), read as head orientation only, not a felt emotion."
        } else if lean < -0.15 {
            return "Head-down and turned away — a withdrawal / lower-dominance lean (sometimes glossed \"shame\") — but we can't see your gaze, so this stays low-confidence."
        }
        return "Head near your neutral pose — no clear dominance lean either way."
    }

    // MARK: Thermal governor (US-D13b, PRD v2 §8.1 — the sensing governor)

    /// The tier-appropriate, NON-ALARMING, banlist-clean notice when the governor eases
    /// sensing to shed heat. Never "overheating"; the Persona reading stays live.
    static func thermalReduced(warmth: String) -> String {
        "Your device is \(warmth) — sensing eased back to keep things cool. Fewer lenses and a gentler cadence; your Persona reading stays live."
    }

    /// The recovery notice when the device cools and full sensing returns.
    static let thermalRestored =
        "Your device cooled down — full sensing restored."

    // MARK: Congruence engine (US-C10a, PRD v2 §4.4)

    /// Narration for a divergence EVENT (`.congruenceBreak`) — the arousal-bearing
    /// channels are pulling different ways. Grammar-compliant and honesty-bounded: names
    /// the present signals, frames it as REDUCED CERTAINTY, and NEVER "concealment" (the
    /// app detects a divergence of behavioral proxies, not concealment — §4.4).
    static func congruenceBreak(evidence: [SignalRef], confidence: Double) -> String {
        let channels = evidence.isEmpty
            ? "your enabled lenses"
            : evidence.map(\.displayName).joined(separator: " and ")
        return "Signals disagree right now — \(channels) point different ways on arousal, "
            + "\(personaFraming); the reading is less certain. \(confidencePhrase(confidence))"
    }

    /// Narration for a strong-agreement ONSET (`.arousalConsensus`) — the arousal-bearing
    /// channels just agreed on direction. Names the present signals + the Persona framing
    /// + a confidence word; never asserts a felt emotion.
    static func arousalConsensus(evidence: [SignalRef], confidence: Double) -> String {
        let channels = evidence.isEmpty
            ? "your enabled lenses"
            : evidence.map(\.displayName).joined(separator: " and ")
        return "Your arousal signals agree — \(channels) are moving together, "
            + "\(personaFraming). \(confidencePhrase(confidence))"
    }

    /// The subtle congruence-RING state label. `.insufficient` returns `nil` (no
    /// judgment — the ring renders a neutral, NON-error state, never "insufficient"
    /// as a scary word). All returned strings are banned-substring-clean.
    static func congruenceStateLabel(_ named: NamedCongruence) -> String? {
        switch named {
        case .insufficient: return nil
        case .agreeing: return "signals agree"
        case .mixed: return "signals mixed"
        case .diverging: return "signals diverging"
        }
    }

    // MARK: F7 Frustration (task friction) fusion construct (US-C9, PRD v2 §4.2)

    /// The named confound F7 can never rule out — the sanctioned "task friction" honesty.
    /// A hard task and a frustrating one drive the same signals; this states that plainly.
    static let frustrationConfound = "Task difficulty and feeling look alike here."

    /// The F7 ACTIVATION narration. Follows the ONE grammar: expression estimate
    /// ("leans negative") + channel attribution ("cancel rate climbs" — cites the
    /// present interaction signal) + the named confound + a confidence word rendered
    /// SEPARATE from intensity. Never asserts frustration from interaction alone, and
    /// never says bare "frustration" without the task-friction framing.
    static func frustration(confidence: Double) -> String {
        "Your Persona leans negative while your cancel rate climbs — "
        + "consistent with frustration with the task. "
        + "\(frustrationConfound) \(confidencePhrase(confidence))"
    }

    /// F7's minimal disambiguation-ladder rungs (US-C10, §6.6 — proving the ladder is
    /// reusable). L0 = the negative lean; L1 = the interaction-friction conjunction that
    /// surfaces the named state. Banned-clean; "frustration (task friction)" is F7's
    /// sanctioned framing.
    static let frustrationLadderL0 = "Persona expression leans negative"
    static let frustrationLadderL0Fork = "The Persona expression isn't leaning negative right now."
    static let frustrationLadderL1 = "Interaction friction climbing — frustration (task friction)"
    static let frustrationLadderL1Fork = "Cancels and corrections aren't climbing enough to surface it."

    // MARK: F1 Composure-under-load fusion construct (US-C10, PRD v2 §4.2 F1)

    /// F1's RationalePanel mechanism paragraph. States the Gross & Levenson anchor, the
    /// ⚠️ no-autonomic-sensor caveat (behavioral proxy of a proxy), the named confound,
    /// and the 15 Hz / no-lie-detection boundary. Banned-substring-clean by construction
    /// (note: NEVER the words "concealing"/"concealment"/"genuine" — even in negation —
    /// because the deterministic linter can't read intent).
    static let composureRationale =
        "Marries a near-neutral Persona face to a behavioral arousal proxy climbing at "
        + "the same time — today a blink-rate rise beyond your own baseline; hand and "
        + "voice energy join later. Gross & Levenson 1993 found expressive suppression "
        + "shows up as a flat face while arousal rises, but that arousal was skin-"
        + "conductance — this app has NO autonomic sensor (no skin-conductance, heart-"
        + "rate or pupils), so it reads the BEHAVIORAL divergence only, a proxy of a "
        + "proxy. It surfaces \"composed but activated\" only when a calm face AND an "
        + "elevated proxy hold together for a few seconds. A naturally still face and a "
        + "truly calm one look identical here; your per-user baseline plus an "
        + "expressiveness gate reduce, not eliminate, that. The 15 Hz sampling cannot "
        + "read micro-expressions, keeping this well clear of lie-detection."

    /// The named confound F1 can never fully rule out (RationalePanel + narration).
    static let composureConfound =
        "A naturally still face and a truly calm one look identical here — a per-user "
        + "baseline and an expressiveness gate reduce, not eliminate, that."

    /// The short low-expresser note (the §5.4 tentative variant) — surfaced on the
    /// ladder's tentative rung and in the hedged narration.
    static let composureLowExpresserNote =
        "Your Persona baseline shows a narrow expressive range — this reading stays tentative."

    /// F1 ACTIVATION narration. The ONE grammar: expression estimate ("Persona face
    /// reads calm") + channel attribution ("blink rate is elevated" — the present eyes
    /// proxy) + the sanctioned divergence framing ("composed but activated; possible
    /// regulation") + a confidence word SEPARATE from intensity. NEVER "concealing." The
    /// "blink rate" wording is correct while eyes is the only live proxy; it generalizes
    /// when hands/voice land.
    static func composure(confidence: Double) -> String {
        "Your Persona face reads calm, but blink rate is elevated — "
        + "composed but activated; possible regulation. \(confidencePhrase(confidence))"
    }

    /// The low-expresser TENTATIVE variant of the F1 narration (§5.4) — same reading,
    /// plus the narrow-baseline hedge. Available for hedged narration and swept here.
    static func composureTentative(confidence: Double) -> String {
        "Your Persona face reads calm and blink rate is elevated — "
        + "composed but activated; possible regulation. \(composureLowExpresserNote) "
        + "\(confidencePhrase(confidence))"
    }

    /// F1's disambiguation-ladder rungs (US-C10, §6.6). The claim NARROWS: calm face →
    /// proxy elevated → divergence sustained; a tentative rung appears only under the
    /// §5.4 gate; and a PERMANENT ruled-out rung refuses the concealment/lie-detection
    /// reading (rendered greyed + struck — never a claim the app makes). All banned-clean.
    static let composureLadderL0 = "Persona face reads near-neutral"
    static let composureLadderL0Fork = "Waiting for a calm Persona face — it isn't near-neutral yet."
    static let composureLadderL1 = "Blink rate elevated vs your baseline"
    static let composureLadderL1Fork = "Blink rate isn't above your baseline yet."
    static let composureLadderL2 = "Divergence sustained — composed but activated; possible regulation"
    static let composureLadderL2Fork = "The calm-face-with-rising-arousal split hasn't held long enough to surface."
    static let composureLadderTentative = "Narrow expressive baseline — reading stays tentative"
    static let composureLadderTentativeFork =
        "A naturally still face and a truly calm one are hard to tell apart at a narrow baseline."
    /// The permanent refusal rung (worded to pass the deterministic banlist — it refuses
    /// the capability, never implies it).
    static let composureLadderRuledOut = "Hidden-feeling or lie detection"
    static let composureLadderRuledOutReason =
        "This app can't and won't read that — behavioral proxies only, sampled too slowly for micro-expressions."

    // MARK: F3 Fatigue ⇄ Engagement fusion construct (US-C11, PRD v2 §4.2 F3)

    /// F3's RationalePanel mechanism paragraph. States the ONE-coupled-axis design, the
    /// PERCLOS / Wierwille anchor, the session-accrual asymmetry, the named confound, and
    /// the non-diagnostic ceiling. Banned-substring-clean by construction (note: NEVER
    /// "diagnos…" even in negation — say "medical claim").
    static let fatigueEngagementRationale =
        "Reads your Persona's blink stream over time against your own resting rate — ONE "
        + "coupled axis, not two meters. Sustained blink suppression with steady eyes leans "
        + "engaged; a rising blink rate with prolonged eye closures (a PERCLOS-style burden) "
        + "leans the other way, and that fatigued side accrues the longer the session runs "
        + "(Wierwille 1994; Dinges PERCLOS). Blink is ambiguous alone, so this is an "
        + "attention / alertness axis, not an emotion — boredom and a calm low-arousal state "
        + "look identical here. It never makes a medical claim; at most it says alertness is "
        + "declining and suggests a break."

    /// The named confound F3 can never rule out (RationalePanel + the ladder).
    static let fatigueEngagementConfound =
        "Boredom and a calm low-arousal state look similar here — this is an attention / "
        + "alertness axis, not an emotion."

    /// The two surfaced POLE labels (the coupled meter's `namedState`). Non-diagnostic:
    /// the negative pole is "alertness declining", never a drowsiness/medical label.
    static let fatigueEngagementEngagedState = "engaged"
    static let fatigueEngagementFatiguedState = "alertness declining"

    /// F3 ACTIVATION narration, per pole. Keeps the Persona framing, cites present signals
    /// (the engaged copy names the suppressed blink rate; the fatigued copy names the
    /// rising cues from the event's evidence), states a confidence word SEPARATE from
    /// intensity, and closes with the sanctioned nudge on the fatigued side. Never a
    /// medical claim.
    static func fatigueEngagement(engaged: Bool, evidence: [SignalRef], confidence: Double) -> String {
        if engaged {
            return "Your Persona's blink rate is suppressed and your eyes are steady — "
                + "consistent with focused engagement. This is an attention / alertness "
                + "axis, not an emotion. \(confidencePhrase(confidence))"
        }
        let cues = evidence.filter { $0 != .sessionMinutes }
        let named = cues.isEmpty ? "blink rate and eye closures"
                                 : cues.map(\.displayName).joined(separator: " and ")
        return "Your Persona's \(named) are rising over the session — alertness declining; "
            + "consider a break. This is an attention / alertness axis, not an emotion. "
            + "\(confidencePhrase(confidence))"
    }

    /// F3's disambiguation-ladder rungs (US-C11, §6.6). The claim NARROWS: blink trend →
    /// closures / PERCLOS burden → session accrual → the pole verdict (or the ambiguous
    /// dead-band fork). All banned-clean; "alertness declining" / "consider a break" is the
    /// ceiling.
    static let fatigueEngagementLadderL0 = "Blink rate moving vs your baseline"
    static let fatigueEngagementLadderL0Fork = "Blink rate is near your baseline — no clear lean either way."
    static let fatigueEngagementLadderL1 = "Prolonged eye closures present — a PERCLOS-style burden"
    static let fatigueEngagementLadderL1Fork = "No prolonged eye closures — nothing tugging toward the fatigued side."
    /// L2 carries the live session minutes ("over [X] min") — the accrual rung.
    static func fatigueEngagementLadderL2(minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 1
            ? "Sustained over \(m) min — the fatigued side accrues with time on task"
            : "Sustained long enough to lean"
    }
    static let fatigueEngagementLadderL2Fork = "The lean hasn't held long enough to surface yet."
    /// The pole verdicts (resolved) and the neutral dead-band fork (ambiguous).
    static let fatigueEngagementVerdictEngaged = "Blink suppression and steady eyes — consistent with focused engagement"
    static let fatigueEngagementVerdictFatigued = "Alertness declining — consider a break"
    static let fatigueEngagementVerdictNeutral = "No strong lean either way"
    static let fatigueEngagementVerdictNeutralFork =
        "Steady state — blink isn't clearly suppressed or rising, so neither engagement nor declining alertness surfaces."

    // MARK: F2 Cognitive load / effort fusion construct (US-D14a, PRD v2 §4.2 F2)

    /// The surfaced named state (the chip label the hub sets on latch). EFFORT / LOAD only —
    /// NEVER "stress" (banned). An attention axis, not an emotion.
    static let cognitiveLoadState = "high effort/load"

    /// F2's RationalePanel mechanism paragraph. States the E×I MVV + hands/head enhance, the
    /// Omnicept mean+variance anchor, the below-resting SIGN discipline (stilling = load, motion
    /// isn't), and the confound. Banned-substring-clean (never "stress"/"anxiety").
    static let cognitiveLoadRationale =
        "Combines your Persona's suppressed blinks with slower, more-corrected interaction — and, "
        + "when live, still hands and a still head — into one calibrated load meter with a "
        + "variance band, the way HP Omnicept ships a mean-plus-variance cognitive-load reading "
        + "(Chua 2024; Doherty-Sneddon & Phelps 2005: looking away is load, not evasion). Load "
        + "shows up as stilling and slowing measured against your OWN resting baseline, so "
        + "ordinary calm and brisk motion both read low. It is an attention / effort axis, not an "
        + "emotion: high effort and unease look alike here, so it never claims more than moderate "
        + "confidence."

    /// The named confound F2 can never rule out (RationalePanel + the honesty sweep).
    static let cognitiveLoadConfound =
        "High effort and unease look alike here — a hard task and an uneasy one drive the same "
        + "signals — so this is an attention / load axis, not an emotion."

    /// The load cue for one contributing signal — each phrase CONTAINS the signal's display
    /// name so the narrated attribution both reads naturally AND cites a present signal (the
    /// honesty law). Names the mechanical cue, never a felt state.
    static func cognitiveLoadCue(_ s: SignalRef) -> String {
        switch s {
        case .blinkRate: return "blink rate suppressed"
        case .inputTempo: return "input tempo slower"
        case .cancelRate: return "cancel rate up"
        case .selfTouchRate: return "self-touch rate up"
        case .gestureEnergy: return "gesture energy low"
        case .handAperture: return "hand aperture tight"
        case .headMotionEnergy: return "head-motion energy low"
        default: return s.displayName
        }
    }

    /// F2 ACTIVATION narration — the attribution sentence BUILT FROM the actually-contributing
    /// signals (the PRD's attribution law: list only live, loading cues). Grammar: the cited
    /// cues + the "high effort/load" state + the "attention axis, not an emotion" framing +
    /// the Persona grounding + a confidence word separate from intensity. NEVER "stress."
    static func cognitiveLoad(evidence: [SignalRef], confidence: Double) -> String {
        let cues = evidence.map(cognitiveLoadCue)
        let list = cues.isEmpty ? "several quiet signals" : cues.joined(separator: ", ")
        return "Your Persona and enabled lenses read \(list) — \(cognitiveLoadState) "
            + "(an attention axis, not an emotion). \(confidencePhrase(confidence))"
    }

    // MARK: F4 Frown + head-down disambiguation fusion construct (US-D14a, PRD v2 §4.2 F4)

    /// F4's RationalePanel mechanism paragraph. States the ambiguity, the AU4-imposter
    /// correction (Step 0), the narrowing ladder, and the gaze-blind ceiling. The felt word
    /// "shame" appears ONLY here, as an explicit hedged gloss — never in a live state name.
    /// Banned-substring-clean (never "fake"/"faked" — say "mimic").
    static let frownHeadDownRationale =
        "A lowered brow is ambiguous — effort, displeasure, or dejection — and looking down can "
        + "mimic a lowered brow entirely (Witkower & Tracy 2019/2020). So this never asserts an "
        + "emotion: it corrects for the head-down tilt first, then runs a narrowing ladder — brow "
        + "morphology, then whether the body reads approach or withdrawal (Harmon-Jones & Allen "
        + "1998), then a low-confidence head-orientation proxy — and surfaces a hedged LEAN, never "
        + "a label. Because we read head orientation and not gaze, the concentration-versus-"
        + "withdrawal split (the felt word \"shame\" only as a hedged gloss) stays low-confidence "
        + "and may remain unresolved. A disambiguation aid, not a verdict."

    /// The named confound F4 can never fully rule out (RationalePanel + the honesty sweep).
    static let frownHeadDownConfound =
        "We read head orientation, not gaze, so the concentration-versus-withdrawal split can't "
        + "be fully resolved."

    /// The four hedged LEAN names (the chip label the hub sets on latch + the self-test's exact
    /// strings). Each is a LEAN, never a discrete-emotion label. Banned-clean.
    static let frownHeadDownLeanEffort = "leans focused effort"
    static let frownHeadDownLeanApproach = "leans displeasure-approach"
    static let frownHeadDownLeanWithdrawal = "leans dejection-withdrawal"
    static let frownHeadDownLeanAmbiguous = "ambiguous — multiple readings possible"

    /// The lean name for a computed `F4Lean` — shared by the (visionOS) mode's `namedState`
    /// and the (cross-platform) narrator, so both speak the same lean vocabulary.
    static func frownHeadDownLeanName(_ lean: F4Lean) -> String {
        switch lean {
        case .effort: return frownHeadDownLeanEffort
        case .displeasureApproach: return frownHeadDownLeanApproach
        case .dejectionWithdrawal: return frownHeadDownLeanWithdrawal
        case .ambiguous: return frownHeadDownLeanAmbiguous
        }
    }

    /// The lean CLAUSE for the narrated sentence (the "[X]" the ladder resolves to).
    static func frownHeadDownLeanClause(_ lean: F4Lean) -> String {
        switch lean {
        case .effort: return "it leans focused effort"
        case .displeasureApproach: return "it leans displeasure — approach-motivated"
        case .dejectionWithdrawal: return "it leans dejection — withdrawal"
        case .ambiguous: return "it stays ambiguous — multiple readings are possible"
        }
    }

    /// F4 ACTIVATION / lean-transition narration — hedged and confound-visible. Grammar: the
    /// corrected lowered brow (cites the present AU4) + the head-down context + the resolved
    /// LEAN + the gaze caveat + a confidence word separate from intensity. NEVER a label,
    /// NEVER "angry"; banned-clean.
    static func frownHeadDown(lean: F4Lean, evidence: [SignalRef], confidence: Double) -> String {
        let head = evidence.contains(.headPitch) ? "with your head down" : "with your head level"
        return "Your Persona shows a lowered brow (\(SignalRef.au4.displayName)) \(head) — after "
            + "correcting for the tilt, \(frownHeadDownLeanClause(lean)). We can't see your gaze, "
            + "so this may stay unresolved. \(confidencePhrase(confidence))"
    }

    /// F4's disambiguation-ladder rungs (§6.6) — the progressive-narrowing stepper. The claim
    /// narrows L0→L5; a ruled-out rung refuses the false-anger label. All banned-clean (note:
    /// NEVER "fake"/"faked" even about the imposter — say "mimic"). "anger" appears only inside
    /// the ruled-out rung, which REFUSES the label.
    static let frownHeadDownL0HeadDown = "Brow looks lowered, but your head is down — correcting for that"
    static let frownHeadDownL0Level = "Brow reads lowered — your head is level, no tilt to correct for"
    static let frownHeadDownL1 = "Lowered brow: effort, displeasure or dejection — ambiguous"
    static let frownHeadDownL1Fork = "The companion muscles (a lid raise, an inner-brow raise, a downturned mouth) haven't picked a direction yet."
    static let frownHeadDownL1Anger = "Lowered brow with a lid raise — reads as displeasure (approach-motivated)"
    static let frownHeadDownL1Sadness = "Lowered brow with an oblique inner-brow and a downturned mouth — reads as dejection"
    static let frownHeadDownL1Effort = "A lowered brow alone, no lid or mouth companions — reads as effort"
    static let frownHeadDownL2 = "Approach or withdrawal? Motor energy and head orientation should tell."
    static let frownHeadDownL2Fork = "Motor energy and head lean are too weak to split approach from withdrawal."
    static let frownHeadDownL2Approach = "Body reads engaged / expansive — leans displeasure, approach-motivated"
    static let frownHeadDownL2Withdrawal = "Body reads low-motor / collapsed — leans dejection, withdrawal"
    static let frownHeadDownL3 = "Head-orientation proxy — toward your content, or down-and-away?"
    static let frownHeadDownL3Fork = "Your head is down but not turned away — with direct gaze this is concentration, but we can't see your gaze, so this may stay unresolved."
    static let frownHeadDownL3Toward = "Head oriented toward your content — leans focused effort (low confidence — head orientation is not gaze)"
    static let frownHeadDownL3Withdrawal = "Head turned down-and-away — leans withdrawal (low confidence — head orientation is not gaze)"
    static let frownHeadDownL4 = "Blink / load — are blinks suppressed?"
    static let frownHeadDownL4Loaded = "Blinks suppressed — elevated load supports the effort reading"
    static let frownHeadDownL4Fork = "Blink rate is near your baseline — no clear load signal."
    static let frownHeadDownL4NeedsEyes = "Enable the eyes lens to add the blink / load step."
    static func frownHeadDownL5(minutes: Double, friction: Bool) -> String {
        let m = Int(minutes.rounded())
        let base = "Over \(m) min on task"
        return friction ? "\(base), with corrections climbing — long-session effort"
                        : "\(base) — long-session effort"
    }
    static let frownHeadDownL5Early = "Early in the session — no time-on-task signal yet"
    static let frownHeadDownL5Fork = "Not long enough on task to read session effort."
    /// The PERMANENT ruled-out rung (worded to pass the deterministic banlist — "mimic", never
    /// "fake"; it refuses the anger label rather than asserting one).
    static let frownHeadDownRuledOut = "A single \"anger\" label from a lowered brow"
    static let frownHeadDownRuledOutReason =
        "The head-down tilt can mimic it — corrected at step 0, so a lowered brow never reads as anger by itself."

    // MARK: F6 Corroborated Positivity fusion construct (US-D14b, PRD v2 §4.2 F6)

    /// The surfaced named state (the chip label the hub sets on latch). "echoed across
    /// channels" — NEVER "genuine" / "fake" (both banned by design; F6 sits on exactly that
    /// refused boundary, §4.5 #1).
    static let corroboratedPositivityEchoedState = "positivity echoed across channels"

    /// F6's RationalePanel mechanism paragraph. States the Girard artifact + the refused
    /// smile-authenticity combination this REPLACES, the laughter-corroboration mechanism, the
    /// windowed-vs-immersive availability, and the confound. Banned-substring-clean by
    /// construction (NEVER "genuine" / "fake" — say "authenticity" / "echoed").
    static let corroboratedPositivityRationale =
        "Checks whether a positive Persona expression is ECHOED by your other channels — a recent "
        + "on-device laughter sound, plus head-motion and gesture energy when the immersive aura "
        + "is open. It reports \"echoed / not echoed across channels\", never whether a smile is "
        + "authentic: AU6/Duchenne is an intensity artifact, not an authenticity signal (Girard "
        + "2021), so smile-authenticity is on the refused list (§4.5 #1) and this is its honest "
        + "replacement. Laughter works in the plain window; the head and gesture echo need the "
        + "aura open, so it is richer there. An absence of echo is simply un-corroborated, never "
        + "a verdict. Confound: a social smile can be high-arousal and laughter-accompanied too."

    /// The named confound F6 can never rule out (RationalePanel + narration).
    static let corroboratedPositivityConfound =
        "A social smile can be high-arousal and laughter-accompanied too — an echo across "
        + "channels corroborates the positive expression, it doesn't prove a feeling."

    /// F6's disambiguation-ladder rungs (§6.6). L0 positive expression → L1 laughter within the
    /// window → L2 motion/gesture echo → the "echoed" verdict; "not echoed" appears ONLY as the
    /// verdict FORK (a null, never a fired state). All banned-clean.
    static let corroboratedPositivityL0 = "Persona expression reads positive"
    static let corroboratedPositivityL0Fork = "The Persona expression isn't clearly positive right now."
    static let corroboratedPositivityL1 = "A laugh-like sound registered recently"
    static let corroboratedPositivityL1Fork = "No laugh-like sound heard within the last 30 seconds."
    static let corroboratedPositivityL2 = "Head motion and gesture energy echo it"
    static let corroboratedPositivityL2Fork = "No head-motion or gesture echo yet (richer with the immersive aura open)."
    static let corroboratedPositivityVerdict = "Positivity echoed across channels"
    static let corroboratedPositivityVerdictNotEchoed = "Not echoed across channels"
    static let corroboratedPositivityVerdictFork =
        "A positive expression on its own — un-corroborated, which is a null, not a verdict about whether it's real."

    /// F6 ACTIVATION narration. Grammar: the positive expression + the corroborating channels
    /// (cites the present signals — recent laughter, head/gesture echo) + the "echoed" framing +
    /// a confidence word separate from intensity. NEVER "genuine" / "fake"; Persona-grounded.
    static func corroboratedPositivity(evidence: [SignalRef], confidence: Double) -> String {
        let channels = evidence.filter { $0 != .valence }.map(\.displayName)
        let list = channels.isEmpty ? "your other channels" : channels.joined(separator: ", ")
        return "Your Persona's positive expression is echoed across channels — \(list) — "
            + "corroboration, not a claim that a smile is real. \(confidencePhrase(confidence))"
    }

    // MARK: F10 Approach ⇄ Withdrawal fusion construct (US-D14b, PRD v2 §4.2 F10 / §4.3)

    /// The two surfaced POLE labels (the coupled meter's namedState) — bare DIRECTION language;
    /// the context-sensitive tie-break LEAN lives in the narration. Banned-clean.
    static let approachWithdrawalApproachState = "movement leans approach"
    static let approachWithdrawalWithdrawalState = "movement leans withdrawal"

    /// F10's RationalePanel mechanism paragraph. States the §4.3 valence dissociation (approach
    /// vs withdrawal), the head-motor MVV, the tie-break, and the coarse-read hedges. Banned-clean.
    static let approachWithdrawalRationale =
        "Reads motivational DIRECTION from your head — motor energy and orientation, plus an "
        + "expansive-gesture vote when your hands are live — as one coupled approach ⇄ withdrawal "
        + "axis. Direction is dissociable from valence (Harmon-Jones & Allen 1998): a negative "
        + "expression that APPROACHES leans the displeasure side, one that WITHDRAWS leans the "
        + "dejection side — the split valence alone can't make. It is a coarse behavioral read "
        + "(head orientation is not gaze, motor is a proxy), so it stays low-confidence and speaks "
        + "in leans, never a discrete emotion label."

    static let approachWithdrawalConfound =
        "Low motor with a level head can read as mild withdrawal when you are simply still — this "
        + "is a coarse direction proxy, a lean, not a feeling."

    static let approachWithdrawalL0 = "Head motion and orientation read a direction"
    static let approachWithdrawalL0Fork = "Motor energy and head lean are too weak to read a direction."
    static let approachWithdrawalVerdictNeutral = "No clear approach or withdrawal lean"
    static let approachWithdrawalVerdictNeutralFork = "The direction is near neutral — neither approach nor withdrawal leans out."

    /// F10 ACTIVATION / pole narration — the §4.3 CONTEXT-SENSITIVE tie-break. When the face is
    /// currently NEGATIVE the lean names the displeasure / dejection side (a LEAN, reusing F4's
    /// hedged vocabulary — never a discrete label, never "angry"/"sad"); a neutral / positive
    /// face gets direction language only. Cites the present head signal + a confidence word;
    /// Persona-grounded. Banned-clean.
    static func approachWithdrawal(approach: Bool, faceNegative: Bool, evidence: [SignalRef], confidence: Double) -> String {
        let cue = evidence.first?.displayName ?? SignalRef.headMotionEnergy.displayName
        let lean: String
        if faceNegative {
            lean = approach
                ? "a negative expression that approaches — leans displeasure, approach-motivated"
                : "a negative expression that withdraws — leans dejection, withdrawal"
        } else {
            lean = approach ? "movement leans approach / engagement" : "movement leans withdrawal"
        }
        return "Your Persona's \(cue) reads \(lean) — a coarse direction lean, not a feeling. "
            + "\(confidencePhrase(confidence))"
    }

    // MARK: F8 Dominance display fusion construct (US-D14b, PRD v2 §4.2 F8 / §3.4)

    /// The two surfaced POLE labels — DISPLAY language only (a posture on the dominance axis,
    /// never a felt emotion). Banned-clean.
    static let dominanceExpansionState = "expansion display"
    static let dominanceContractionState = "contracted / withdrawn display"

    static let dominanceRationale =
        "Reads your head's dominance-lean over time as one coupled axis — head-back and level "
        + "(an expansion display) versus head-down and turned away (a contracted / withdrawn "
        + "display). These are innate nonverbal displays (Tracy & Matsumoto 2008), but we read "
        + "head ORIENTATION only — not your gaze and not your torso — so this is a display on the "
        + "dominance axis, never a felt emotion, and it stays low-confidence. Sustained means held "
        + "for a few seconds, not a fleeting tilt. No head-tilt or nod dictionary."

    static let dominanceConfound =
        "Head orientation is not gaze and we can't see your torso — this describes a posture "
        + "display on the dominance axis, not a felt emotion."

    static let dominanceL0 = "A clear, sustained head dominance lean"
    static let dominanceL0Fork = "The head is near your neutral pose — no clear dominance lean either way."
    static let dominanceVerdictNeutral = "No dominance display either way"
    static let dominanceVerdictNeutralFork = "The head lean isn't sustained enough to read a display."

    /// F8 ACTIVATION / pole narration. DISPLAY language + the gaze/torso hedge + the cited head
    /// signals + a confidence word; Persona-grounded. Banned-clean; never a felt emotion.
    static func dominance(expansion: Bool, evidence: [SignalRef], confidence: Double) -> String {
        let cues = evidence.map(\.displayName).joined(separator: ", ")
        let display = expansion
            ? "head-back and level — an expansion display"
            : "head-down and turned away — a contracted / withdrawn display"
        return "Your Persona's head pose (\(cues)) reads \(display) on the dominance axis — head "
            + "orientation only, not gaze or your torso; a posture display, not a felt emotion. "
            + "\(confidencePhrase(confidence))"
    }

    // MARK: F9 Expansive display fusion construct (US-D14b, PRD v2 §4.2 F9 / §4.5 #7)

    /// The surfaced named state (the chip label the hub sets on latch) — labelled HEAD-ONLY.
    static let expansiveDisplayState = "expansive high-dominance display (head-only)"

    /// F9's RationalePanel mechanism paragraph. States the innate-display anchor, the head-only /
    /// torso hedge, "pride" ONLY as a hedged gloss, and the REFUSED power-pose causal claim
    /// (§4.5 #7). Banned-substring-clean (NEVER "genuine" — say "a … display is rare").
    static let expansiveDisplayRationale =
        "Fires only on a STRONG, sustained head-back expansion together with a non-negative face — "
        + "the innate high-dominance display (Tracy & Matsumoto 2008). It is labelled head-only "
        + "because we can't see your torso, and the expansive posture is a whole-body display. It "
        + "is a display on the dominance axis, loosely glossed \"pride\", NOT the felt emotion and "
        + "NOT a power-pose claim: an expansive pose is never said to cause confidence, dominance, "
        + "or hormone changes (Carney 2016 disavowal; refused §4.5 #7). A high-dominance display "
        + "is rare, so the bar is deliberately high and conservative."

    static let expansiveDisplayConfound =
        "Head-only and torso-blind — an expansive head-back can be a reach or a stretch, so this "
        + "reports a display on the dominance axis, not the felt emotion \"pride\"."

    static let expansiveDisplayL0 = "Strong, sustained head-back expansion"
    static let expansiveDisplayL0Fork = "The head-back expansion isn't strong or sustained enough for this display."
    static let expansiveDisplayL1 = "Face reads non-negative"
    static let expansiveDisplayL1Fork = "The face reads negative — an expansive head-back with a negative face is not this display."
    static let expansiveDisplayVerdict = "Expansive high-dominance display — head-only, we can't see your torso"
    static let expansiveDisplayVerdictNotYet = "No expansive high-dominance display yet"
    static let expansiveDisplayVerdictNotYetFork = "The strong-expansion-with-a-non-negative-face conjunction hasn't held long enough."
    /// The PERMANENT ruled-out rung — the power-pose causal claim, refused (§4.5 #7). Banned-clean.
    static let expansiveDisplayRuledOut = "A power-pose claim about confidence or hormones"
    static let expansiveDisplayRuledOutReason =
        "Refused — an expansive pose doesn't cause those (Carney 2016), and your torso isn't sensable anyway."

    /// F9 ACTIVATION narration. Grammar: the strong expansion + the non-negative face (cites the
    /// present signals) + the head-only display + the "pride" gloss + the power-pose refusal + a
    /// confidence word. Persona-grounded; banned-clean; NO power-pose causal claim.
    static func expansiveDisplay(evidence: [SignalRef], confidence: Double) -> String {
        let cues = evidence.map(\.displayName).joined(separator: ", ")
        return "Your Persona reads a strong head-back expansion with a non-negative face (\(cues)) — "
            + "an expansive high-dominance display, head-only (we can't see your torso), loosely "
            + "glossed \"pride\", not the felt emotion and not a power-pose claim. \(confidencePhrase(confidence))"
    }

    // MARK: F5 Corroborated arousal fusion construct (US-D14b, PRD v2 §4.2 F5)

    /// F5's RationalePanel mechanism paragraph. States the ≥2-channel corroboration, the
    /// DISTINCTION from F1 (no calm-face requirement), the "needs a second arousal channel"
    /// low-signal state, and the level-not-a-feeling honesty. Banned-clean (never "concealment").
    static let covertArousalRationale =
        "Watches your NON-face arousal channels — blink rate, hand energy and self-touch, head "
        + "motion, vocal pitch — and speaks only when TWO or more are elevated together: "
        + "corroborated arousal. It is the arousal sibling of composure-under-load, but WITHOUT "
        + "that construct's calm-face requirement — it reads the same behavioral proxies whether "
        + "the Persona expression is calm, expressive, or unseen. Arousal is a level, not a direction or a "
        + "feeling, and with no autonomic sensor these are behavioral proxies — so it stays "
        + "low-confidence and speaks only of corroborated activation, never a feeling. It needs a "
        + "second arousal channel — enable hands, head, or voice alongside the eyes lens."

    static let covertArousalConfound =
        "Arousal is a level, not a direction — two elevated channels corroborate activation, not "
        + "which emotion, and never a feeling."

    static let covertArousalL0 = "Two or more non-face arousal channels elevated together"
    static let covertArousalNeedsSecond = "Needs a second arousal channel — enable hands, head, or voice alongside the eyes lens."
    static let covertArousalL1 = "Held across the window?"
    static let covertArousalL1Fork = "The corroboration hasn't held long enough to surface."
    static let covertArousalVerdict = "Corroborated arousal — multiple channels elevated together"

    /// F5 ACTIVATION narration. Grammar: the agreeing non-face channels (cites the present
    /// signals) + the corroborated-arousal framing + the level-not-a-feeling hedge + a confidence
    /// word. Persona-grounded; banned-clean; arousal is a LEVEL, never a direction or a feeling.
    static func covertArousal(evidence: [SignalRef], confidence: Double) -> String {
        let cues = evidence.map(\.displayName).joined(separator: ", ")
        let list = cues.isEmpty ? "your non-face channels" : cues
        return "Your Persona's non-face channels agree — \(list) are elevated together — "
            + "corroborated arousal (a level, not a feeling). \(confidencePhrase(confidence))"
    }

    // MARK: Uncertainty grammar + fused aura (PRD v2 §6.4 / §6.5)

    /// The fused-aura toggle label + its ONE honest line (surfaced under the fusion section).
    /// Reflects, never praises — the aura mirrors the reading, it does not reward it.
    static let auraFusedToggleLabel = "Aura follows fused signals"
    static let auraFusedExplainer =
        "Hue = expression valence, pulse = combined activation, dimness = uncertainty."

    /// The visual-only arousal quantile-dotplot title + caption (§6.5). Arousal from the
    /// face alone is a wide, low-agreement axis (visual-only CCC ≈ 0.26); the dots FAN OUT
    /// as confidence falls. A DISPLAY of the reading's uncertainty, never a new measurement.
    static let arousalWideAxisTitle = "Arousal — visual-only, wide by nature"
    static let arousalWideAxisCaption =
        "About 15 dots span the plausible arousal range and fan out as confidence falls — "
        + "visual-only arousal is a wide, low-agreement axis. A display of how uncertain the "
        + "reading is, not a new measurement."

    /// The eyes lens's forked-ambiguity prong labels (§3.2 dual-reading law). Same blink
    /// signal, two readings — the ForkedMeter shows BOTH because blink rate alone can't choose.
    static let eyesForkLowLabel = "engaged / early in a task"
    static let eyesForkHighLabel = "fatigue / mind-wandering"
    /// The fork's explainer paragraph (moved here from a
    /// hardcoded view string so it rides the banlist; "tension" is the non-clinical word for
    /// the elevated-arousal arm the literature also ties to blink-rate rises).
    static let eyesForkExplainer =
        "Low blink rate → engaged  OR  early in a task.\n"
        + "High blink rate → fatigue / tension  OR  mind-wandering.\n"
        + "Strong in fusion, weak alone — so both readings are shown when it's ambiguous."

    /// The multi-label chip prefix — "likely {A, B}" (or "likely A" when a clear winner). The
    /// emotion names come from `Emotion.displayName`; this is only the leading word.
    static let multiLabelPrefix = "likely"

    // MARK: ESM ground-truth loop + conformal sets (US-E17, PRD v2 §5.7 / §9.1 M6)

    /// The manual "log how you feel" button label (near the insight feed).
    static let selfReportManualButton = "How do you feel?"

    /// The gentle, NON-interruptive banner shown after a settled state-shift (PRD OQ14:
    /// cooldown-gated, dismissible, never a modal). Optional by design.
    static let selfReportBannerText = "Noticed a shift — want to log how you actually feel? It’s optional."
    static let selfReportBannerCTA = "Log it"
    static let selfReportBannerDismiss = "Not now"

    /// The self-report sheet copy. One tap on Save (the slider alone) is a complete report.
    static let selfReportTitle = "How do you feel, really?"
    static let selfReportSubtitle =
        "A one-tap check-in. Your own words are the ground truth this app calibrates against — the slider alone is enough; labels are optional."
    static let selfReportValencePrompt = "How pleasant does right now feel?"
    static let selfReportValenceLow = "Unpleasant"
    static let selfReportValenceHigh = "Pleasant"

    /// A live pleasantness word for the slider readout (−1 … +1). Mirrors Apple's
    /// State-of-Mind valence banding; all words are banlist-clean.
    static func valenceWord(_ v: Double) -> String {
        switch v {
        case ..<(-0.6): return "Very unpleasant"
        case ..<(-0.2): return "Unpleasant"
        case ..<0.2: return "Neutral"
        case ..<0.6: return "Pleasant"
        default: return "Very pleasant"
        }
    }
    static let selfReportLabelsPrompt = "Add a word or two (optional)"
    static let selfReportSaveButton = "Save report"
    static let selfReportSavingButton = "Saving…"
    /// Purpose-first Health note (shown in the sheet before the first system prompt, §6.8).
    static let selfReportHealthNote =
        "If you allow it, this is also saved to Apple Health as a State of Mind sample — your data, following your Health and iCloud settings. AffectLens itself never sends it anywhere."

    // Health write outcomes — the banlist-clean reason a report stayed local-only (also
    // the empirical answer to the PRD §10 WRITE-availability verify-item, logged in
    // `HealthWriter`). Never leaks the raw Apple error into UI copy.
    static let healthUnavailableReason = "Health isn’t available on this device — your report stays on this device only."
    static let healthDeniedReason = "Health sharing wasn’t allowed — your report stays on this device only."
    static let healthSaveFailedReason = "Couldn’t reach Health just now — your report stays on this device only."

    // The ground-truth section (home). Per-user framing ALWAYS — never a population claim.
    static let groundTruthTitle = "Ground truth — for you, on this device"
    static let groundTruthBlurb =
        "Your 1-tap reports calibrate this app to how YOU actually feel. Never a population claim; nothing here leaves your device unless you save it to Health."
    static let groundTruthEmpty = "No reports yet — tap “How do you feel?” to start your own calibration."

    /// The per-user CCC line (inferred valence vs your self-report). Explicitly per-user.
    static func groundTruthCCC(ccc: Double, pairedCount: Int) -> String {
        "Your inferred valence tracks your reports at CCC \(twoDecimals(ccc)) over \(pairedCount) paired reports — for you, on this device."
    }
    static func groundTruthCCCNeedsMore(pairedCount: Int) -> String {
        "\(pairedCount) paired report\(pairedCount == 1 ? "" : "s") so far — at least 3 are needed to estimate valence agreement for you."
    }

    /// The conformal-set status line (feeds the hero chip when calibrated).
    static func conformalLearning(have: Int, need: Int) -> String {
        "Uncertainty set: learning — \(have) of \(need) labelled reports before your calibrated “likely {…}” set turns on."
    }
    static func conformalCalibrated(sampleCount: Int) -> String {
        "Uncertainty set: calibrated for you from \(sampleCount) labelled reports (90% coverage target)."
    }

    /// The Health-status line for the most recent report.
    static let groundTruthHealthSaved = "Last report: saved to Apple Health."
    static func groundTruthHealthLocalOnly(reason: String) -> String { "Last report: \(reason)" }

    // MARK: Lab Mode (US-lab, §6.8) — the workbench copy. Numeric tables + diffs are
    // technical (fine); these prose strings carry the Persona / on-device framing.

    static let labBlurb =
        "A live workbench — everything reads from your Persona and stays on this device. The channels side by side, the raw event bus + fusion audit, a deterministic replay of recorded traces, and the engine knobs — for spotting congruence and conflict as they happen."
    static let labColumnsNote =
        "Live lenses are bright; the rest are greyed with an honest reason. Detach any column into its own window to set it beside the face."
    static let labEventLogNote =
        "The raw AffectEvent bus (newest first) and the per-channel reliability audit — the numbers behind every fused reading. State-shifts are highlighted."
    static let labReplayNote =
        "Replays a recorded golden trace through the SAME downstream pipeline the CI fixture uses — deterministic, so the same trace always reads the same. Scrub the timeline, or run two configs and diff them."
    static let labEngineKnobsNote =
        "These change live inference — the defaults are the shipped values. Nothing here is persisted beyond the toggle you set."
    static let labDetachedFaceNote =
        "The face dashboard owns the camera in the main window, so this detached view is a read-only summary. Detach the other lenses here to compare them against the face."

    private static func twoDecimals(_ x: Double) -> String { String(format: "%.2f", x) }
}
