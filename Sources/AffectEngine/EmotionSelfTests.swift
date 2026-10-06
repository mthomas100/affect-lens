//
//  EmotionSelfTests.swift
//  AffectLens
//
//  Debug-build sanity checks for the pure emotion math (classifier prototypes
//  and temporal hysteresis), executed once at launch. Failures trap in debug
//  so regressions are caught the moment the app starts.
//

import Foundation
import CoreGraphics
#if os(visionOS) || os(macOS)
import HealthKit
#endif

#if (os(visionOS) || os(macOS)) && DEBUG

enum EmotionSelfTests {

    static func runAll() {
        classifierPrototypes()
        temporalHysteresis()
        intensityGrading()
        distributionMath()
        pitchCorrection()
        channelReadingTests()
        affectHubSpine()
        analysisFanOut()
        baselineStore()
        blinkDetection()
        interactionDynamics()
        lensRegistryTests()
        fusionRegistryScaffold()
        constructHysteresis()
        f7Frustration()
        f1Composure()
        f3FatigueEngagement()
        motivationalDirection()
        f2CognitiveLoad()
        f4Ladder()
        f6Corroborated()
        f10ApproachWithdrawal()
        f8Dominance()
        f9Expansive()
        f5CovertArousal()
        registryHonestyLint()
        ladderModel()
        changePointDetection()
        narratorHonesty()
        eventBus()
        goldenTraceReplay()
        traceSchemaNoPixels()
        logPoolWeights()
        temperatureScaling()
        confidenceAlgebra()
        vaTransformSeam()
        congruenceEngine()
        prosodyMath()
        handKinematics()
        headPose()
        thermalGovernor()
        uncertaintyWidgets()
        esmAndConformal()
        labReplay()
        print("✅ EmotionSelfTests: all checks passed")
    }

    private static func classifierPrototypes() {
        let cases: [(AUVector, Emotion)] = [
            ([.au12: 0.8, .au6: 0.5], .happiness),
            ([.au1: 0.6, .au2: 0.7, .au5: 0.7, .au26: 0.6], .surprise),
            ([.au4: 0.7, .au7: 0.5, .au23: 0.6], .anger),
            ([.au15: 0.6, .au1: 0.4, .au4: 0.3], .sadness),
            ([.au9: 0.7, .au15: 0.3, .au7: 0.2], .disgust),
            ([.au1: 0.5, .au2: 0.5, .au4: 0.5, .au5: 0.6, .au20: 0.6, .au26: 0.3], .fear),
            ([.auUnilateral: 0.7, .au23: 0.2], .contempt),
            ([:], .neutral),
        ]
        for (au, expected) in cases {
            let result = EmotionClassifier.classify(au).dominant.emotion
            assert(
                result == expected,
                "EmotionSelfTests: AU vector \(au) classified as \(result), expected \(expected)"
            )
        }
    }

    private static func temporalHysteresis() {
        var smoother = TemporalSmoother()
        let happy = EmotionDistribution(normalizing: [.happiness: 0.9, .neutral: 0.1])

        // A single frame must NOT flip the stable label (hysteresis).
        let afterOne = smoother.update(with: happy).dominant
        assert(afterOne == .neutral, "EmotionSelfTests: label flipped after a single frame")

        // A sustained signal must flip it within ~10 frames.
        var final: Emotion = afterOne
        for _ in 0..<10 {
            final = smoother.update(with: happy).dominant
        }
        assert(final == .happiness, "EmotionSelfTests: sustained happiness not adopted, got \(final)")
    }

    private static func intensityGrading() {
        // Raw evidence scores must grow with expression strength.
        let mild = EmotionClassifier.scores(for: [.au12: 0.3])[.happiness] ?? 0
        let strong = EmotionClassifier.scores(for: [.au12: 0.9, .au6: 0.6])[.happiness] ?? 0
        assert(strong > mild, "EmotionSelfTests: intensity not monotone (\(mild) vs \(strong))")

        assert(EmotionClassifier.expressionEnergy(for: [:]) == 0, "EmotionSelfTests: rest energy not zero")
        assert(EmotionClassifier.expressionEnergy(for: [.au12: 0.9, .au26: 0.8]) > 0.5,
               "EmotionSelfTests: strong expression energy too low")

        assert(EmotionIntensity.adjective(0.1) == "Barely", "EmotionSelfTests: adjective scale broken")
        assert(EmotionIntensity.adjective(0.95) == "Extremely", "EmotionSelfTests: adjective scale broken")
    }

    /// US-A0 — the AU4 head-pitch correction (the Witkower "AU4 imposter").
    private static func pitchCorrection() {
        let b = FacialMetrics.defaultNeutral

        // A face whose brow READS strongly lowered + knit (a V-brow) — as a
        // head-down foreshortening inflates it. The underlying muscle action is
        // neutral, so this is the false-anger case we must not classify as anger.
        var vals = b.values
        vals[.browInnerLeft] = b[.browInnerLeft] - 0.12   // brow appears lowered
        vals[.browInnerRight] = b[.browInnerRight] - 0.12
        vals[.browGapX] = b[.browGapX] - 0.12             // and pulled together
        let foreshortened = FacialMetrics(values: vals)

        // Explicit config so the thresholds below are independent of any future
        // default retune. downSign = -1 ⇒ head-down is a NEGATIVE pitch.
        let cfg = PitchCorrection(slope: 1.0, deadband: 0.15, clampMaxFraction: 0.6, downSign: -1.0)
        let downStrong = -1.0   // rad (~57° down) — well past the deadband, hits the clamp
        let up = 0.6            // rad — head tilted UP

        // (a) nil pitch ⇒ AU vector identical to the pre-change behavior: the
        //     no-arg call, an explicit nil, and a zero-slope correction all agree.
        let auNoArg = AUComputer.compute(metrics: foreshortened, baseline: b)
        let auNil = AUComputer.compute(metrics: foreshortened, baseline: b,
                                       pitch: nil, pitchCorrection: cfg)
        for u in ActionUnit.allCases {
            assert(auNoArg[u] == auNil[u],
                   "EmotionSelfTests: default arg not nil-equivalent for \(u)")
        }
        let au4Raw = auNil[.au4] ?? 0
        assert(au4Raw > 0.6, "EmotionSelfTests: pitch test setup should give a high raw AU4, got \(au4Raw)")

        // (b) synthetic downward pitch ⇒ AU4 drops and the false anger dies —
        //     while the uncorrected vector reproduces the anger misclassification.
        let auDown = AUComputer.compute(metrics: foreshortened, baseline: b,
                                        pitch: downStrong, pitchCorrection: cfg)
        let au4Down = auDown[.au4] ?? 0
        assert(au4Down < au4Raw, "EmotionSelfTests: down-pitch must lower AU4 (\(au4Down) !< \(au4Raw))")
        assert(EmotionClassifier.classify(auNil).dominant.emotion == .anger,
               "EmotionSelfTests: uncorrected foreshortened brow should read anger (bug repro)")
        assert(EmotionClassifier.classify(auDown).dominant.emotion != .anger,
               "EmotionSelfTests: corrected down-pitch must NOT read anger (bug fixed)")

        // The SHIPPED defaults must also kill the false anger. Derive "down" from
        // defaultDownSign so this survives a K3 sign flip.
        let downByDefault = PitchCorrection.defaultDownSign * 1.0
        let auDefault = AUComputer.compute(metrics: foreshortened, baseline: b,
                                           pitch: downByDefault, pitchCorrection: .default)
        assert(EmotionClassifier.classify(auDefault).dominant.emotion != .anger,
               "EmotionSelfTests: shipped defaults must not read anger under head-down")

        // (c) monotonic: more down-pitch ⇒ more subtraction, respecting the clamp.
        func au4(atPitch p: Double) -> Double {
            AUComputer.compute(metrics: foreshortened, baseline: b, pitch: p, pitchCorrection: cfg)[.au4] ?? 0
        }
        let mild = au4(atPitch: -0.4), mid = au4(atPitch: -0.7), deep = au4(atPitch: -1.5)
        assert(mild >= mid && mid >= deep, "EmotionSelfTests: pitch correction not monotone (\(mild),\(mid),\(deep))")
        let clampFloor = (1 - cfg.clampMaxFraction) * au4Raw
        assert(deep >= clampFloor - 1e-12, "EmotionSelfTests: clamp violated (\(deep) < \(clampFloor))")
        assert(au4Down > 0, "EmotionSelfTests: clamp should keep AU4 positive under strong down-pitch")

        // (d) upward pitch ⇒ zero correction.
        let auUp = au4(atPitch: up)
        assert(auUp == au4Raw, "EmotionSelfTests: upward pitch must not correct (\(auUp) != \(au4Raw))")

        // (e) slope 0 ⇒ zero correction, even at a strong down-pitch.
        let auSlope0 = AUComputer.compute(
            metrics: foreshortened, baseline: b, pitch: downStrong,
            pitchCorrection: PitchCorrection(slope: 0, deadband: cfg.deadband,
                                             clampMaxFraction: cfg.clampMaxFraction, downSign: cfg.downSign)
        )[.au4] ?? 0
        assert(auSlope0 == au4Raw, "EmotionSelfTests: slope 0 must yield zero correction (\(auSlope0) != \(au4Raw))")
    }

    private static func distributionMath() {
        let d = EmotionDistribution(normalizing: [.happiness: 2, .neutral: 2])
        assert(abs(d[.happiness] - 0.5) < 1e-9, "EmotionSelfTests: normalization broken")

        let fused = d.fused(with: EmotionDistribution(normalizing: [.happiness: 1]), weight: 0.5)
        assert(fused.dominant.emotion == .happiness, "EmotionSelfTests: fusion broken")

        let va = EmotionDistribution(normalizing: [.happiness: 1]).valenceArousal
        assert(va.valence > 0.5, "EmotionSelfTests: valence anchor broken")
    }

    /// US-A1 — the channel-generic reading types: Codable round-trips (the
    /// golden-trace prerequisite, PRD §5.7), the face→`ChannelReading` projection,
    /// and the non-face "no discrete posterior" rule.
    private static func channelReadingTests() {
        let enc = JSONEncoder()
        let dec = JSONDecoder()

        // Tolerant scalar/meter/distribution comparisons: JSON round-trips Double
        // losslessly, but an over-strict assert here would trap at every launch.
        func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-6 }
        func metersEqual(_ a: Meter?, _ b: Meter?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (x?, y?): return approx(x.value, y.value) && approx(x.confidence, y.confidence)
            default: return false
            }
        }
        func distsEqual(_ a: EmotionDistribution?, _ b: EmotionDistribution?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (x?, y?): return Emotion.allCases.allSatisfy { approx(x[$0], y[$0]) }
            default: return false
            }
        }

        // (a) ChannelReading Codable round-trip — every field, incl. the features
        //     dict (enum-keyed) and the face-only posterior.
        let posterior = EmotionDistribution(normalizing: [.happiness: 0.6, .surprise: 0.25, .neutral: 0.15])
        let cr = ChannelReading(
            channel: .face,
            date: Date(timeIntervalSinceReferenceDate: 4321),
            availability: .degraded,
            quality: 0.83,
            valence: Meter(value: 0.42, confidence: 0.7),
            arousal: Meter(value: -0.17, confidence: 0.55),
            intensity: 0.61,
            features: [.au4: 0.3, .blinkRate: 12.5, .headPitch: -0.2],
            posterior: posterior
        )
        do {
            let r = try dec.decode(ChannelReading.self, from: enc.encode(cr))
            assert(r.channel == cr.channel, "EmotionSelfTests: ChannelReading channel lost in round-trip")
            assert(approx(r.date.timeIntervalSinceReferenceDate, cr.date.timeIntervalSinceReferenceDate),
                   "EmotionSelfTests: ChannelReading date lost in round-trip")
            assert(r.availability == cr.availability, "EmotionSelfTests: ChannelReading availability lost")
            assert(approx(r.quality, cr.quality), "EmotionSelfTests: ChannelReading quality lost")
            assert(metersEqual(r.valence, cr.valence), "EmotionSelfTests: ChannelReading valence lost")
            assert(metersEqual(r.arousal, cr.arousal), "EmotionSelfTests: ChannelReading arousal lost")
            assert(approx(r.intensity, cr.intensity), "EmotionSelfTests: ChannelReading intensity lost")
            assert(Set(r.features.keys) == Set(cr.features.keys), "EmotionSelfTests: ChannelReading feature keys lost")
            assert(cr.features.allSatisfy { approx(r.features[$0.key] ?? .nan, $0.value) },
                   "EmotionSelfTests: ChannelReading feature values lost")
            assert(distsEqual(r.posterior, cr.posterior), "EmotionSelfTests: ChannelReading posterior lost")
        } catch {
            assertionFailure("EmotionSelfTests: ChannelReading Codable threw \(error)")
        }

        // (b) A real synthetic EmotionReading round-trips through Codable.
        let dist = EmotionDistribution(normalizing: [.happiness: 0.7, .neutral: 0.3])
        let reading = EmotionReading(
            date: Date(timeIntervalSinceReferenceDate: 1000),
            distribution: dist,
            dominant: .happiness,
            confidence: 0.66,
            intensity: 0.42,
            intensities: [.happiness: 1.2, .neutral: 0.1],
            valence: 0.5,
            arousal: 0.3,
            faceDetected: true,
            quality: 0.9
        )
        do {
            let r = try dec.decode(EmotionReading.self, from: enc.encode(reading))
            assert(approx(r.date.timeIntervalSinceReferenceDate, reading.date.timeIntervalSinceReferenceDate),
                   "EmotionSelfTests: EmotionReading date lost")
            assert(r.dominant == reading.dominant, "EmotionSelfTests: EmotionReading dominant lost")
            assert(approx(r.confidence, reading.confidence), "EmotionSelfTests: EmotionReading confidence lost")
            assert(approx(r.intensity, reading.intensity), "EmotionSelfTests: EmotionReading intensity lost")
            assert(approx(r.valence, reading.valence), "EmotionSelfTests: EmotionReading valence lost")
            assert(approx(r.arousal, reading.arousal), "EmotionSelfTests: EmotionReading arousal lost")
            assert(r.faceDetected == reading.faceDetected, "EmotionSelfTests: EmotionReading faceDetected lost")
            assert(approx(r.quality, reading.quality), "EmotionSelfTests: EmotionReading quality lost")
            assert(distsEqual(r.distribution, reading.distribution), "EmotionSelfTests: EmotionReading distribution lost")
            assert(reading.intensities.allSatisfy { approx(r.intensities[$0.key] ?? .nan, $0.value) },
                   "EmotionSelfTests: EmotionReading intensities lost")
        } catch {
            assertionFailure("EmotionSelfTests: EmotionReading Codable threw \(error)")
        }

        // (c) Projection preserves V/A, intensity, confidence, and posterior identity.
        let proj = reading.asChannelReading()
        assert(proj.channel == .face, "EmotionSelfTests: projection channel must be .face")
        assert(proj.availability == .live, "EmotionSelfTests: a detected face must project .live")
        assert(metersEqual(proj.valence, Meter(value: reading.valence, confidence: reading.confidence)),
               "EmotionSelfTests: projection valence meter mismatch")
        assert(metersEqual(proj.arousal, Meter(value: reading.arousal, confidence: reading.confidence)),
               "EmotionSelfTests: projection arousal meter mismatch")
        assert(approx(proj.intensity, reading.intensity), "EmotionSelfTests: projection intensity mismatch")
        if let p = proj.posterior {
            assert(p == reading.distribution, "EmotionSelfTests: projection must carry the face distribution")
        } else {
            assertionFailure("EmotionSelfTests: a face projection must have a posterior")
        }
        // A no-face reading honestly projects to `.unavailable`.
        assert(EmotionReading.empty.asChannelReading().availability == .unavailable,
               "EmotionSelfTests: a no-face reading must project .unavailable")

        // (d) Non-face rule: a non-face channel carries NO discrete posterior.
        let eyes = ChannelReading(
            channel: .eyes,
            date: Date(timeIntervalSinceReferenceDate: 0),
            availability: .live,
            quality: 1.0,
            valence: nil,
            arousal: Meter(value: 0.2, confidence: 0.5),
            intensity: 0.2,
            features: [.blinkRate: 18],
            posterior: nil
        )
        assert(eyes.posterior == nil, "EmotionSelfTests: non-face channels must not carry a posterior")
    }

    /// US-A2/A3 — the `AffectHub` composition spine: the `.face` alias identity,
    /// the `AffectChannel` conformance shape on `EmotionEngine`, and that the
    /// face channel's `latest` is exactly the engine reading's own projection.
    /// Structural (not math): a throwaway `AppModel` is built so the REAL alias
    /// (`AppModel.emotionEngine → affectHub.face`) is what gets checked.
    private static func affectHubSpine() {
        let appModel = AppModel()

        // (a) The `emotionEngine` alias returns the very instance the hub owns.
        assert(appModel.emotionEngine === appModel.affectHub.face,
               "EmotionSelfTests: emotionEngine must alias affectHub.face (same instance)")

        // (b) `EmotionEngine` viewed as `any AffectChannel` reports the face
        //     identity and produces a `.face` reading.
        let channel: any AffectChannel = appModel.affectHub.face
        assert(channel.id == .face, "EmotionSelfTests: face channel id must be .face")
        assert(channel.isEnabled, "EmotionSelfTests: the face lens is the always-on default")
        assert(channel.latest.channel == .face,
               "EmotionSelfTests: face channel latest must be a .face reading")

        // (c) `latest` equals the engine reading's own projection, field for field.
        let viaChannel = channel.latest
        let viaReading = appModel.affectHub.face.reading.asChannelReading()
        assert(viaChannel.channel == viaReading.channel,
               "EmotionSelfTests: channel projection channel mismatch")
        assert(viaChannel.availability == viaReading.availability,
               "EmotionSelfTests: channel projection availability mismatch")
        assert(viaChannel.intensity == viaReading.intensity,
               "EmotionSelfTests: channel projection intensity mismatch")

        // reset() is a documented no-op — it must not perturb the reading.
        let before = channel.latest.channel
        channel.reset()
        assert(channel.latest.channel == before,
               "EmotionSelfTests: face reset() must be a no-op")
    }

    /// US-B5a — the `FrameAnalysis` fan-out seam: the hub multiplexes the engine's
    /// single `onAnalysis` tap out to registered consumers, in registration order,
    /// with working removal and no crash when empty. Pure & synchronous — a
    /// `FrameAnalysis` is synthesized directly (no camera / no Vision) and pushed
    /// through the SAME hook the engine fires (`hub.face.onAnalysis`), exercising
    /// the real init-time wiring.
    private static func analysisFanOut() {
        let hub = AffectHub()

        // A directly-synthesized analysis, identified by its timestamp so a
        // consumer can prove it received THIS value.
        let stamp = Date(timeIntervalSinceReferenceDate: 987_654)
        let analysis = FrameAnalysis.absent(at: stamp,
                                            imageSize: CGSize(width: 640, height: 480))

        // (d) No consumers registered ⇒ firing the tap must not crash.
        hub.face.onAnalysis?(analysis)

        // (a) A single registered consumer receives exactly the pushed value.
        var received: [Date] = []
        hub.addAnalysisConsumer("a") { received.append($0.date) }
        hub.face.onAnalysis?(analysis)
        assert(received == [stamp],
               "EmotionSelfTests: consumer must receive the pushed analysis")

        // (b) Two consumers both fire, in REGISTRATION order.
        var order: [String] = []
        hub.removeAnalysisConsumer("a")
        hub.addAnalysisConsumer("first") { _ in order.append("first") }
        hub.addAnalysisConsumer("second") { _ in order.append("second") }
        hub.face.onAnalysis?(analysis)
        assert(order == ["first", "second"],
               "EmotionSelfTests: consumers must fire in registration order, got \(order)")

        // (c) Removal stops delivery to that consumer only.
        order.removeAll()
        hub.removeAnalysisConsumer("first")
        hub.face.onAnalysis?(analysis)
        assert(order == ["second"],
               "EmotionSelfTests: a removed consumer must stop receiving, got \(order)")
    }

    /// US-A4 — the `BaselineStore` per-channel robust-baseline layer: robust-z
    /// math + epsilon guard, MAD-spread ⇒ separability monotonicity, Codable
    /// round-trip, per-channel retrack convergence, and the v1→v2 MIGRATION
    /// (the acceptance criterion). The migration case uses a THROWAWAY
    /// `UserDefaults` suite so it never touches the app's real persisted baseline.
    private static func baselineStore() {
        // (a) robust-z: (x − median) / (1.4826·mad), with the mad=0 epsilon guard.
        let stat = RobustStat(median: 10, mad: 2)
        let sigma = RobustStat.madToSigma * 2
        assert(stat.robustZ(10) == 0, "EmotionSelfTests: robustZ at the median must be 0")
        assert(abs(stat.robustZ(10 + sigma) - 1) < 1e-9, "EmotionSelfTests: robustZ scale wrong")
        assert(abs(stat.robustZ(10 - 3 * sigma) + 3) < 1e-9, "EmotionSelfTests: robustZ sign/scale wrong")
        let flat = RobustStat(median: 5, mad: RobustStat.unknownMAD)   // mad == 0
        assert(flat.robustZ(5) == 0, "EmotionSelfTests: robustZ(median) must be 0 even at mad=0")
        let guarded = flat.robustZ(6)
        assert(guarded.isFinite && guarded > 1e6,
               "EmotionSelfTests: mad=0 must be epsilon-guarded (finite, large), got \(guarded)")

        // (b) separability is monotone in the calibration MAD spread, in [0,1].
        let narrow = ChannelBaseline(stats: ["a": RobustStat(median: 0, mad: 0.004),
                                             "b": RobustStat(median: 0, mad: 0.005)])
        let wide = ChannelBaseline(stats: ["a": RobustStat(median: 0, mad: 0.04),
                                           "b": RobustStat(median: 0, mad: 0.05)])
        assert(wide.expressiveSeparability > narrow.expressiveSeparability,
               "EmotionSelfTests: wider MAD spread must raise separability")
        assert((0...1).contains(narrow.expressiveSeparability) && (0...1).contains(wide.expressiveSeparability),
               "EmotionSelfTests: separability must stay in [0,1]")
        assert(ChannelBaseline.empty.expressiveSeparability == 0,
               "EmotionSelfTests: an empty entry has 0 separability")

        // (c) Codable round-trip of a populated store (Equatable identity).
        var store = BaselineStore.empty
        var face = ChannelBaseline.empty
        face[FacialMetric.eyeOpenLeft] = RobustStat(median: 0.17, mad: 0.01)
        face[FacialMetric.browInnerLeft] = RobustStat(median: 0.35, mad: 0.02)
        store.channels[.face] = face
        store.channels[.eyes] = ChannelBaseline(stats: [FeatureKey.blinkRate.rawValue: RobustStat(median: 16, mad: 3)])
        store.refreshFingerprint()
        do {
            let back = try JSONDecoder().decode(BaselineStore.self, from: JSONEncoder().encode(store))
            assert(back == store, "EmotionSelfTests: BaselineStore Codable round-trip mismatch")
        } catch {
            assertionFailure("EmotionSelfTests: BaselineStore Codable threw \(error)")
        }

        // (d) retrack: one step moves the median by exactly alpha; it converges.
        let key = FacialMetric.eyeOpenLeft.rawValue
        let median0 = 0.0, target = 1.0, alpha = 0.02
        var rt = BaselineStore.empty
        rt.channels[.face] = ChannelBaseline(stats: [key: RobustStat(median: median0, mad: 0.1)])
        rt.retrack(channel: .face, feature: key, observed: target, alpha: alpha)
        let m1 = rt.stat(.face, key)?.median ?? .nan
        assert(abs(m1 - (median0 + alpha * (target - median0))) < 1e-12,
               "EmotionSelfTests: one retrack must move the median by exactly alpha")
        for _ in 0..<500 { rt.retrack(channel: .face, feature: key, observed: target, alpha: alpha) }
        let mN = rt.stat(.face, key)?.median ?? .nan
        assert(abs(mN - target) < 1e-3, "EmotionSelfTests: retrack must converge toward the observation")

        // (e) MIGRATION (acceptance criterion): a v1 `NeutralBaseline` blob written
        //     to a throwaway suite in EXACTLY `NeutralBaseline.save()`'s format
        //     (JSONEncoder over `metrics.values`) migrates into the `.face` entry,
        //     and the v1 key SURVIVES (the engine still reads it).
        let suiteName = "BaselineStoreTests." + UUID().uuidString
        guard let suite = UserDefaults(suiteName: suiteName) else {
            assertionFailure("EmotionSelfTests: could not create throwaway UserDefaults suite")
            return
        }
        var vals = FacialMetrics.defaultNeutral.values
        vals[.browInnerLeft] = 0.31   // a distinctive value to detect post-migration
        guard let v1data = try? JSONEncoder().encode(vals) else {
            assertionFailure("EmotionSelfTests: could not encode the synthetic v1 blob")
            suite.removePersistentDomain(forName: suiteName)
            return
        }
        suite.set(v1data, forKey: BaselineStore.v1FaceKey)

        let migrated = BaselineStore.loaded(from: suite)   // no v2 present → migration path
        let migratedBrow = migrated.channels[.face]?[FacialMetric.browInnerLeft]
        assert(migrated.channels[.face] != nil, "EmotionSelfTests: migration must create a .face entry")
        assert(migratedBrow != nil && abs(migratedBrow!.median - 0.31) < 1e-9,
               "EmotionSelfTests: migrated face median must equal the v1 value")
        assert(migratedBrow?.mad == RobustStat.unknownMAD,
               "EmotionSelfTests: migrated MAD must be the unknown marker")
        assert(migrated.personaFingerprint != nil,
               "EmotionSelfTests: migration must seed the persona fingerprint")
        assert(suite.data(forKey: BaselineStore.v1FaceKey) != nil,
               "EmotionSelfTests: migration must NOT delete the v1 key")

        suite.removePersistentDomain(forName: suiteName)   // throwaway cleanup
    }

    /// US-B5 — the `BlinkDetector` pure math: adaptive-EAR blink counting at the
    /// ~15 Hz throttle, N-frame confirmation, refractory de-bounce, the
    /// prolonged-closure (AU43/PERCLOS) branch that is NOT a blink, honest
    /// face-absence handling, and rolling-window pruning. Synthetic openness +
    /// timestamps only — no camera, no Vision.
    ///
    /// Openness convention (matches the app's IOD-normalized palpebral-fissure
    /// metric): open ≈ 0.20, closed ≈ 0.02; the first sample seeds the baseline to
    /// 0.20 so the closed threshold is 0.5 × 0.20 = 0.10.
    private static func blinkDetection() {
        let t0 = Date(timeIntervalSinceReferenceDate: 100_000)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        let open = 0.20, shut = 0.02

        // (a) A synthetic 3-blink minute yields blinksPerMinute == 3 (±0).
        do {
            var d = BlinkDetector()
            _ = d.ingest(openness: open, date: at(0.0))     // seeds the baseline
            _ = d.ingest(openness: open, date: at(0.066))
            func blink(atSecond s: Double) -> BlinkDetector.Event? {
                _ = d.ingest(openness: shut, date: at(s))
                _ = d.ingest(openness: shut, date: at(s + 0.066))
                return d.ingest(openness: open, date: at(s + 0.132))   // reopen counts
            }
            assert(blink(atSecond: 1.0) == .blink, "EmotionSelfTests: first blink not counted")
            _ = blink(atSecond: 10.0)
            _ = blink(atSecond: 20.0)
            assert(d.blinksPerMinute == 3, "EmotionSelfTests: 3 blinks must read 3/min, got \(d.blinksPerMinute)")
        }

        // (b) Sub-threshold dips shorter than N (=2) frames don't count.
        do {
            var d = BlinkDetector()
            _ = d.ingest(openness: open, date: at(0.0))
            _ = d.ingest(openness: open, date: at(0.066))
            _ = d.ingest(openness: shut, date: at(0.2))                // one closed frame only
            let e = d.ingest(openness: open, date: at(0.266))          // reopen: run length 1 < 2
            assert(e == nil && d.blinksPerMinute == 0,
                   "EmotionSelfTests: a 1-frame dip must not count as a blink")
            // A shallow dip that never crosses the closed threshold also can't count.
            _ = d.ingest(openness: 0.15, date: at(0.4))                // 0.15 > 0.10 threshold
            _ = d.ingest(openness: 0.15, date: at(0.466))
            assert(d.blinksPerMinute == 0,
                   "EmotionSelfTests: a shallow (never-closed) dip must not count")
        }

        // (c) Refractory: an immediate re-dip right after a blink doesn't double-count.
        do {
            var d = BlinkDetector()
            _ = d.ingest(openness: open, date: at(0.0))
            _ = d.ingest(openness: open, date: at(0.05))
            _ = d.ingest(openness: shut, date: at(0.10))
            _ = d.ingest(openness: shut, date: at(0.15))
            let e1 = d.ingest(openness: open, date: at(0.20))          // blink #1, refractory→0.40
            assert(e1 == .blink, "EmotionSelfTests: expected a blink at reopen")
            _ = d.ingest(openness: shut, date: at(0.25))
            _ = d.ingest(openness: shut, date: at(0.30))
            let e2 = d.ingest(openness: open, date: at(0.35))          // reopen 0.35 < 0.40 → blocked
            assert(e2 == nil && d.blinksPerMinute == 1,
                   "EmotionSelfTests: refractory must suppress the immediate re-dip, got \(d.blinksPerMinute)")
        }

        // (d) A prolonged closure sets the flag and is NOT also counted as a blink.
        do {
            var d = BlinkDetector()
            _ = d.ingest(openness: open, date: at(0.0))
            _ = d.ingest(openness: open, date: at(0.066))
            var sawProlongedBegan = false
            var tt = 1.0
            while tt <= 2.2 {                                          // ~1.2 s of continuous closure
                if d.ingest(openness: shut, date: at(tt)) == .prolongedClosureBegan { sawProlongedBegan = true }
                tt += 0.066
            }
            assert(sawProlongedBegan, "EmotionSelfTests: a >1 s closure must fire prolongedClosureBegan")
            assert(d.prolongedClosure, "EmotionSelfTests: prolonged-closure flag must be set")
            assert(d.blinksPerMinute == 0, "EmotionSelfTests: a prolonged closure must not count as a blink")
            let er = d.ingest(openness: open, date: at(2.3))           // reopen
            assert(er == .prolongedClosureEnded, "EmotionSelfTests: reopen must end the prolonged closure")
            assert(d.blinksPerMinute == 0 && !d.prolongedClosure,
                   "EmotionSelfTests: ending a prolonged closure still counts no blink")
        }

        // (e) A face-absent gap produces zero blinks and no closure flag — even mid-closure.
        do {
            var d = BlinkDetector()
            _ = d.ingest(openness: open, date: at(0.0))
            _ = d.ingest(openness: open, date: at(0.066))
            _ = d.ingest(openness: shut, date: at(0.2))                // closure starts…
            _ = d.ingest(openness: shut, date: at(0.266))              // …reaches N, but never reopens
            d.markAbsent(at: at(0.4))                                  // face gone
            d.markAbsent(at: at(1.5))
            d.markAbsent(at: at(3.0))
            assert(d.blinksPerMinute == 0, "EmotionSelfTests: a face gap must not fabricate a blink")
            assert(!d.prolongedClosure, "EmotionSelfTests: a face gap is not a closure")
            _ = d.ingest(openness: open, date: at(3.1))               // resume
            assert(d.blinksPerMinute == 0, "EmotionSelfTests: still no blink after a face gap")
        }

        // (f) Rolling window prunes: blink events older than 60 s drop off the rate.
        do {
            var d = BlinkDetector()
            _ = d.ingest(openness: open, date: at(0.0))
            func blink(atSecond s: Double) {
                _ = d.ingest(openness: shut, date: at(s))
                _ = d.ingest(openness: shut, date: at(s + 0.05))
                _ = d.ingest(openness: open, date: at(s + 0.10))
            }
            blink(atSecond: 0.1); blink(atSecond: 0.4); blink(atSecond: 0.7)
            assert(d.blinksPerMinute == 3, "EmotionSelfTests: expected 3 blinks in-window, got \(d.blinksPerMinute)")
            _ = d.ingest(openness: open, date: at(61.0))               // >60 s later → prune
            assert(d.blinksPerMinute == 0,
                   "EmotionSelfTests: blinks older than 60 s must prune off the rate, got \(d.blinksPerMinute)")
        }
    }

    /// US-B8 — the interaction-dynamics lens. Pure-core window math (tempo, cancel
    /// rate, toggle churn, pruning) on synthetic `InteractionEvent` streams, plus the
    /// channel's starvation→availability mapping and its delta-from-baseline contract.
    /// No `SpatialEventGesture` and no view — abstract events only.
    private static func interactionDynamics() {
        let t0 = Date(timeIntervalSinceReferenceDate: 500_000)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

        // (a) tempo: 30 initiations inside the trailing 60 s ⇒ 30/min (exact count,
        //     the EyeChannel per-minute convention).
        do {
            var core = InteractionDynamics()
            for i in 0..<30 { core.note(InteractionEvent(.began, at: at(Double(i) * 2))) }   // 0,2,…,58 s
            let now = at(58)
            assert(core.inputTempo(now: now) == 30,
                   "EmotionSelfTests: 30 initiations in trailing 60 s must read 30/min, got \(core.inputTempo(now: now))")
            assert(core.eventCount(now: now) == 30, "EmotionSelfTests: interaction eventCount wrong")
            assert(!core.isStarved(now: now), "EmotionSelfTests: 30 events must not be starved")
        }

        // (b) cancelRate: 2 cancelled of 10 resolved ⇒ 0.2; nil with nothing resolved.
        do {
            var core = InteractionDynamics()
            for i in 0..<8 { core.note(InteractionEvent(.ended, at: at(Double(i)), duration: 0.2)) }
            for i in 8..<10 { core.note(InteractionEvent(.cancelled, at: at(Double(i)), duration: 0.3)) }
            assert(core.cancelRate(now: at(9)) == 0.2,
                   "EmotionSelfTests: 2 cancelled of 10 must give cancelRate 0.2, got \(String(describing: core.cancelRate(now: at(9))))")
            var pending = InteractionDynamics()
            pending.note(InteractionEvent(.began, at: at(0)))
            assert(pending.cancelRate(now: at(0)) == nil,
                   "EmotionSelfTests: cancelRate must be nil with nothing resolved (never a fabricated 0)")
        }

        // (c) toggle churn: a same-control flip-back within 5 s counts once; a slow
        //     flip doesn't.
        do {
            var fast = InteractionDynamics()
            fast.note(InteractionEvent(.toggle(id: "x", isOn: true), at: at(0)))
            fast.note(InteractionEvent(.toggle(id: "x", isOn: false), at: at(3)))
            assert(fast.toggleCorrections(now: at(3)) == 1,
                   "EmotionSelfTests: on→off within 5 s must count one correction, got \(fast.toggleCorrections(now: at(3)))")

            var slow = InteractionDynamics()
            slow.note(InteractionEvent(.toggle(id: "y", isOn: true), at: at(0)))
            slow.note(InteractionEvent(.toggle(id: "y", isOn: false), at: at(10)))
            assert(slow.toggleCorrections(now: at(10)) == 0,
                   "EmotionSelfTests: on→off after >5 s must not count as a correction")
        }

        // (e) window pruning: events past the windows age off the reads.
        do {
            var core = InteractionDynamics()
            for i in 0..<10 { core.note(InteractionEvent(.began, at: at(Double(i)))) }
            let future = at(300)   // >120 s later
            assert(core.inputTempo(now: future) == 0,
                   "EmotionSelfTests: events past the 60 s tempo window must prune off the rate")
            assert(core.eventCount(now: future) == 0,
                   "EmotionSelfTests: events past the 120 s window must age out")
        }

        // (d) starvation: 3 events ⇒ insufficient (core) and, through the channel,
        //     .unavailable + low confidence (the DESIGNED passive-viewing state).
        do {
            var core = InteractionDynamics()
            for i in 0..<3 { core.note(InteractionEvent(.began, at: at(Double(i)))) }
            assert(core.isStarved(now: at(2)), "EmotionSelfTests: 3 events must be starved")
            assert(core.eventCount(now: at(2)) == 3, "EmotionSelfTests: starvation eventCount wrong")

            let key = InteractionChannel.enabledKey
            let saved = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            let hub = AffectHub()
            hub.interaction.prepareForActivation()
            for i in 0..<3 { hub.interaction.note(InteractionEvent(.began, at: at(Double(i)))) }
            let s = hub.interaction.snapshot(at: at(2))
            assert(s.isStarved, "EmotionSelfTests: channel snapshot must report starved at 3 events")
            assert(s.availability == .unavailable,
                   "EmotionSelfTests: a starved interaction lens must read .unavailable (designed state)")
            assert(s.quality < 0.3, "EmotionSelfTests: a starved lens must carry low confidence, got \(s.quality)")
            assert(s.effort == 0, "EmotionSelfTests: a starved lens must not fabricate effort")
            restore(key, saved)
        }

        // (f) baseline delta: the .inputTempo feature is (tempo − per-user baseline
        //     median). Seed a learned baseline, drive a known tempo, and assert the
        //     delta-from-baseline contract exactly (robust to the slow passive retrack),
        //     plus the master-law shape (no V/A, no posterior).
        do {
            let key = InteractionChannel.enabledKey
            let saved = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            let hub = AffectHub()
            var entry = ChannelBaseline.empty
            entry[FeatureKey.inputTempo] = RobustStat(median: 12, mad: 4)      // a learned baseline
            entry[FeatureKey.cancelRate] = RobustStat(median: 0.1, mad: 0.05)
            hub.baselines.channels[.interaction] = entry
            hub.interaction.prepareForActivation()
            for i in 0..<10 { hub.interaction.note(InteractionEvent(.began, at: at(Double(i)))) }
            let s = hub.interaction.snapshot(at: at(9))
            let median = hub.baselines.stat(.interaction, FeatureKey.inputTempo.rawValue)!.median
            let feature = s.reading.features[.inputTempo] ?? .nan
            assert(abs(feature - (s.inputTempo - median)) < 1e-9,
                   "EmotionSelfTests: .inputTempo feature must equal tempo − baseline median (\(feature) vs \(s.inputTempo - median))")
            assert(s.baselineLearned, "EmotionSelfTests: a seeded MAD>0 baseline must read learned")
            assert(s.reading.valence == nil && s.reading.arousal == nil,
                   "EmotionSelfTests: interaction owns effort/load — never circumplex V/A")
            assert(s.reading.posterior == nil, "EmotionSelfTests: non-face law — interaction carries no posterior")
            restore(key, saved)
        }
    }

    /// US-B6 / US-B8 — the `Lens` registry: six lenses with unique ids + unique
    /// defaults keys (eyes exactly `lens.eyes.enabled`, matching `EyeChannel.enabledKey`),
    /// and the three-state availability mapping (face always available; eyes AND
    /// interaction disabled ⇒ unavailableButEnableable, enabled ⇒ available; the
    /// remaining not-yet-wired channels ⇒ the honest `.unavailable` state).
    private static func lensRegistryTests() {
        // (a) six lenses, unique ids, unique defaults keys, eyes key exact.
        let lenses = Lens.allCases
        assert(lenses.count == 6, "EmotionSelfTests: expected 6 lenses, got \(lenses.count)")
        assert(Set(lenses.map(\.id)).count == 6, "EmotionSelfTests: lens ids must be unique")
        let keys = lenses.compactMap(\.enabledDefaultsKey)      // face has none (always-on)
        assert(Set(keys).count == keys.count, "EmotionSelfTests: lens defaults keys must be unique")
        assert(Lens.face.enabledDefaultsKey == nil, "EmotionSelfTests: the face lens is always-on (no key)")
        assert(Lens.eyes.enabledDefaultsKey == "lens.eyes.enabled",
               "EmotionSelfTests: eyes key must be exactly lens.eyes.enabled")
        assert(Lens.eyes.enabledDefaultsKey == EyeChannel.enabledKey,
               "EmotionSelfTests: eyes lens key must match EyeChannel.enabledKey")
        for l in lenses where l != .face {
            assert(l.enabledDefaultsKey == "lens.\(l.rawValue).enabled",
                   "EmotionSelfTests: \(l.rawValue) key must be lens.<raw>.enabled")
            assert(l.channel.rawValue == l.rawValue,
                   "EmotionSelfTests: lens \(l.rawValue) must map to its same-named channel")
        }

        // (b) availability mapping — deterministic via save/set/restore of the real
        //     flag. Safe at launch: no view observes it yet, and the app hub reads it
        //     live so restoring the value fully reverts the effect.
        let key = EyeChannel.enabledKey
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        let hub = AffectHub()
        guard case .unavailableButEnableable = Lens.eyes.availability(in: hub) else {
            assertionFailure("EmotionSelfTests: eyes disabled must be unavailableButEnableable")
            restore(key, saved); return
        }
        UserDefaults.standard.set(true, forKey: key)
        assert(Lens.eyes.availability(in: hub).isAvailable,
               "EmotionSelfTests: eyes enabled must be available")
        restore(key, saved)

        // interaction mirrors the eyes pattern (US-B8): disabled ⇒ enableable,
        // enabled ⇒ available (same save/set/restore of the real flag).
        let ikey = InteractionChannel.enabledKey
        let isaved = UserDefaults.standard.object(forKey: ikey)
        UserDefaults.standard.set(false, forKey: ikey)
        guard case .unavailableButEnableable = Lens.interaction.availability(in: hub) else {
            assertionFailure("EmotionSelfTests: interaction disabled must be unavailableButEnableable")
            restore(ikey, isaved); return
        }
        UserDefaults.standard.set(true, forKey: ikey)
        assert(Lens.interaction.availability(in: hub).isAvailable,
               "EmotionSelfTests: interaction enabled must be available")
        restore(ikey, isaved)

        // voice mirrors the eyes/interaction enableable pattern (US-D12), but is mic-aware:
        // disabled + mic-not-denied ⇒ enableable; enabled ⇒ available. `connect` disarms
        // the flag each launch (privacy-first), so the hub's `voice.micDenied` is false here
        // and reading the flag drives availability without any mic side effect.
        let vkey = VoiceChannel.enabledKey
        let vsaved = UserDefaults.standard.object(forKey: vkey)
        UserDefaults.standard.set(false, forKey: vkey)
        guard case .unavailableButEnableable = Lens.voice.availability(in: hub) else {
            assertionFailure("EmotionSelfTests: voice disabled must be unavailableButEnableable")
            restore(vkey, vsaved); return
        }
        UserDefaults.standard.set(true, forKey: vkey)
        assert(Lens.voice.availability(in: hub).isAvailable,
               "EmotionSelfTests: voice enabled (mic not denied) must be available")
        restore(vkey, vsaved)

        // face is always available.
        assert(Lens.face.availability(in: hub) == .available,
               "EmotionSelfTests: the face lens is always available")

        // hands is now a REAL immersive channel (US-D13a): disabled ⇒ enableable (the enable
        // CTA); enabled-but-space-closed ⇒ enableable (the "open the aura" CTA). It is never
        // `.available` without live hand data (no provider in the sim / tests), and only truly
        // `.unavailable` on auth-deny / unsupported / session error. `AffectHub.init` wires the
        // hands state from the flag at construction, so control the flag with dedicated hubs.
        let hkey = HandsChannel.enabledKey
        let hsaved = UserDefaults.standard.object(forKey: hkey)
        UserDefaults.standard.set(false, forKey: hkey)
        let handsOff = AffectHub()
        guard case .unavailableButEnableable = Lens.hands.availability(in: handsOff) else {
            assertionFailure("EmotionSelfTests: hands disabled must be unavailableButEnableable (enable CTA)")
            restore(hkey, hsaved); return
        }
        UserDefaults.standard.set(true, forKey: hkey)
        let handsOn = AffectHub()   // connect() sees enabled ⇒ the immersive-closed state
        guard case .unavailableButEnableable = Lens.hands.availability(in: handsOn) else {
            assertionFailure("EmotionSelfTests: hands enabled but space-closed must be unavailableButEnableable (open-the-aura CTA)")
            restore(hkey, hsaved); return
        }
        restore(hkey, hsaved)

        // head is now a DUAL-SOURCE lens (US-D13b): the windowed pose works in the plain
        // window, so disabled ⇒ enableable and enabled ⇒ available (mirrors eyes/voice).
        // Its key must equal `HeadChannel.enabledKey`. Save/set/restore the real flag.
        assert(Lens.head.enabledDefaultsKey == HeadChannel.enabledKey,
               "EmotionSelfTests: head lens key must match HeadChannel.enabledKey")
        let hdkey = HeadChannel.enabledKey
        let hdsaved = UserDefaults.standard.object(forKey: hdkey)
        UserDefaults.standard.set(false, forKey: hdkey)
        guard case .unavailableButEnableable = Lens.head.availability(in: hub) else {
            assertionFailure("EmotionSelfTests: head disabled must be unavailableButEnableable")
            restore(hdkey, hdsaved); return
        }
        UserDefaults.standard.set(true, forKey: hdkey)
        assert(Lens.head.availability(in: hub).isAvailable,
               "EmotionSelfTests: head enabled must be available (windowed source works in the plain window)")
        restore(hdkey, hdsaved)
    }

    /// US-B6 — the `FusionRegistry` scaffold: the RationalePanel honesty invariant
    /// (every mode has non-empty `requires` + `rationale`), the toggle round-trip in
    /// a throwaway suite (default false), and `requires`-unsatisfied ⇒ unavailable.
    /// Exercised by a DEBUG-only placeholder mode that the app never registers.
    private static func fusionRegistryScaffold() {
        let mode = PlaceholderFusionMode()

        // (d) the honesty invariant every fusion mode (and its RationalePanel) demands.
        assert(!mode.requires.isEmpty, "EmotionSelfTests: a fusion mode must declare required channels")
        assert(!mode.rationale.isEmpty, "EmotionSelfTests: a fusion mode must carry a non-empty rationale")
        assert((0...1).contains(mode.confidenceCeiling),
               "EmotionSelfTests: a fusion mode's confidence ceiling must be within 0…1")

        // (c) registry round-trip in a THROWAWAY suite (never touches app defaults).
        let suiteName = "FusionRegistryTests." + UUID().uuidString
        guard let suite = UserDefaults(suiteName: suiteName) else {
            assertionFailure("EmotionSelfTests: could not create throwaway UserDefaults suite")
            return
        }
        let reg = FusionRegistry(defaults: suite)
        assert(reg.modes.isEmpty, "EmotionSelfTests: a fresh registry registers no modes (constructs arrive later)")
        reg.register(mode)
        assert(reg.modes.contains { $0.id == mode.id }, "EmotionSelfTests: register must add the mode")

        // Toggle: default false → true → false, persisted under fusion.<id>.enabled.
        assert(reg.isEnabled(mode.id) == false, "EmotionSelfTests: fusion modes are off by default")
        reg.setEnabled(mode.id, true)
        assert(reg.isEnabled(mode.id) == true, "EmotionSelfTests: setEnabled(true) must stick")
        assert(suite.bool(forKey: FusionRegistry.enabledKey(mode.id)) == true,
               "EmotionSelfTests: the toggle must persist under fusion.<id>.enabled")
        reg.setEnabled(mode.id, false)
        assert(reg.isEnabled(mode.id) == false, "EmotionSelfTests: setEnabled(false) must stick")

        // requires-unsatisfied ⇒ unavailable (the placeholder needs .hands, never live today).
        let hub = AffectHub()
        assert(reg.isAvailable(mode, hub: hub) == false,
               "EmotionSelfTests: a mode requiring a dark channel must be unavailable")

        // fuse gates on presence of its required readings.
        assert(mode.fuse([:]) == nil, "EmotionSelfTests: fuse must return nil without its required readings")
        let faceR = EmotionReading.empty.asChannelReading()
        let handR = ChannelReading(channel: .hands, date: Date(), availability: .live, quality: 1,
                                   valence: nil, arousal: Meter(value: 0.5, confidence: 0.4),
                                   intensity: 0.5, features: [:], posterior: nil)
        let out = mode.fuse([.face: faceR, .hands: handR])
        assert(out != nil, "EmotionSelfTests: fuse must produce output when required channels are present")
        assert(out?.contributions.isEmpty == false, "EmotionSelfTests: a fused output must name its contributors")

        suite.removePersistentDomain(forName: suiteName)
    }

    /// Restore a `UserDefaults.standard` key to a saved value (or remove it if it had
    /// none), so `lensRegistryTests` leaves the eyes flag exactly as it found it.
    private static func restore(_ key: String, _ value: Any?) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// A DEBUG-only placeholder fusion mode — NEVER registered in the running app.
    /// Concrete enough to exercise the registry round-trip, the availability gate,
    /// and the RationalePanel honesty fields. `nonisolated` value type (its pure
    /// members satisfy the nonisolated protocol requirements).
    private nonisolated struct PlaceholderFusionMode: FusionMode {
        var id: String { "placeholder.debug" }
        var title: String { "Placeholder (debug only)" }
        var requires: Set<Channel> { [.face, .hands] }   // .hands is never live today
        var rationale: String {
            "Debug-only stand-in: proves a mode declares its contributing channels and explains itself before any real construct ships."
        }
        var confound: String { "everything — this is not a real construct" }
        var citation: String? { "US-B6 self-test" }
        var confidenceCeiling: Double { 0.5 }

        func fuse(_ readings: [Channel: ChannelReading]) -> FusionOutput? {
            guard requires.allSatisfy({ readings[$0] != nil }) else { return nil }
            return FusionOutput(namedState: "placeholder",
                                contributions: [.face: 0.6, .hands: 0.4],
                                confidence: 0.3)
        }
    }

    // MARK: - US-C9 — ConstructHysteresis (the reusable named-state latch)

    /// US-C9 — the `ConstructHysteresis` latch: it activates only after a DWELL of
    /// consecutive `≥ enter` ticks, holds through the hysteresis band `(exit, enter)`,
    /// deactivates only after a dwell of consecutive `≤ exit` ticks, resets a broken
    /// streak, and RE-FIRES after a full re-arm. Pure — synthetic scores only.
    private static func constructHysteresis() {
        // Enter only after the dwell; hold in the band; exit only after the exit dwell.
        var h = ConstructHysteresis(enter: 0.6, exit: 0.3, enterDwellTicks: 3, exitDwellTicks: 2)
        assert(h.update(score: 0.9) == false, "EmotionSelfTests: 1 high tick must not activate (dwell 3)")
        assert(h.update(score: 0.9) == false, "EmotionSelfTests: 2 high ticks must not activate (dwell 3)")
        assert(h.update(score: 0.9) == true, "EmotionSelfTests: 3 consecutive high ticks must activate")
        assert(h.isActive, "EmotionSelfTests: latch must report active")
        assert(h.update(score: 0.45) == true, "EmotionSelfTests: a score inside (exit,enter) must NOT deactivate")
        assert(h.update(score: 0.2) == true, "EmotionSelfTests: 1 low tick must not deactivate (exit dwell 2)")
        assert(h.update(score: 0.2) == false, "EmotionSelfTests: 2 consecutive low ticks must deactivate")
        assert(!h.isActive, "EmotionSelfTests: latch must report inactive after exit dwell")

        // A broken enter-streak resets (the dwell requires an UNBROKEN run).
        var h2 = ConstructHysteresis(enter: 0.6, exit: 0.3, enterDwellTicks: 3, exitDwellTicks: 1)
        _ = h2.update(score: 0.9); _ = h2.update(score: 0.9)   // 2 in a row…
        assert(h2.update(score: 0.1) == false, "EmotionSelfTests: a sub-enter tick breaks the streak")
        assert(h2.update(score: 0.9) == false, "EmotionSelfTests: streak must restart (only 1 consecutive now)")
        _ = h2.update(score: 0.9)
        assert(h2.update(score: 0.9) == true, "EmotionSelfTests: a re-accumulated 3-in-a-row must activate")

        // Re-fire after a full re-arm: deactivate, then a fresh dwell re-activates.
        assert(h2.update(score: 0.1) == false, "EmotionSelfTests: exit dwell 1 must deactivate on one low tick")
        assert(!h2.isActive, "EmotionSelfTests: must be inactive before re-arm")
        _ = h2.update(score: 0.9); _ = h2.update(score: 0.9)
        assert(h2.update(score: 0.9) == true, "EmotionSelfTests: latch must re-fire after a full re-arm")

        // A mis-set (0/negative) dwell still needs one qualifying tick, never fires on nothing.
        var h3 = ConstructHysteresis(enter: 0.5, exit: 0.2, enterDwellTicks: 0, exitDwellTicks: 0)
        assert(h3.update(score: 0.1) == false, "EmotionSelfTests: a sub-enter tick must not activate a 0-dwell latch")
        assert(h3.update(score: 0.9) == true, "EmotionSelfTests: one qualifying tick activates a 0-dwell latch")
    }

    // MARK: - US-C9 — F7 Frustration (task friction) fusion construct

    /// US-C9 — the `F7FrustrationMode` rule on synthetic readings: (a) a negative face +
    /// sustained friction activates after the dwell; (b) a negative face ALONE never
    /// activates and (c) friction alone never activates (the CONJUNCTION law — either
    /// component at 0 ⇒ score 0); (d) a starved interaction reading yields NO output and,
    /// at the hub, the designed `.starved` state with no false event; (e) contributions
    /// are non-empty and confidence never exceeds the weakest channel; (f) the honesty
    /// contract. Synthetic `ChannelReading`s only — no camera, no Vision.
    private static func f7Frustration() {
        let mode = F7FrustrationMode()

        // Metadata / honesty contract.
        assert(mode.requires == [.face, .interaction], "EmotionSelfTests: F7 requires face + interaction")
        assert(!mode.rationale.isEmpty && !mode.confound.isEmpty,
               "EmotionSelfTests: F7 must explain itself and name its confound")
        assert(mode.hysteresis.enter > mode.hysteresis.exit,
               "EmotionSelfTests: F7 hysteresis must be a real band (enter > exit)")
        assert((0...1).contains(mode.confidenceCeiling), "EmotionSelfTests: F7 ceiling must be in 0…1")

        let t = Date(timeIntervalSinceReferenceDate: 800_000)
        func faceR(valence: Double, au4: Double, conf: Double) -> ChannelReading {
            ChannelReading(channel: .face, date: t, availability: .live, quality: conf,
                           valence: Meter(value: valence, confidence: conf),
                           arousal: Meter(value: 0, confidence: conf),
                           intensity: 0.5, features: au4 > 0 ? [.au4: au4] : [:], posterior: nil)
        }
        func interR(cancelDelta: Double, tempoDelta: Double, quality: Double,
                    availability: ChannelAvailability = .live) -> ChannelReading {
            ChannelReading(channel: .interaction, date: t, availability: availability, quality: quality,
                           valence: nil, arousal: nil, intensity: 0.5,
                           features: [.cancelRate: cancelDelta, .inputTempo: tempoDelta, .responseLatency: 0],
                           posterior: nil)
        }

        let negFace = faceR(valence: -0.6, au4: 0, conf: 0.8)
        let neutralFace = faceR(valence: 0.0, au4: 0, conf: 0.8)
        let friction = interR(cancelDelta: 0.4, tempoDelta: 0, quality: 0.7)
        let noFriction = interR(cancelDelta: 0, tempoDelta: 0, quality: 0.7)

        // (a) negative face + sustained friction ⇒ activates after the dwell.
        do {
            var latch = mode.hysteresis
            var activated = false
            for _ in 0..<(mode.hysteresis.enterDwellTicks + 2) {
                guard let out = mode.fuse([.face: negFace, .interaction: friction]) else {
                    assertionFailure("EmotionSelfTests: F7 must produce output when both channels are live"); break
                }
                assert(out.score > mode.hysteresis.enter,
                       "EmotionSelfTests: a negative-face + friction conjunction must clear the enter threshold, got \(out.score)")
                assert((out.contributions[.face] ?? 0) > 0 && (out.contributions[.interaction] ?? 0) > 0,
                       "EmotionSelfTests: both channel components must be present")
                assert(out.confidence <= 0.7 + 1e-9 && out.confidence <= mode.confidenceCeiling + 1e-9,
                       "EmotionSelfTests: F7 confidence must not exceed the weakest channel nor the ceiling, got \(out.confidence)")
                if latch.update(score: out.score) { activated = true }
            }
            assert(activated, "EmotionSelfTests: sustained negative-face + friction must activate F7 after the dwell")
        }

        // (b) negative face ALONE (zero friction) ⇒ score 0, NEVER activates.
        do {
            var latch = mode.hysteresis
            var everActive = false
            for _ in 0..<(mode.hysteresis.enterDwellTicks + 20) {
                let out = mode.fuse([.face: negFace, .interaction: noFriction])
                assert((out?.score ?? 1) == 0,
                       "EmotionSelfTests: a negative face with zero friction must score 0 (conjunction law)")
                if latch.update(score: out?.score ?? 0) { everActive = true }
            }
            assert(!everActive, "EmotionSelfTests: a negative face ALONE must NEVER activate F7")
        }

        // (c) friction alone (neutral face) ⇒ score 0, NEVER activates.
        do {
            var latch = mode.hysteresis
            var everActive = false
            for _ in 0..<(mode.hysteresis.enterDwellTicks + 20) {
                let out = mode.fuse([.face: neutralFace, .interaction: friction])
                assert((out?.score ?? 1) == 0,
                       "EmotionSelfTests: friction with a neutral face must score 0 (conjunction law)")
                if latch.update(score: out?.score ?? 0) { everActive = true }
            }
            assert(!everActive, "EmotionSelfTests: friction ALONE must NEVER activate F7")
        }

        // (d) starved (unavailable) interaction ⇒ NO output (never fabricate); missing too.
        do {
            let starved = interR(cancelDelta: 0.4, tempoDelta: 0, quality: 0.1, availability: .unavailable)
            assert(mode.fuse([.face: negFace, .interaction: starved]) == nil,
                   "EmotionSelfTests: a starved interaction reading must yield NO F7 output (designed state)")
            assert(mode.fuse([.face: negFace]) == nil,
                   "EmotionSelfTests: a missing interaction reading must yield NO F7 output")
        }

        // (e) contributions non-empty + confidence ≤ the weakest channel + evidence present.
        do {
            let out = mode.fuse([.face: faceR(valence: -0.6, au4: 0.7, conf: 0.6),
                                 .interaction: interR(cancelDelta: 0.5, tempoDelta: 0, quality: 0.9)])
            assert(out?.contributions.isEmpty == false, "EmotionSelfTests: a fused output must name its contributors")
            assert((out?.confidence ?? 1) <= 0.6 + 1e-9,
                   "EmotionSelfTests: F7 confidence must not exceed the weakest channel (0.6)")
            assert(out?.evidence.isEmpty == false, "EmotionSelfTests: a fused output must carry evidence signals")
            assert((0...1).contains(out?.score ?? -1), "EmotionSelfTests: F7 score must stay in 0…1")
        }

        // (f) hub-level: F7 enabled + interaction enabled-but-STARVED ⇒ the designed
        //     `.starved` state, NOT active, and NO fabricated `.constructStateChanged`.
        do {
            let fkey = FusionRegistry.enabledKey("f7-frustration")
            let ikey = InteractionChannel.enabledKey
            let fsaved = UserDefaults.standard.object(forKey: fkey)
            let isaved = UserDefaults.standard.object(forKey: ikey)
            UserDefaults.standard.set(true, forKey: fkey)
            UserDefaults.standard.set(true, forKey: ikey)
            let hub = AffectHub()
            hub.interaction.prepareForActivation()      // enabled, but no events ⇒ starved
            let before = hub.events.count
            let analysis = FrameAnalysis.absent(at: t, imageSize: CGSize(width: 640, height: 480))
            hub.face.onAnalysis?(analysis)              // drive the real fan-out
            let state = hub.fusionStates["f7-frustration"]
            assert(state != nil, "EmotionSelfTests: an enabled fusion mode must publish a live state")
            assert(state?.isActive == false, "EmotionSelfTests: a starved construct must not be active")
            if case .starved = state?.availability {} else {
                assertionFailure("EmotionSelfTests: an enabled-but-starved construct must resolve to .starved, got \(String(describing: state?.availability))")
            }
            assert(!hub.events.dropFirst(before).contains { $0.kind == .constructStateChanged },
                   "EmotionSelfTests: a starved construct must NEVER fire a constructStateChanged event")
            restore(fkey, fsaved)
            restore(ikey, isaved)
        }
    }

    // MARK: - US-C10 — F1 Composure-under-load fusion construct

    /// US-C10 — the `F1ComposureMode` rule on synthetic readings: (a) a calm face + a
    /// sustained UPWARD eye proxy activates after the dwell; (b) an EXPRESSIVE face +
    /// elevated proxy NEVER activates (calm is required); (c) a calm face + FLAT proxy
    /// never activates (the CONJUNCTION law — either component at 0 ⇒ score 0); (d) the
    /// low-expresser gate — low separability LOWERS the score (harder to activate) AND
    /// multiplies confidence down AND marks the output tentative (all three asserted,
    /// with the exact chosen constants); (e) proxy generality — a synthetic reading
    /// carrying a `gestureEnergy` delta as the ONLY proxy also drives the score (the
    /// future-proof path). Synthetic `ChannelReading`s only — no camera, no Vision.
    private static func f1Composure() {
        let mode = F1ComposureMode()

        // Metadata / honesty contract.
        assert(mode.requires == [.face, .eyes], "EmotionSelfTests: F1 requires face + eyes")
        assert(!mode.rationale.isEmpty && !mode.confound.isEmpty,
               "EmotionSelfTests: F1 must explain itself and name its confound")
        assert(mode.hysteresis.enter > mode.hysteresis.exit,
               "EmotionSelfTests: F1 hysteresis must be a real band (enter > exit)")
        assert(mode.confidenceCeiling <= 0.7 + 1e-9,
               "EmotionSelfTests: F1 ceiling must sit at/below F7's 0.7, got \(mode.confidenceCeiling)")
        assert((0...1).contains(mode.confidenceCeiling), "EmotionSelfTests: F1 ceiling must be in 0…1")

        let t = Date(timeIntervalSinceReferenceDate: 900_000)
        func faceR(valence: Double, intensity: Double, conf: Double, separability: Double? = nil) -> ChannelReading {
            ChannelReading(channel: .face, date: t, availability: .live, quality: conf,
                           valence: Meter(value: valence, confidence: conf),
                           arousal: Meter(value: 0, confidence: conf),
                           intensity: intensity, features: [:], posterior: nil,
                           expressiveSeparability: separability)
        }
        func eyesR(blinkDelta: Double, conf: Double = 0.3,
                   availability: ChannelAvailability = .live) -> ChannelReading {
            let mag = min(1, abs(blinkDelta) / 12)
            return ChannelReading(channel: .eyes, date: t, availability: availability, quality: conf,
                                  valence: nil, arousal: Meter(value: mag, confidence: conf),
                                  intensity: mag, features: [.blinkRate: blinkDelta], posterior: nil)
        }

        let calmFace = faceR(valence: 0.0, intensity: 0.1, conf: 0.8)
        let expressiveFace = faceR(valence: -0.7, intensity: 0.6, conf: 0.8)
        let proxyUp = eyesR(blinkDelta: 10)       // +10/min ⇒ elevation ≈ 0.83
        let proxyFlat = eyesR(blinkDelta: 0)      // no upward divergence

        // (a) calm face + sustained upward proxy ⇒ activates after the dwell.
        do {
            var latch = mode.hysteresis
            var activated = false
            for _ in 0..<(mode.hysteresis.enterDwellTicks + 2) {
                guard let out = mode.fuse([.face: calmFace, .eyes: proxyUp]) else {
                    assertionFailure("EmotionSelfTests: F1 must produce output when face+eyes are live"); break
                }
                assert(out.score > mode.hysteresis.enter,
                       "EmotionSelfTests: calm face + upward proxy must clear the enter threshold, got \(out.score)")
                assert((out.contributions[.face] ?? 0) > 0 && (out.contributions[.eyes] ?? 0) > 0,
                       "EmotionSelfTests: both the calm-face and proxy components must be present")
                assert(out.confidence <= mode.confidenceCeiling + 1e-9,
                       "EmotionSelfTests: F1 confidence must not exceed the ceiling, got \(out.confidence)")
                assert(out.evidence.contains(.valence) && out.evidence.contains(.blinkRate),
                       "EmotionSelfTests: F1 evidence must cite the calm face + the blink proxy")
                if latch.update(score: out.score) { activated = true }
            }
            assert(activated, "EmotionSelfTests: sustained calm-face + upward proxy must activate F1 after the dwell")
        }

        // (b) EXPRESSIVE face + elevated proxy ⇒ score 0, NEVER activates (calm required).
        do {
            var latch = mode.hysteresis
            var everActive = false
            for _ in 0..<(mode.hysteresis.enterDwellTicks + 20) {
                let out = mode.fuse([.face: expressiveFace, .eyes: proxyUp])
                assert((out?.score ?? 1) == 0,
                       "EmotionSelfTests: an expressive face must score 0 (calm required, conjunction law)")
                if latch.update(score: out?.score ?? 0) { everActive = true }
            }
            assert(!everActive, "EmotionSelfTests: an expressive face must NEVER activate F1")
        }

        // (c) calm face + FLAT proxy ⇒ score 0, NEVER activates (the conjunction).
        do {
            var latch = mode.hysteresis
            var everActive = false
            for _ in 0..<(mode.hysteresis.enterDwellTicks + 20) {
                let out = mode.fuse([.face: calmFace, .eyes: proxyFlat])
                assert((out?.score ?? 1) == 0,
                       "EmotionSelfTests: a calm face with a flat proxy must score 0 (conjunction law)")
                if latch.update(score: out?.score ?? 0) { everActive = true }
            }
            assert(!everActive, "EmotionSelfTests: a calm face ALONE must NEVER activate F1")
        }

        // (d) low-expresser gate: SAME calm-face + upward-proxy stimulus, high vs low
        //     separability. Low separability must (i) LOWER the score, (ii) multiply
        //     confidence down, (iii) MARK the output tentative — with the chosen constants
        //     (score floor 0.70, conf floor 0.40, threshold 0.35).
        do {
            let hiSep = 0.9, loSep = 0.05
            let hi = faceR(valence: 0.0, intensity: 0.1, conf: 0.8, separability: hiSep)
            let lo = faceR(valence: 0.0, intensity: 0.1, conf: 0.8, separability: loSep)
            guard let outHi = mode.fuse([.face: hi, .eyes: proxyUp]),
                  let outLo = mode.fuse([.face: lo, .eyes: proxyUp]) else {
                assertionFailure("EmotionSelfTests: F1 must produce output under the gate"); return
            }
            assert(outLo.score < outHi.score,
                   "EmotionSelfTests: low separability must LOWER the score (harder to activate): \(outLo.score) !< \(outHi.score)")
            assert(outLo.confidence < outHi.confidence,
                   "EmotionSelfTests: low separability must multiply confidence down: \(outLo.confidence) !< \(outHi.confidence)")
            assert(outLo.separabilityLimited && !outHi.separabilityLimited,
                   "EmotionSelfTests: low separability must MARK the output tentative (and high must not)")
            assert(F1ComposureMode.lowSeparabilityThreshold == 0.35,
                   "EmotionSelfTests: the documented low-expresser threshold is 0.35")
            // The score ratio is EXACTLY the ratio of the chosen score-gate multipliers
            // (raw score is identical; only the gate differs).
            let gateHi = F1ComposureMode.scoreGateFloor + (1 - F1ComposureMode.scoreGateFloor) * hiSep
            let gateLo = F1ComposureMode.scoreGateFloor + (1 - F1ComposureMode.scoreGateFloor) * loSep
            assert(abs(outHi.score / outLo.score - gateHi / gateLo) < 1e-9,
                   "EmotionSelfTests: the score-gate ratio must match the chosen 0.70 floor")
        }

        // (e) proxy generality: a calm face + FLAT eyes + a synthetic reading carrying a
        //     gestureEnergy delta as the ONLY proxy still drives the score (future-proof).
        do {
            let hands = ChannelReading(channel: .hands, date: t, availability: .live, quality: 0.6,
                                       valence: nil, arousal: Meter(value: 0.6, confidence: 0.4),
                                       intensity: 0.6, features: [.gestureEnergy: 0.6], posterior: nil)
            guard let out = mode.fuse([.face: calmFace, .eyes: proxyFlat, .hands: hands]) else {
                assertionFailure("EmotionSelfTests: F1 must still fuse when face+eyes are present"); return
            }
            assert((out.contributions[.hands] ?? 0) > 0,
                   "EmotionSelfTests: the gestureEnergy proxy must register a hands contribution")
            assert(out.score > 0,
                   "EmotionSelfTests: a gestureEnergy-only proxy must drive the F1 score (future-proof path)")
            assert(out.evidence.contains(.gestureEnergy),
                   "EmotionSelfTests: F1 must cite the gestureEnergy proxy it used")
        }

        // (f) VOICE proxy SCALES: vocalF0 is an Hz delta — +30 Hz (half of
        //     `VoiceChannel.f0DeltaScale` 60) must register elevation 0.5, NOT saturate
        //     (the pre-fix placeholder scale 1.0 read ANY ≥1 Hz rise as a maxed proxy);
        //     vocalIntensity participates on its own 0.08 RMS scale (the PRD F1 spec
        //     names BOTH: "vocal F0/intensity↑").
        do {
            func voiceR(_ features: [FeatureKey: Double]) -> ChannelReading {
                ChannelReading(channel: .voice, date: t, availability: .live, quality: 0.5,
                               valence: nil, arousal: Meter(value: 0.75, confidence: 0.3),
                               intensity: 0.5, features: features, posterior: nil)
            }
            guard let outF0 = mode.fuse([.face: calmFace, .eyes: proxyFlat,
                                         .voice: voiceR([.vocalF0: 30])]) else {
                assertionFailure("EmotionSelfTests: F1 must fuse with a voice proxy present"); return
            }
            assert(abs((outF0.contributions[.voice] ?? 0) - 0.5) < 1e-9,
                   "EmotionSelfTests: a +30 Hz vocalF0 delta must read elevation 0.5 on the 60 Hz scale, got \(outF0.contributions[.voice] ?? -1)")
            assert(outF0.evidence.contains(.vocalF0),
                   "EmotionSelfTests: F1 must cite the vocalF0 proxy it used")
            guard let outInt = mode.fuse([.face: calmFace, .eyes: proxyFlat,
                                          .voice: voiceR([.vocalIntensity: 0.04])]) else {
                assertionFailure("EmotionSelfTests: F1 must fuse with a vocal-intensity proxy present"); return
            }
            assert(abs((outInt.contributions[.voice] ?? 0) - 0.5) < 1e-9,
                   "EmotionSelfTests: a +0.04 RMS vocalIntensity delta must read elevation 0.5 on the 0.08 scale, got \(outInt.contributions[.voice] ?? -1)")
            assert(outInt.evidence.contains(.vocalIntensity),
                   "EmotionSelfTests: F1 must cite the vocalIntensity proxy it used")
        }
    }

    // MARK: - US-C11 — F3 Fatigue ⇄ Engagement (the ONE coupled meter)

    /// US-C11 — the `F3FatigueEngagementMode` coupled construct on synthetic readings:
    /// (a) sustained blink↑ + closures over ≥20 min latches the FATIGUED pole, and the
    /// SAME stimulus at minute 2 yields a WEAKER axis (the accrual asymmetry); (b)
    /// sustained suppression latches the ENGAGED pole, and session time does NOT amplify
    /// it; (c) dead-band alternation never latches either pole; (d) mutual exclusion — a
    /// hard flip makes the fatigued pole EXIT to neutral BEFORE the engaged pole can
    /// enter (no dual-active tick, the ONE-meter law); (f) the additive-Codable check the
    /// golden fixture relies on (constructID round-trips; a missing key decodes to nil);
    /// plus the ladder mapping and (g) an honesty sweep of every new string. Synthetic
    /// `ChannelReading`s only — no camera, no Vision. (Routing (e) lives in
    /// `narratorHonesty` alongside the F1/F7 routing.)
    private static func f3FatigueEngagement() {
        let mode = F3FatigueEngagementMode()
        let t = Date(timeIntervalSinceReferenceDate: 950_000)

        // Metadata / honesty contract.
        assert(mode.requires == [.eyes], "EmotionSelfTests: F3 requires the eyes lens only (context is a modifier)")
        assert(!mode.rationale.isEmpty && !mode.confound.isEmpty,
               "EmotionSelfTests: F3 must explain itself and name its confound")
        assert(mode.confidenceCeiling <= 0.7 + 1e-9, "EmotionSelfTests: F3 ceiling must sit at/below 0.7")
        assert(F3FatigueEngagementMode.poleExitDwell < F3FatigueEngagementMode.poleEnterDwell,
               "EmotionSelfTests: F3's exit dwell must be shorter than its enter dwell (the dead band)")

        func eyesR(blinkDelta: Double, variance: Double, prolonged: Bool, conf: Double = 0.3,
                   availability: ChannelAvailability = .live) -> ChannelReading {
            ChannelReading(channel: .eyes, date: t, availability: availability, quality: conf,
                           valence: nil, arousal: Meter(value: min(1, abs(blinkDelta) / 12), confidence: conf),
                           intensity: 0,
                           features: [.blinkRate: blinkDelta, .eyeOpenVariance: variance,
                                      .prolongedClosure: prolonged ? 1 : 0],
                           posterior: nil)
        }
        func contextR(minutes: Double) -> ChannelReading {
            ChannelReading(channel: .context, date: t, availability: .live, quality: 1,
                           valence: nil, arousal: nil, intensity: 0,
                           features: [.sessionMinutes: minutes], posterior: nil)
        }

        let fatigueEyes = eyesR(blinkDelta: 6, variance: 0.02, prolonged: true)   // blink↑ + closure + unsteady
        let engagedEyes = eyesR(blinkDelta: -8, variance: 0, prolonged: false)     // suppression + perfectly steady

        // (a) sustained fatigue stimulus over 25 min ⇒ the FATIGUED (negative) pole latches
        //     after the enter dwell; and the SAME stimulus is WEAKER at minute 2 (accrual).
        do {
            guard mode.fuse([.eyes: fatigueEyes, .context: contextR(minutes: 25)]) != nil else {
                assertionFailure("EmotionSelfTests: F3 must fuse when the eyes lens is live"); return
            }
            var latch = mode.coupledLatch
            var pole: Pole = .neutral
            for _ in 0..<(F3FatigueEngagementMode.poleEnterDwell + 4) {
                let out = mode.fuse([.eyes: fatigueEyes, .context: contextR(minutes: 25)])!
                pole = latch.update(axis: out.axis ?? 0)
            }
            assert(pole == .negative,
                   "EmotionSelfTests: sustained blink↑ + closures over 25 min must latch the fatigued pole, got \(pole)")

            let axis25 = mode.fuse([.eyes: fatigueEyes, .context: contextR(minutes: 25)])!.axis ?? 0
            let axis2 = mode.fuse([.eyes: fatigueEyes, .context: contextR(minutes: 2)])!.axis ?? 0
            assert(axis25 < 0 && axis2 < 0, "EmotionSelfTests: the fatigue axis must be negative at both times")
            assert(abs(axis25) > abs(axis2),
                   "EmotionSelfTests: accrual asymmetry — the same stimulus at 25 min must exceed minute 2 (\(axis25) vs \(axis2))")
        }

        // (b) sustained suppression ⇒ the ENGAGED (positive) pole latches; session time
        //     does NOT amplify it (the documented asymmetry — accrual is fatigue-only).
        do {
            var latch = mode.coupledLatch
            var pole: Pole = .neutral
            for _ in 0..<(F3FatigueEngagementMode.poleEnterDwell + 4) {
                let out = mode.fuse([.eyes: engagedEyes, .context: contextR(minutes: 25)])!
                pole = latch.update(axis: out.axis ?? 0)
            }
            assert(pole == .positive,
                   "EmotionSelfTests: sustained blink suppression must latch the engaged pole, got \(pole)")
            let eng2 = mode.fuse([.eyes: engagedEyes, .context: contextR(minutes: 2)])!.axis ?? 0
            let eng40 = mode.fuse([.eyes: engagedEyes, .context: contextR(minutes: 40)])!.axis ?? 0
            assert(eng2 > 0, "EmotionSelfTests: the engaged axis must be positive")
            assert(abs(eng2 - eng40) < 1e-9,
                   "EmotionSelfTests: session time must NOT amplify engagement (\(eng2) vs \(eng40))")
        }

        // (c) dead-band alternation (small up/down) ⇒ neither pole ever latches.
        do {
            var latch = mode.coupledLatch
            var everActive = false
            for i in 0..<80 {
                let delta = (i % 2 == 0) ? 3.0 : -3.0
                let out = mode.fuse([.eyes: eyesR(blinkDelta: delta, variance: 0.004, prolonged: false),
                                     .context: contextR(minutes: 10)])!
                if latch.update(axis: out.axis ?? 0) != .neutral { everActive = true }
            }
            assert(!everActive, "EmotionSelfTests: dead-band alternation must never latch a pole")
        }

        // (d) mutual exclusion: fatigued-active, then a HARD flip to suppression ⇒ the
        //     fatigued pole exits to neutral BEFORE engaged can enter (no dual-active tick).
        do {
            var latch = mode.coupledLatch
            for _ in 0..<(F3FatigueEngagementMode.poleEnterDwell + 2) { _ = latch.update(axis: -0.8) }
            assert(latch.pole == .negative, "EmotionSelfTests: the fatigued pole must be latched before the flip")

            var poles: [Pole] = []
            for _ in 0..<(F3FatigueEngagementMode.poleEnterDwell + 2) { poles.append(latch.update(axis: 0.8)) }
            let firstNonNegative = poles.first { $0 != .negative }
            assert(firstNonNegative == .neutral,
                   "EmotionSelfTests: on a hard flip the fatigued pole must exit to NEUTRAL before engaged enters, got \(String(describing: firstNonNegative))")
            assert(poles.contains(.positive), "EmotionSelfTests: the engaged pole must eventually enter after the flip")
            if let firstPos = poles.firstIndex(of: .positive), let firstNeu = poles.firstIndex(of: .neutral) {
                assert(firstNeu < firstPos, "EmotionSelfTests: the neutral dead band must precede the engaged entry")
            }
            assert(latch.pole == .positive, "EmotionSelfTests: the latch must settle on the engaged pole")
        }

        // Ladder mapping: a fatigued-active state resolves L0/L1/L2 + a fatigued verdict; a
        // non-latched state shows the dead-band fork; a nil output ⇒ no ladder.
        do {
            assert(F3FatigueEngagementMode.ladder(output: nil, isActive: false).isEmpty,
                   "EmotionSelfTests: a nil output must yield no F3 ladder")
            let out = mode.fuse([.eyes: fatigueEyes, .context: contextR(minutes: 22)])!
            let active = F3FatigueEngagementMode.ladder(output: out, isActive: true)
            assert(active.count == 4, "EmotionSelfTests: the F3 ladder has 4 rungs, got \(active.count)")
            assert(active[0].status == .resolved, "EmotionSelfTests: L0 must resolve on a clear blink trend")
            assert(active[1].status == .resolved, "EmotionSelfTests: L1 must resolve with a prolonged closure present")
            assert(active[3].status == .resolved && active[3].claim == HonestyPhrases.fatigueEngagementVerdictFatigued,
                   "EmotionSelfTests: the verdict rung must resolve to the fatigued pole")
            let neutral = F3FatigueEngagementMode.ladder(output: out, isActive: false)
            guard case .ambiguous = neutral[3].status else {
                assertionFailure("EmotionSelfTests: a non-latched F3 state must show the dead-band fork"); return
            }
            assert(Set(active.map(\.id)).count == active.count, "EmotionSelfTests: F3 ladder rung ids must be unique")
        }

        // (f) additive Codable (the golden-trace guarantee): a constructID round-trips, and
        //     a nil constructID is OMITTED on encode + decodes back to nil (old traces).
        do {
            let enc = GoldenTraceCoding.encoder()
            let dec = GoldenTraceCoding.decoder()
            let withID = AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.5,
                                     confidence: 0.3, evidence: [.blinkRate],
                                     baselineDelta: -0.6, constructID: ConstructID.fatigueEngagement)
            guard let data = try? enc.encode(withID),
                  let back = try? dec.decode(AffectEvent.self, from: data) else {
                assertionFailure("EmotionSelfTests: F3 event failed to Codable round-trip"); return
            }
            assert(back.constructID == ConstructID.fatigueEngagement,
                   "EmotionSelfTests: constructID must survive the Codable round-trip")
            assert(back.baselineDelta == -0.6, "EmotionSelfTests: the signed axis must survive on baselineDelta")

            let noID = AffectEvent(channel: .eyes, kind: .blink, magnitude: 1, confidence: 0.5, evidence: [.blinkRate])
            guard let noData = try? enc.encode(noID) else {
                assertionFailure("EmotionSelfTests: legacy event failed to encode"); return
            }
            assert(!String(decoding: noData, as: UTF8.self).contains("constructID"),
                   "EmotionSelfTests: a nil constructID must be OMITTED on encode (pre-US-C11 traces unchanged)")
            assert((try? dec.decode(AffectEvent.self, from: noData))?.constructID == nil,
                   "EmotionSelfTests: an event with no constructID key must decode to nil")
        }

        // (g) honesty sweep of every new F3 string, + both pole narrations (Persona framing,
        //     a cited present signal, a confidence word, and the sanctioned nudge/confound).
        let copy = [
            HonestyPhrases.fatigueEngagementRationale,
            HonestyPhrases.fatigueEngagementConfound,
            HonestyPhrases.fatigueEngagementEngagedState,
            HonestyPhrases.fatigueEngagementFatiguedState,
            HonestyPhrases.fatigueEngagementLadderL0, HonestyPhrases.fatigueEngagementLadderL0Fork,
            HonestyPhrases.fatigueEngagementLadderL1, HonestyPhrases.fatigueEngagementLadderL1Fork,
            HonestyPhrases.fatigueEngagementLadderL2(minutes: 22), HonestyPhrases.fatigueEngagementLadderL2Fork,
            HonestyPhrases.fatigueEngagementVerdictEngaged, HonestyPhrases.fatigueEngagementVerdictFatigued,
            HonestyPhrases.fatigueEngagementVerdictNeutral, HonestyPhrases.fatigueEngagementVerdictNeutralFork,
            mode.title
        ]
        for c in copy {
            assert(!HonestyPhrases.containsBanned(c), "EmotionSelfTests: F3 copy contains a banned substring: \(c)")
        }
        for engaged in [true, false] {
            let text = HonestyPhrases.fatigueEngagement(engaged: engaged,
                                                        evidence: [.blinkRate, .prolongedClosure], confidence: 0.3)
            assert(!HonestyPhrases.containsBanned(text), "EmotionSelfTests: F3 narration banned: \(text)")
            assert(text.localizedCaseInsensitiveContains("persona"),
                   "EmotionSelfTests: F3 narration must keep the Persona framing: \(text)")
            assert(text.localizedCaseInsensitiveContains(SignalRef.blinkRate.displayName),
                   "EmotionSelfTests: F3 narration must cite the blink proxy: \(text)")
            assert(HonestyPhrases.confidenceWords.contains { text.localizedCaseInsensitiveContains($0) },
                   "EmotionSelfTests: F3 narration must state a confidence word: \(text)")
        }
        assert(HonestyPhrases.fatigueEngagementVerdictFatigued.localizedCaseInsensitiveContains("consider a break"),
               "EmotionSelfTests: the fatigued verdict must carry the sanctioned 'consider a break' nudge")
        assert(HonestyPhrases.fatigueEngagementConfound.localizedCaseInsensitiveContains("boredom"),
               "EmotionSelfTests: the F3 confound must name the boredom / low-arousal confound")
    }

    // MARK: - US-C10 — the disambiguation-ladder MODEL (§6.6, the honesty widget)

    /// US-C10 — the reusable ladder MODEL: F1's builder maps live state to rungs
    /// (resolved / ambiguous / ruledOut), the tentative rung appears ONLY under the §5.4
    /// gate, the PERMANENT refusal rung is `.ruledOut` (greyed + struck) and banned-clean,
    /// a nil output yields no ladder, rung ids are unique, and F7 reuses the same widget.
    // MARK: - US-D14a — MotivationalDirection (the reusable approach/withdrawal primitive)

    /// US-D14a — the `MotivationalDirection` blend (§4.3): (k) HIGH motor + level head ⇒
    /// approach (+); LOW motor + head down-and-away ⇒ withdrawal (−); a MISSING cue shrinks
    /// the magnitude (never fabricates); all-nil ⇒ 0; the squash keeps it inside (−1, +1).
    private static func motivationalDirection() {
        func dir(_ m: Double?, _ h: Double?, _ g: Double?) -> Double {
            MotivationalDirection.direction(motorEnergy: m, headLean: h, gestureRate: g)
        }

        // (k) high motor + level head ⇒ approach; low motor + down-away ⇒ withdrawal.
        let approach = dir(1.0, 0.0, nil)
        assert(approach > 0, "EmotionSelfTests: high motor + level head must lean approach (+), got \(approach)")
        let withdrawal = dir(0.0, -1.0, nil)
        assert(withdrawal < 0, "EmotionSelfTests: low motor + head down-away must lean withdrawal (−), got \(withdrawal)")

        // Missing head ⇒ the magnitude SHRINKS (fewer voters ⇒ a weaker, never a fabricated, lean).
        let bothApproach = dir(1.0, 1.0, nil)
        let motorOnly = dir(1.0, nil, nil)
        assert(motorOnly > 0 && motorOnly < bothApproach,
               "EmotionSelfTests: dropping the head cue must shrink the approach magnitude (\(motorOnly) vs \(bothApproach))")

        // All-nil ⇒ exactly 0 (no evidence, no fabricated lean); the squash stays in (−1, +1).
        assert(dir(nil, nil, nil) == 0, "EmotionSelfTests: no cues must yield a 0 (neutral) direction")
        assert(abs(dir(1.0, 1.0, 1.0)) < 1 && abs(dir(0.0, -1.0, 0.0)) < 1,
               "EmotionSelfTests: the squashed direction must stay within (−1, +1)")

        // An expansive gesture ADDS to an approach lean, but is the lightest voter.
        let withGesture = dir(1.0, 1.0, 1.0)
        assert(withGesture > bothApproach,
               "EmotionSelfTests: an expansive gesture must add to an approach lean (\(withGesture) vs \(bothApproach))")
    }

    // MARK: - US-D14a — F2 Cognitive load / effort fusion construct

    /// US-D14a — the `F2CognitiveLoadMode` rule on synthetic readings: (a) MVV — eyes
    /// suppression + interaction slowing ALONE raise load (no hands/head needed); (b) adding
    /// hand-tension raises it further (renormalization sane); (c) HIGH gesture energy does NOT
    /// raise load (the sign discipline — motion is not load); (d) a noisy load series has a
    /// larger spread than a steady one (the variance); (e) a missing/starved required channel
    /// yields NO output; (f) the never-"stress" honesty sweep. Synthetic readings — no camera.
    private static func f2CognitiveLoad() {
        let mode = F2CognitiveLoadMode()
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // Metadata / honesty contract.
        assert(mode.requires == [.eyes, .interaction], "EmotionSelfTests: F2 requires eyes + interaction (the MVV)")
        assert(!mode.rationale.isEmpty && !mode.confound.isEmpty,
               "EmotionSelfTests: F2 must explain itself and name its confound")
        assert(mode.confidenceCeiling <= 0.7 + 1e-9, "EmotionSelfTests: F2 ceiling must sit at/below 0.7")
        assert(mode.hysteresis.enter > mode.hysteresis.exit, "EmotionSelfTests: F2 hysteresis must be a real band")

        func eyesR(blinkDelta: Double, quality: Double = 0.8) -> ChannelReading {
            ChannelReading(channel: .eyes, date: t, availability: .live, quality: quality,
                           valence: nil, arousal: Meter(value: 0, confidence: quality), intensity: 0,
                           features: [.blinkRate: blinkDelta], posterior: nil)
        }
        func interR(tempoDelta: Double, cancelDelta: Double, quality: Double = 0.8) -> ChannelReading {
            ChannelReading(channel: .interaction, date: t, availability: .live, quality: quality,
                           valence: nil, arousal: nil, intensity: 0,
                           features: [.inputTempo: tempoDelta, .cancelRate: cancelDelta], posterior: nil)
        }
        func handsR(selfTouch: Double, gestureDelta: Double, aperture: Double, quality: Double = 0.8) -> ChannelReading {
            ChannelReading(channel: .hands, date: t, availability: .live, quality: quality,
                           valence: nil, arousal: Meter(value: max(0, gestureDelta / 0.5), confidence: quality),
                           intensity: 0,
                           features: [.selfTouchRate: selfTouch, .gestureEnergy: gestureDelta, .handAperture: aperture],
                           posterior: nil)
        }

        // (a) MVV: eyes suppression + interaction slowing ALONE ⇒ load rises (no hands/head).
        guard let mvv = mode.fuse([.eyes: eyesR(blinkDelta: -6), .interaction: interR(tempoDelta: -8, cancelDelta: 0)]) else {
            assertionFailure("EmotionSelfTests: F2 must fuse with eyes + interaction alone"); return
        }
        assert(mvv.score > 0.3, "EmotionSelfTests: suppressed blinks + slower input alone must raise load, got \(mvv.score)")
        assert(mvv.confidence <= mode.confidenceCeiling + 1e-9, "EmotionSelfTests: F2 confidence must respect the ceiling")
        assert(!mvv.evidence.isEmpty, "EmotionSelfTests: F2 must cite the present signals")
        assert((0...1).contains(mvv.score), "EmotionSelfTests: F2 load must stay in 0…1")

        // (b) enhancement: adding hand-tension (self-touch + clenched, still hands) raises it.
        let enhanced = mode.fuse([.eyes: eyesR(blinkDelta: -6), .interaction: interR(tempoDelta: -8, cancelDelta: 0),
                                  .hands: handsR(selfTouch: 3.0, gestureDelta: -0.3, aperture: 0.1)])!
        assert(enhanced.score > mvv.score,
               "EmotionSelfTests: adding hand-tension must raise the load (\(enhanced.score) vs \(mvv.score))")

        // (c) motion ≠ load: HIGH gesture energy (brisk motion, open hand) does NOT raise load.
        let withMotion = mode.fuse([.eyes: eyesR(blinkDelta: -6), .interaction: interR(tempoDelta: -8, cancelDelta: 0),
                                    .hands: handsR(selfTouch: 0, gestureDelta: 0.5, aperture: 0.9)])!
        assert(withMotion.score <= mvv.score + 1e-9,
               "EmotionSelfTests: brisk hand MOTION must not raise load (the sign discipline) — \(withMotion.score) vs \(mvv.score)")

        // (d) variance: a noisy load series ⇒ a larger spread than a steady one.
        let noisy = F2CognitiveLoadMode.spread(of: [0.1, 0.9, 0.2, 0.8, 0.15, 0.85])
        let steady = F2CognitiveLoadMode.spread(of: [0.5, 0.5, 0.5, 0.5, 0.5, 0.5])
        assert(noisy > steady, "EmotionSelfTests: a noisy load series must have a larger spread (\(noisy) vs \(steady))")
        assert(steady == 0, "EmotionSelfTests: a flat load series must have zero spread")
        var window = RollingLoad(window: mode.spreadWindow)
        var lastSpread = 0.0
        for (i, v) in [0.1, 0.9, 0.2, 0.8].enumerated() { lastSpread = window.record(v, at: t.addingTimeInterval(Double(i))) }
        assert(lastSpread > 0, "EmotionSelfTests: a wobbling RollingLoad must report a positive spread")

        // (e) a missing OR starved required channel ⇒ NO output (never fabricate).
        assert(mode.fuse([.eyes: eyesR(blinkDelta: -6)]) == nil,
               "EmotionSelfTests: F2 needs BOTH required channels — missing interaction ⇒ nil")
        let starvedInter = ChannelReading(channel: .interaction, date: t, availability: .unavailable, quality: 0,
                                          valence: nil, arousal: nil, intensity: 0, features: [:], posterior: nil)
        assert(mode.fuse([.eyes: eyesR(blinkDelta: -6), .interaction: starvedInter]) == nil,
               "EmotionSelfTests: a starved interaction reading ⇒ no F2 output (the designed state)")

        // (f) the never-"stress" honesty sweep over the new F2 strings.
        let f2Copy = [HonestyPhrases.cognitiveLoadState, HonestyPhrases.cognitiveLoadRationale,
                      HonestyPhrases.cognitiveLoadConfound, mode.title,
                      HonestyPhrases.cognitiveLoad(evidence: [.blinkRate, .inputTempo], confidence: 0.4)]
        for copy in f2Copy {
            assert(!HonestyPhrases.containsBanned(copy), "EmotionSelfTests: F2 copy contains a banned substring: \(copy)")
            assert(!copy.localizedCaseInsensitiveContains("stress"), "EmotionSelfTests: F2 copy must never say 'stress': \(copy)")
        }
        assert(HonestyPhrases.cognitiveLoadState.localizedCaseInsensitiveContains("effort"),
               "EmotionSelfTests: F2's named state must carry the effort/load framing")
    }

    // MARK: - US-D14a — F4 Frown + head-down disambiguation fusion construct

    /// US-D14a — the `F4FrownHeadDownMode` rule + ladder on synthetic readings: quiescent with
    /// no lowered brow; (f) down-pitch + AU4-alone ⇒ effort-lean, anger NEVER surfaced (the
    /// killer demo); (g) AU4+AU5 + approach ⇒ the exact "leans displeasure-approach" LEAN;
    /// (h) AU1+AU15 + withdrawal ⇒ dejection-withdrawal; (i) L3 head-orientation resolves
    /// toward-content (effort) / down-and-away (withdrawal), both low-confidence; (j) conflicting
    /// arms ⇒ the L1 fork + an "ambiguous" output; plus the permanent ruled-out anger rung and
    /// the honesty sweep. Synthetic `ChannelReading`s only — no camera, no Vision.
    private static func f4Ladder() {
        let mode = F4FrownHeadDownMode()
        let t = Date(timeIntervalSinceReferenceDate: 1_100_000)

        // Metadata / honesty contract.
        assert(mode.requires == [.face, .head], "EmotionSelfTests: F4 requires face + head")
        assert(!mode.rationale.isEmpty && !mode.confound.isEmpty,
               "EmotionSelfTests: F4 must explain itself and name its confound")
        assert(mode.confidenceCeiling <= 0.5 + 1e-9,
               "EmotionSelfTests: F4 ceiling ≤ 0.5 (a disambiguation aid, not a verdict)")

        func faceR(au4: Double, au1: Double = 0, au5: Double = 0, au7: Double = 0, au15: Double = 0,
                   conf: Double = 0.7) -> ChannelReading {
            var f: [FeatureKey: Double] = [.au4: au4]
            if au1 > 0 { f[.au1] = au1 }; if au5 > 0 { f[.au5] = au5 }
            if au7 > 0 { f[.au7] = au7 }; if au15 > 0 { f[.au15] = au15 }
            return ChannelReading(channel: .face, date: t, availability: .live, quality: conf,
                                  valence: Meter(value: -0.3, confidence: conf),
                                  arousal: Meter(value: 0.2, confidence: conf), intensity: 0.5,
                                  features: f, posterior: nil)
        }
        func headR(pitch: Double, yaw: Double, dominance: Double, motion: Double) -> ChannelReading {
            ChannelReading(channel: .head, date: t, availability: .live, quality: 0.4,
                           valence: nil, arousal: Meter(value: motion, confidence: 0.4), intensity: motion,
                           features: [.headPitch: pitch, .headYaw: yaw, .dominanceLean: dominance,
                                      .headMotionEnergy: 0], posterior: nil)
        }

        // Quiescent: no lowered brow (AU4 below the trigger) ⇒ NO output (no fabricated ladder).
        assert(mode.fuse([.face: faceR(au4: 0.05), .head: headR(pitch: -0.3, yaw: 0, dominance: 0, motion: 0.2)]) == nil,
               "EmotionSelfTests: F4 must stay quiescent (nil) with no lowered brow to disambiguate")

        // (f) down-pitch + AU4-alone + weak direction ⇒ effort-lean; anger NEVER in the state.
        let effort = mode.fuse([.face: faceR(au4: 0.7),
                                .head: headR(pitch: -0.3, yaw: 0.0, dominance: 0.0, motion: 0.5)])!
        assert(effort.namedState == HonestyPhrases.frownHeadDownLeanEffort,
               "EmotionSelfTests: AU4-alone under head-down must lean focused effort, got \(String(describing: effort.namedState))")
        assert(!(effort.namedState ?? "").localizedCaseInsensitiveContains("anger"),
               "EmotionSelfTests: a lowered brow under head-down must NEVER surface 'anger' (the killer demo)")

        // (g) AU4 + AU5 + approach ⇒ the exact "leans displeasure-approach" LEAN (not a label).
        let approach = mode.fuse([.face: faceR(au4: 0.7, au5: 0.6),
                                  .head: headR(pitch: 0.0, yaw: 0.0, dominance: 0.6, motion: 1.0)])!
        assert(approach.namedState == HonestyPhrases.frownHeadDownLeanApproach,
               "EmotionSelfTests: AU4+AU5 + approach must lean displeasure-approach, got \(String(describing: approach.namedState))")

        // (h) AU1 + AU15 + withdrawal ⇒ dejection-withdrawal lean.
        let withdrawal = mode.fuse([.face: faceR(au4: 0.6, au1: 0.6, au15: 0.6),
                                    .head: headR(pitch: -0.4, yaw: 0.5, dominance: -0.6, motion: 0.0)])!
        assert(withdrawal.namedState == HonestyPhrases.frownHeadDownLeanWithdrawal,
               "EmotionSelfTests: AU1+AU15 + withdrawal must lean dejection-withdrawal, got \(String(describing: withdrawal.namedState))")

        // (i) L3 head-orientation: toward-content ⇒ effort-side (resolved + low-confidence gaze
        //     caveat); down-and-away ⇒ withdrawal-side (resolved). Both are gaze-blind.
        let towardLadder = F4FrownHeadDownMode.ladder(output: approach, isActive: true)   // approach head was level
        let l3Toward = towardLadder.first { $0.claim == HonestyPhrases.frownHeadDownL3Toward }
        assert(l3Toward?.status == .resolved, "EmotionSelfTests: a toward-content head must resolve L3 to the effort side")
        assert(HonestyPhrases.frownHeadDownL3Toward.localizedCaseInsensitiveContains("gaze"),
               "EmotionSelfTests: the toward-content L3 rung must carry the low-confidence gaze caveat")
        let awayLadder = F4FrownHeadDownMode.ladder(output: withdrawal, isActive: true)   // withdrawal head down-and-away
        let l3Away = awayLadder.first { $0.claim == HonestyPhrases.frownHeadDownL3Withdrawal }
        assert(l3Away?.status == .resolved, "EmotionSelfTests: a down-and-away head must resolve L3 to the withdrawal side")

        // (j) conflicting arms + weak direction ⇒ the L1 morphology fork + an "ambiguous" output.
        let ambiguous = mode.fuse([.face: faceR(au4: 0.5, au1: 0.3, au5: 0.3, au15: 0.3),
                                   .head: headR(pitch: -0.2, yaw: 0.05, dominance: 0.0, motion: 0.5)])!
        assert(ambiguous.namedState == HonestyPhrases.frownHeadDownLeanAmbiguous,
               "EmotionSelfTests: conflicting arms + weak direction must stay ambiguous, got \(String(describing: ambiguous.namedState))")
        let ambLadder = F4FrownHeadDownMode.ladder(output: ambiguous, isActive: false)
        guard case .ambiguous = ambLadder[1].status else {     // rung index 1 == L1 brow morphology
            assertionFailure("EmotionSelfTests: an ambiguous F4 state must show the L1 morphology fork"); return
        }

        // Ladder shape: nil ⇒ empty; a real ladder has unique ids, reflects the L0 head-down
        // correction, and ENDS on the permanent ruled-out anger refusal (banned-clean).
        assert(F4FrownHeadDownMode.ladder(output: nil, isActive: false).isEmpty,
               "EmotionSelfTests: a nil F4 output must yield no ladder")
        let ladder = F4FrownHeadDownMode.ladder(output: effort, isActive: true)
        assert(Set(ladder.map(\.id)).count == ladder.count, "EmotionSelfTests: F4 ladder rung ids must be unique")
        assert(ladder[0].claim == HonestyPhrases.frownHeadDownL0HeadDown && ladder[0].status == .resolved,
               "EmotionSelfTests: L0 must reflect the inherited head-down correction")
        guard let refusal = ladder.last, case .ruledOut(let reason) = refusal.status else {
            assertionFailure("EmotionSelfTests: the last F4 rung must be the ruledOut anger refusal"); return
        }
        assert(!HonestyPhrases.containsBanned(refusal.claim) && !HonestyPhrases.containsBanned(reason),
               "EmotionSelfTests: the F4 refusal rung must be banned-clean")

        // Honesty sweep over the new F4 strings (leans, every ladder rung, the narration).
        let f4Copy = [HonestyPhrases.frownHeadDownRationale, HonestyPhrases.frownHeadDownConfound,
                      HonestyPhrases.frownHeadDownLeanEffort, HonestyPhrases.frownHeadDownLeanApproach,
                      HonestyPhrases.frownHeadDownLeanWithdrawal, HonestyPhrases.frownHeadDownLeanAmbiguous,
                      HonestyPhrases.frownHeadDownL0HeadDown, HonestyPhrases.frownHeadDownL0Level,
                      HonestyPhrases.frownHeadDownL1, HonestyPhrases.frownHeadDownL1Fork,
                      HonestyPhrases.frownHeadDownL1Anger, HonestyPhrases.frownHeadDownL1Sadness,
                      HonestyPhrases.frownHeadDownL1Effort, HonestyPhrases.frownHeadDownL2,
                      HonestyPhrases.frownHeadDownL2Fork, HonestyPhrases.frownHeadDownL2Approach,
                      HonestyPhrases.frownHeadDownL2Withdrawal, HonestyPhrases.frownHeadDownL3,
                      HonestyPhrases.frownHeadDownL3Fork, HonestyPhrases.frownHeadDownL3Toward,
                      HonestyPhrases.frownHeadDownL3Withdrawal, HonestyPhrases.frownHeadDownL4,
                      HonestyPhrases.frownHeadDownL4Loaded, HonestyPhrases.frownHeadDownL4Fork,
                      HonestyPhrases.frownHeadDownL4NeedsEyes, HonestyPhrases.frownHeadDownL5(minutes: 22, friction: true),
                      HonestyPhrases.frownHeadDownL5Early, HonestyPhrases.frownHeadDownL5Fork,
                      HonestyPhrases.frownHeadDownRuledOut, HonestyPhrases.frownHeadDownRuledOutReason,
                      mode.title,
                      HonestyPhrases.frownHeadDown(lean: .effort, evidence: [.au4, .headPitch], confidence: 0.3)]
        for copy in f4Copy {
            assert(!HonestyPhrases.containsBanned(copy), "EmotionSelfTests: F4 copy contains a banned substring: \(copy)")
        }
    }

    // MARK: - US-D14b — F6 Corroborated Positivity fusion construct

    /// US-D14b — the `F6CorroboratedPositivityMode` rule on synthetic readings: (a) a positive
    /// face + a recent laughter event ⇒ "echoed" after the dwell; (b) a positive face WITHOUT
    /// laughter ⇒ quiescent (score 0, never latches — a null, and the ladder shows "not echoed"
    /// only as a FORK); (c) laughter with a non-positive face ⇒ nil (nothing to corroborate);
    /// (d) head-motion / gesture enhancers ELEVATE the echo; (e) the ladder; (f) the honesty
    /// sweep (never "genuine"/"fake"). Synthetic `ChannelReading`s only — no camera, no Vision.
    private static func f6Corroborated() {
        let mode = F6CorroboratedPositivityMode()
        let t = Date(timeIntervalSinceReferenceDate: 1_200_000)

        assert(mode.requires == [.face, .voice], "EmotionSelfTests: F6 requires face + voice")
        assert(!mode.rationale.isEmpty && !mode.confound.isEmpty,
               "EmotionSelfTests: F6 must explain itself and name its confound")
        assert(mode.hysteresis.enter > mode.hysteresis.exit, "EmotionSelfTests: F6 hysteresis must be a real band")
        assert(mode.confidenceCeiling <= 0.6 + 1e-9, "EmotionSelfTests: F6 ceiling ≤ 0.6")

        func faceR(valence: Double, conf: Double = 0.8) -> ChannelReading {
            ChannelReading(channel: .face, date: t, availability: .live, quality: conf,
                           valence: Meter(value: valence, confidence: conf),
                           arousal: Meter(value: 0, confidence: conf), intensity: 0.4,
                           features: [:], posterior: nil)
        }
        func voiceR(laughter: Double, conf: Double = 0.5) -> ChannelReading {
            ChannelReading(channel: .voice, date: t, availability: .live, quality: conf,
                           valence: nil, arousal: Meter(value: 0.3, confidence: conf), intensity: 0.3,
                           features: [.recentLaughter: laughter], posterior: nil)
        }
        func headR(motion: Double) -> ChannelReading {
            ChannelReading(channel: .head, date: t, availability: .live, quality: 0.5,
                           valence: nil, arousal: Meter(value: motion, confidence: 0.4), intensity: motion,
                           features: [.headMotionEnergy: motion], posterior: nil)
        }

        let posFace = faceR(valence: 0.6)
        let laugh = voiceR(laughter: 1.0)
        let noLaugh = voiceR(laughter: 0.0)

        // (a) positive face + recent laughter ⇒ activates after the dwell.
        do {
            var latch = mode.hysteresis
            var activated = false
            for _ in 0..<(mode.hysteresis.enterDwellTicks + 2) {
                guard let out = mode.fuse([.face: posFace, .voice: laugh]) else {
                    assertionFailure("EmotionSelfTests: F6 must fuse with a positive face + voice"); break
                }
                assert(out.score > mode.hysteresis.enter,
                       "EmotionSelfTests: positive face + laughter must clear the enter threshold, got \(out.score)")
                assert(out.confidence <= mode.confidenceCeiling + 1e-9, "EmotionSelfTests: F6 confidence must respect the ceiling")
                assert(out.evidence.contains(.valence) && out.evidence.contains(.recentLaughter),
                       "EmotionSelfTests: F6 evidence must cite the positive face + the recent laughter")
                if latch.update(score: out.score) { activated = true }
            }
            assert(activated, "EmotionSelfTests: sustained positive-face + laughter must activate F6 after the dwell")
        }

        // (b) positive face WITHOUT laughter ⇒ score 0 (a NULL, not "not echoed"); never latches.
        do {
            var latch = mode.hysteresis
            var everActive = false
            for _ in 0..<(mode.hysteresis.enterDwellTicks + 20) {
                guard let out = mode.fuse([.face: posFace, .voice: noLaugh]) else {
                    assertionFailure("EmotionSelfTests: F6 must still fuse a positive face (score 0)"); break
                }
                assert(out.score == 0, "EmotionSelfTests: a positive face with no laughter must score 0 (null, not a verdict)")
                if latch.update(score: out.score) { everActive = true }
            }
            assert(!everActive, "EmotionSelfTests: a positive face WITHOUT laughter must NEVER latch F6 (quiescent null)")
            // "not echoed" appears ONLY as the ladder's ambiguous FORK, never a fired state.
            let ladder = F6CorroboratedPositivityMode.ladder(output: mode.fuse([.face: posFace, .voice: noLaugh]), isActive: false)
            guard case .ambiguous = ladder[1].status else {   // L1 = laughter within window
                assertionFailure("EmotionSelfTests: F6 L1 must be an ambiguous fork with no laughter"); return
            }
            guard case .ambiguous = ladder[3].status else {   // verdict
                assertionFailure("EmotionSelfTests: F6 verdict must be an ambiguous fork when un-corroborated"); return
            }
        }

        // (c) laughter with a NON-positive face ⇒ nil (nothing to corroborate — quiescent).
        assert(mode.fuse([.face: faceR(valence: 0.0), .voice: laugh]) == nil,
               "EmotionSelfTests: laughter with a near-neutral face must yield NO F6 output (nothing to corroborate)")
        assert(mode.fuse([.face: faceR(valence: -0.5), .voice: laugh]) == nil,
               "EmotionSelfTests: laughter with a negative face must yield NO F6 output")

        // (d) enhancers: head-motion ELEVATES the echo above the face×laughter base.
        do {
            let weakPos = faceR(valence: 0.3)          // a partial base so the boost is visible
            let halfLaugh = voiceR(laughter: 0.5)
            let base = mode.fuse([.face: weakPos, .voice: halfLaugh])!.score
            let boosted = mode.fuse([.face: weakPos, .voice: halfLaugh, .head: headR(motion: 1.0)])!
            assert(boosted.score > base, "EmotionSelfTests: a head-motion echo must ELEVATE the F6 score (\(boosted.score) vs \(base))")
            assert((boosted.contributions[.head] ?? 0) > 0 && boosted.evidence.contains(.headMotionEnergy),
                   "EmotionSelfTests: the head-motion enhancer must register a contribution + evidence")
        }

        // (e) ladder shape: nil ⇒ empty; a real ladder has 4 unique rungs.
        assert(F6CorroboratedPositivityMode.ladder(output: nil, isActive: false).isEmpty,
               "EmotionSelfTests: a nil F6 output must yield no ladder")
        let echoedLadder = F6CorroboratedPositivityMode.ladder(output: mode.fuse([.face: posFace, .voice: laugh]), isActive: true)
        assert(echoedLadder.count == 4, "EmotionSelfTests: the F6 ladder has 4 rungs, got \(echoedLadder.count)")
        assert(Set(echoedLadder.map(\.id)).count == echoedLadder.count, "EmotionSelfTests: F6 ladder rung ids must be unique")
        assert(echoedLadder[0].status == .resolved && echoedLadder[1].status == .resolved && echoedLadder[3].status == .resolved,
               "EmotionSelfTests: a corroborated F6 ladder must resolve L0/L1/verdict")

        // (f) honesty sweep — every new F6 string + the narration; NEVER "genuine"/"fake".
        let f6Copy = [
            HonestyPhrases.corroboratedPositivityEchoedState, HonestyPhrases.corroboratedPositivityRationale,
            HonestyPhrases.corroboratedPositivityConfound,
            HonestyPhrases.corroboratedPositivityL0, HonestyPhrases.corroboratedPositivityL0Fork,
            HonestyPhrases.corroboratedPositivityL1, HonestyPhrases.corroboratedPositivityL1Fork,
            HonestyPhrases.corroboratedPositivityL2, HonestyPhrases.corroboratedPositivityL2Fork,
            HonestyPhrases.corroboratedPositivityVerdict, HonestyPhrases.corroboratedPositivityVerdictNotEchoed,
            HonestyPhrases.corroboratedPositivityVerdictFork, mode.title,
            HonestyPhrases.corroboratedPositivity(evidence: [.valence, .recentLaughter, .headMotionEnergy], confidence: 0.4)
        ]
        for c in f6Copy {
            assert(!HonestyPhrases.containsBanned(c), "EmotionSelfTests: F6 copy contains a banned substring: \(c)")
        }
        let f6Text = HonestyPhrases.corroboratedPositivity(evidence: [.valence, .recentLaughter], confidence: 0.4)
        assert(f6Text.localizedCaseInsensitiveContains("persona") && f6Text.localizedCaseInsensitiveContains("recent laughter"),
               "EmotionSelfTests: F6 narration must keep the Persona framing + cite the laughter: \(f6Text)")
        assert(HonestyPhrases.confidenceWords.contains { f6Text.localizedCaseInsensitiveContains($0) },
               "EmotionSelfTests: F6 narration must state a confidence word: \(f6Text)")
    }

    // MARK: - US-D14b — F10 Approach ⇄ Withdrawal fusion construct (the coupled tie-break axis)

    /// US-D14b — the `F10ApproachWithdrawalMode` coupled construct: (a) high motor + level head
    /// ⇒ the APPROACH pole; (b) low motor + head down-and-away ⇒ the WITHDRAWAL pole; (c) the
    /// §4.3 negative-face tie-break NARRATION chooser (pure) selects the displeasure /
    /// dejection lean; (d) dead-band alternation never latches; (e) the ladder; (f) the honesty
    /// sweep (leans, never a discrete label). Synthetic readings only — no camera, no Vision.
    private static func f10ApproachWithdrawal() {
        let mode = F10ApproachWithdrawalMode()
        let t = Date(timeIntervalSinceReferenceDate: 1_300_000)

        assert(mode.requires == [.head], "EmotionSelfTests: F10 requires the head lens (hands enhance)")
        assert(!mode.rationale.isEmpty && !mode.confound.isEmpty,
               "EmotionSelfTests: F10 must explain itself and name its confound")
        assert(mode.confidenceCeiling <= 0.6 + 1e-9, "EmotionSelfTests: F10 ceiling ≤ 0.6")
        assert(F10ApproachWithdrawalMode.poleExitDwell < F10ApproachWithdrawalMode.poleEnterDwell,
               "EmotionSelfTests: F10's exit dwell must be shorter than its enter dwell (the dead band)")

        func headR(motor: Double, lean: Double, conf: Double = 0.4) -> ChannelReading {
            ChannelReading(channel: .head, date: t, availability: .live, quality: conf,
                           valence: nil, arousal: Meter(value: motor, confidence: conf), intensity: motor,
                           features: [.dominanceLean: lean, .headMotionEnergy: motor], posterior: nil)
        }

        // (a) high motor + level head ⇒ the APPROACH (positive) pole latches.
        do {
            var latch = mode.coupledLatch
            var pole: Pole = .neutral
            for _ in 0..<(F10ApproachWithdrawalMode.poleEnterDwell + 4) {
                let out = mode.fuse([.head: headR(motor: 1.0, lean: 0.0)])!
                assert((out.axis ?? 0) > 0, "EmotionSelfTests: high motor + level head must read approach (+), got \(out.axis ?? 0)")
                pole = latch.update(axis: out.axis ?? 0)
            }
            assert(pole == .positive, "EmotionSelfTests: sustained high-motor + level head must latch the approach pole, got \(pole)")
        }

        // (b) low motor + head down-and-away ⇒ the WITHDRAWAL (negative) pole latches.
        do {
            var latch = mode.coupledLatch
            var pole: Pole = .neutral
            for _ in 0..<(F10ApproachWithdrawalMode.poleEnterDwell + 4) {
                let out = mode.fuse([.head: headR(motor: 0.0, lean: -1.0)])!
                assert((out.axis ?? 0) < 0, "EmotionSelfTests: low motor + down-away must read withdrawal (−), got \(out.axis ?? 0)")
                pole = latch.update(axis: out.axis ?? 0)
            }
            assert(pole == .negative, "EmotionSelfTests: sustained low-motor + down-away must latch the withdrawal pole, got \(pole)")
        }

        // (c) the §4.3 CONTEXT-SENSITIVE tie-break narration chooser (pure). A NEGATIVE face
        //     adds the displeasure / dejection LEAN; a non-negative face gets direction only.
        let negApproach = HonestyPhrases.approachWithdrawal(approach: true, faceNegative: true, evidence: [.headMotionEnergy], confidence: 0.3)
        assert(negApproach.localizedCaseInsensitiveContains("displeasure"),
               "EmotionSelfTests: a negative face + approach must lean displeasure: \(negApproach)")
        let negWithdrawal = HonestyPhrases.approachWithdrawal(approach: false, faceNegative: true, evidence: [.headMotionEnergy], confidence: 0.3)
        assert(negWithdrawal.localizedCaseInsensitiveContains("dejection"),
               "EmotionSelfTests: a negative face + withdrawal must lean dejection: \(negWithdrawal)")
        let neutralApproach = HonestyPhrases.approachWithdrawal(approach: true, faceNegative: false, evidence: [.headMotionEnergy], confidence: 0.3)
        assert(neutralApproach.localizedCaseInsensitiveContains("approach")
               && !neutralApproach.localizedCaseInsensitiveContains("displeasure"),
               "EmotionSelfTests: a non-negative face must narrate direction only, no displeasure lean: \(neutralApproach)")
        for text in [negApproach, negWithdrawal, neutralApproach] {
            assert(!HonestyPhrases.containsBanned(text), "EmotionSelfTests: F10 narration banned: \(text)")
            assert(!text.localizedCaseInsensitiveContains("angry"), "EmotionSelfTests: F10 narration must never say 'angry': \(text)")
            assert(text.localizedCaseInsensitiveContains("persona"), "EmotionSelfTests: F10 narration must keep the Persona framing")
        }

        // (d) dead-band alternation (tiny ±direction) ⇒ neither pole ever latches.
        do {
            var latch = mode.coupledLatch
            var everActive = false
            for i in 0..<80 {
                let motor = (i % 2 == 0) ? 0.55 : 0.45   // ±0.1 around still ⇒ |axis| ≈ 0.035 < poleEnter
                let out = mode.fuse([.head: headR(motor: motor, lean: 0.0)])!
                if latch.update(axis: out.axis ?? 0) != .neutral { everActive = true }
            }
            assert(!everActive, "EmotionSelfTests: dead-band alternation must never latch an F10 pole")
        }

        // (e) ladder: a leaning output resolves L0 + the pole verdict; a near-neutral one forks; nil ⇒ empty.
        assert(F10ApproachWithdrawalMode.ladder(output: nil, isActive: false).isEmpty,
               "EmotionSelfTests: a nil F10 output must yield no ladder")
        let leanOut = mode.fuse([.head: headR(motor: 1.0, lean: 0.0)])!
        let leanLadder = F10ApproachWithdrawalMode.ladder(output: leanOut, isActive: true)
        assert(leanLadder.count == 2 && leanLadder[0].status == .resolved && leanLadder[1].status == .resolved,
               "EmotionSelfTests: an active F10 ladder must resolve L0 + the pole verdict")
        assert(Set(leanLadder.map(\.id)).count == leanLadder.count, "EmotionSelfTests: F10 ladder rung ids must be unique")

        // (f) honesty sweep — every new F10 string + both pole labels.
        let f10Copy = [
            HonestyPhrases.approachWithdrawalRationale, HonestyPhrases.approachWithdrawalConfound,
            HonestyPhrases.approachWithdrawalApproachState, HonestyPhrases.approachWithdrawalWithdrawalState,
            HonestyPhrases.approachWithdrawalL0, HonestyPhrases.approachWithdrawalL0Fork,
            HonestyPhrases.approachWithdrawalVerdictNeutral, HonestyPhrases.approachWithdrawalVerdictNeutralFork,
            mode.title, mode.poleName(forSign: 1) ?? "", mode.poleName(forSign: -1) ?? ""
        ]
        for c in f10Copy {
            assert(!HonestyPhrases.containsBanned(c), "EmotionSelfTests: F10 copy contains a banned substring: \(c)")
        }
    }

    // MARK: - US-D14b — F8 Dominance display fusion construct (the coupled posture axis)

    /// US-D14b — the `F8DominanceMode` coupled construct: (a) sustained expansion lean ⇒ the
    /// EXPANSION pole; (b) alternation ⇒ neutral (dead band); (c) DISPLAY-language pole labels;
    /// (d) the ladder; (e) the honesty sweep (display language, never a felt emotion). Synthetic
    /// readings only — no camera, no Vision.
    private static func f8Dominance() {
        let mode = F8DominanceMode()
        let t = Date(timeIntervalSinceReferenceDate: 1_400_000)

        assert(mode.requires == [.head], "EmotionSelfTests: F8 requires the head lens (hands enhance)")
        assert(!mode.rationale.isEmpty && !mode.confound.isEmpty,
               "EmotionSelfTests: F8 must explain itself and name its confound")
        assert(mode.confidenceCeiling <= 0.5 + 1e-9, "EmotionSelfTests: F8 ceiling ≤ 0.5 (a display, not a felt state)")
        assert(F8DominanceMode.poleExitDwell < F8DominanceMode.poleEnterDwell,
               "EmotionSelfTests: F8's exit dwell must be shorter than its enter dwell (the dead band)")

        func headR(lean: Double, quality: Double = 0.8) -> ChannelReading {
            ChannelReading(channel: .head, date: t, availability: .live, quality: quality,
                           valence: nil, arousal: Meter(value: 0.1, confidence: quality), intensity: 0.1,
                           features: [.dominanceLean: lean, .headPitch: lean * 0.35, .headYaw: 0], posterior: nil)
        }

        // (a) sustained expansion lean ⇒ the EXPANSION (positive) pole latches.
        do {
            var latch = mode.coupledLatch
            var pole: Pole = .neutral
            for _ in 0..<(F8DominanceMode.poleEnterDwell + 4) {
                let out = mode.fuse([.head: headR(lean: 0.6)])!
                assert(out.confidence <= mode.confidenceCeiling + 1e-9, "EmotionSelfTests: F8 confidence must respect the ≤0.5 ceiling")
                pole = latch.update(axis: out.axis ?? 0)
            }
            assert(pole == .positive, "EmotionSelfTests: a sustained expansion lean must latch the expansion pole, got \(pole)")
        }

        // (b) alternation (±0.5) ⇒ neither pole ever latches (the dead band).
        do {
            var latch = mode.coupledLatch
            var everActive = false
            for i in 0..<120 {
                let lean = (i % 2 == 0) ? 0.5 : -0.5
                let out = mode.fuse([.head: headR(lean: lean)])!
                if latch.update(axis: out.axis ?? 0) != .neutral { everActive = true }
            }
            assert(!everActive, "EmotionSelfTests: an alternating dominance lean must never latch an F8 pole (dead band)")
        }

        // (c) DISPLAY-language pole labels (never a felt emotion).
        assert(mode.poleName(forSign: 1) == HonestyPhrases.dominanceExpansionState,
               "EmotionSelfTests: F8 + pole must be the expansion display")
        assert(mode.poleName(forSign: -1) == HonestyPhrases.dominanceContractionState,
               "EmotionSelfTests: F8 − pole must be the contraction display")
        assert(mode.poleName(forSign: 0) == nil, "EmotionSelfTests: F8 neutral has no pole label")

        // (d) ladder: an expansion output resolves L0 + the display verdict; nil ⇒ empty.
        assert(F8DominanceMode.ladder(output: nil, isActive: false).isEmpty, "EmotionSelfTests: a nil F8 output must yield no ladder")
        let expOut = mode.fuse([.head: headR(lean: 0.6)])!
        let expLadder = F8DominanceMode.ladder(output: expOut, isActive: true)
        assert(expLadder.count == 2 && expLadder[0].status == .resolved && expLadder[1].claim == HonestyPhrases.dominanceExpansionState,
               "EmotionSelfTests: an active F8 ladder must resolve L0 + the expansion-display verdict")

        // (e) honesty sweep.
        let f8Copy = [
            HonestyPhrases.dominanceRationale, HonestyPhrases.dominanceConfound,
            HonestyPhrases.dominanceExpansionState, HonestyPhrases.dominanceContractionState,
            HonestyPhrases.dominanceL0, HonestyPhrases.dominanceL0Fork,
            HonestyPhrases.dominanceVerdictNeutral, HonestyPhrases.dominanceVerdictNeutralFork, mode.title,
            HonestyPhrases.dominance(expansion: true, evidence: [.headPitch, .headYaw], confidence: 0.3),
            HonestyPhrases.dominance(expansion: false, evidence: [.headPitch, .headYaw], confidence: 0.3)
        ]
        for c in f8Copy {
            assert(!HonestyPhrases.containsBanned(c), "EmotionSelfTests: F8 copy contains a banned substring: \(c)")
        }
        let f8Text = HonestyPhrases.dominance(expansion: true, evidence: [.headPitch], confidence: 0.3)
        assert(f8Text.localizedCaseInsensitiveContains("persona") && f8Text.localizedCaseInsensitiveContains("head pitch"),
               "EmotionSelfTests: F8 narration must keep the Persona framing + cite a head signal: \(f8Text)")
    }

    // MARK: - US-D14b — F9 Expansive display fusion construct (the conservative pride-adjacent display)

    /// US-D14b — the `F9ExpansiveDisplayMode` rule: (a) F8-grade expansion does NOT fire F9
    /// (the HIGHER bar, asserted numerically vs F8); (b) strong expansion + a non-negative face
    /// ⇒ fires after the dwell; (c) a negative face gates it OFF (the conjunction); (d) the
    /// ladder ends on the power-pose refusal; (e) the honesty sweep ("pride" only a gloss, NO
    /// power-pose causal claim). Synthetic readings only — no camera, no Vision.
    private static func f9Expansive() {
        let mode = F9ExpansiveDisplayMode()
        let t = Date(timeIntervalSinceReferenceDate: 1_500_000)

        assert(mode.requires == [.face, .head], "EmotionSelfTests: F9 requires face + head")
        assert(!mode.rationale.isEmpty && !mode.confound.isEmpty,
               "EmotionSelfTests: F9 must explain itself and name its confound")
        assert(mode.confidenceCeiling <= 0.5 + 1e-9, "EmotionSelfTests: F9 ceiling ≤ 0.5")
        assert(mode.hysteresis.enter > mode.hysteresis.exit, "EmotionSelfTests: F9 hysteresis must be a real band")

        func faceR(valence: Double, conf: Double = 0.8) -> ChannelReading {
            ChannelReading(channel: .face, date: t, availability: .live, quality: conf,
                           valence: Meter(value: valence, confidence: conf),
                           arousal: Meter(value: 0, confidence: conf), intensity: 0.3, features: [:], posterior: nil)
        }
        func headR(lean: Double, quality: Double = 0.8) -> ChannelReading {
            ChannelReading(channel: .head, date: t, availability: .live, quality: quality,
                           valence: nil, arousal: Meter(value: 0.1, confidence: quality), intensity: 0.1,
                           features: [.dominanceLean: lean, .headPitch: lean * 0.35], posterior: nil)
        }

        // (a) the HIGHER bar: F9's enter threshold sits ABOVE F8's poleEnter (asserted
        //     numerically), and an F8-GRADE lean (0.5) never fires F9.
        assert(F9ExpansiveDisplayMode.expansionEnter > F8DominanceMode.poleEnter,
               "EmotionSelfTests: F9's bar (\(F9ExpansiveDisplayMode.expansionEnter)) must exceed F8's poleEnter (\(F8DominanceMode.poleEnter))")
        do {
            var latch = mode.hysteresis
            var everActive = false
            for _ in 0..<(mode.hysteresis.enterDwellTicks + 20) {
                let out = mode.fuse([.face: faceR(valence: 0.2), .head: headR(lean: 0.5)])!
                if latch.update(score: out.score) { everActive = true }
            }
            assert(!everActive, "EmotionSelfTests: an F8-grade (0.5) expansion must NEVER fire F9 (the higher bar)")
        }

        // (b) STRONG expansion + a non-negative face ⇒ fires after the dwell.
        do {
            var latch = mode.hysteresis
            var activated = false
            for _ in 0..<(mode.hysteresis.enterDwellTicks + 4) {
                guard let out = mode.fuse([.face: faceR(valence: 0.2), .head: headR(lean: 0.8)]) else {
                    assertionFailure("EmotionSelfTests: F9 must fuse with face + head"); break
                }
                assert(out.namedState == HonestyPhrases.expansiveDisplayState, "EmotionSelfTests: F9 must surface the head-only display state")
                assert(out.confidence <= mode.confidenceCeiling + 1e-9, "EmotionSelfTests: F9 confidence must respect the ≤0.5 ceiling")
                if latch.update(score: out.score) { activated = true }
            }
            assert(activated, "EmotionSelfTests: strong expansion + a non-negative face must fire F9 after the dwell")
        }

        // (c) a clearly NEGATIVE face gates F9 OFF (the conjunction — score 0), even at strong expansion.
        do {
            var latch = mode.hysteresis
            var everActive = false
            for _ in 0..<(mode.hysteresis.enterDwellTicks + 20) {
                let out = mode.fuse([.face: faceR(valence: -0.6), .head: headR(lean: 0.8)])!
                assert(out.score == 0, "EmotionSelfTests: a negative face must gate the F9 score to 0 (conjunction)")
                if latch.update(score: out.score) { everActive = true }
            }
            assert(!everActive, "EmotionSelfTests: a negative face must NEVER fire F9")
        }

        // (d) ladder ends on the PERMANENT power-pose refusal; nil ⇒ empty.
        assert(F9ExpansiveDisplayMode.ladder(output: nil, isActive: false).isEmpty, "EmotionSelfTests: a nil F9 output must yield no ladder")
        let fired = mode.fuse([.face: faceR(valence: 0.2), .head: headR(lean: 0.8)])!
        let ladder = F9ExpansiveDisplayMode.ladder(output: fired, isActive: true)
        assert(Set(ladder.map(\.id)).count == ladder.count, "EmotionSelfTests: F9 ladder rung ids must be unique")
        guard let refusal = ladder.last, case .ruledOut(let reason) = refusal.status else {
            assertionFailure("EmotionSelfTests: the last F9 rung must be the ruledOut power-pose refusal"); return
        }
        assert(!HonestyPhrases.containsBanned(refusal.claim) && !HonestyPhrases.containsBanned(reason),
               "EmotionSelfTests: the F9 refusal rung must be banned-clean")

        // (e) honesty sweep. "pride" is ONLY a hedged gloss (rationale), NEVER in the state.
        let f9Copy = [
            HonestyPhrases.expansiveDisplayState, HonestyPhrases.expansiveDisplayRationale,
            HonestyPhrases.expansiveDisplayConfound, HonestyPhrases.expansiveDisplayL0, HonestyPhrases.expansiveDisplayL0Fork,
            HonestyPhrases.expansiveDisplayL1, HonestyPhrases.expansiveDisplayL1Fork,
            HonestyPhrases.expansiveDisplayVerdict, HonestyPhrases.expansiveDisplayVerdictNotYet,
            HonestyPhrases.expansiveDisplayVerdictNotYetFork, HonestyPhrases.expansiveDisplayRuledOut,
            HonestyPhrases.expansiveDisplayRuledOutReason, mode.title,
            HonestyPhrases.expansiveDisplay(evidence: [.headPitch, .valence], confidence: 0.3)
        ]
        for c in f9Copy {
            assert(!HonestyPhrases.containsBanned(c), "EmotionSelfTests: F9 copy contains a banned substring: \(c)")
        }
        assert(!HonestyPhrases.expansiveDisplayState.localizedCaseInsensitiveContains("pride"),
               "EmotionSelfTests: F9's surfaced state must NOT say 'pride' (a felt emotion) — only the rationale glosses it")
        assert(HonestyPhrases.expansiveDisplayRationale.localizedCaseInsensitiveContains("pride"),
               "EmotionSelfTests: F9's rationale must gloss 'pride' as a hedged term")
        assert(HonestyPhrases.expansiveDisplayRuledOut.localizedCaseInsensitiveContains("power-pose"),
               "EmotionSelfTests: F9 must ship the power-pose refusal rung (§4.5 #7)")
    }

    // MARK: - US-D14b — F5 Corroborated arousal fusion construct (the calm-face-free F1 sibling)

    /// US-D14b — the `F5CovertArousalMode` rule: (a) TWO elevated non-face proxies ⇒ fires
    /// after the dwell, AND fires with an EXPRESSIVE face too (calm-face NOT required — the F1
    /// distinction); (b) ONE elevated proxy ⇒ NEVER fires (the ≥2 guard); (c) the ladder shows
    /// "needs a second arousal channel" with one proxy; (d) the honesty sweep (never "covert"/
    /// "concealment" in user copy). Synthetic readings only — no camera, no Vision.
    private static func f5CovertArousal() {
        let mode = F5CovertArousalMode()
        let t = Date(timeIntervalSinceReferenceDate: 1_600_000)

        assert(mode.requires == [.eyes], "EmotionSelfTests: F5 requires the eyes lens (the ≥2 guard is in-fuse)")
        assert(!mode.rationale.isEmpty && !mode.confound.isEmpty,
               "EmotionSelfTests: F5 must explain itself and name its confound")
        assert(mode.confidenceCeiling <= 0.6 + 1e-9, "EmotionSelfTests: F5 ceiling ≤ 0.6")
        assert(mode.hysteresis.enter > mode.hysteresis.exit, "EmotionSelfTests: F5 hysteresis must be a real band")

        func eyesR(blinkDelta: Double, conf: Double = 0.3) -> ChannelReading {
            ChannelReading(channel: .eyes, date: t, availability: .live, quality: conf,
                           valence: nil, arousal: Meter(value: min(1, abs(blinkDelta) / 12), confidence: conf),
                           intensity: 0, features: [.blinkRate: blinkDelta], posterior: nil)
        }
        func handsR(gestureEnergy: Double, conf: Double = 0.4) -> ChannelReading {
            ChannelReading(channel: .hands, date: t, availability: .live, quality: conf,
                           valence: nil, arousal: Meter(value: max(0, gestureEnergy / 0.5), confidence: conf),
                           intensity: 0, features: [.gestureEnergy: gestureEnergy], posterior: nil)
        }
        // An EXPRESSIVE face — F5 must fire regardless (it never reads the face; the F1 distinction).
        let expressiveFace = ChannelReading(channel: .face, date: t, availability: .live, quality: 0.8,
                                            valence: Meter(value: -0.7, confidence: 0.8),
                                            arousal: Meter(value: 0.6, confidence: 0.8), intensity: 0.6,
                                            features: [:], posterior: nil)

        // (a) TWO elevated proxies (eyes blink↑ + hand energy↑) ⇒ fires — even with an expressive face.
        do {
            var latch = mode.hysteresis
            var activated = false
            let readings: [Channel: ChannelReading] = [
                .eyes: eyesR(blinkDelta: 10), .hands: handsR(gestureEnergy: 0.4), .face: expressiveFace]
            for _ in 0..<(mode.hysteresis.enterDwellTicks + 2) {
                guard let out = mode.fuse(readings) else {
                    assertionFailure("EmotionSelfTests: F5 must fuse with the eyes lens live"); break
                }
                assert(out.score > mode.hysteresis.enter,
                       "EmotionSelfTests: two elevated proxies must clear the enter threshold, got \(out.score)")
                assert(out.confidence <= mode.confidenceCeiling + 1e-9, "EmotionSelfTests: F5 confidence must respect the ceiling")
                assert(out.contributions.count >= 2 && out.evidence.contains(.blinkRate) && out.evidence.contains(.gestureEnergy),
                       "EmotionSelfTests: F5 must name ≥2 contributing channels + cite both proxies")
                if latch.update(score: out.score) { activated = true }
            }
            assert(activated, "EmotionSelfTests: two sustained elevated proxies must fire F5 — expressive face and all (the F1 distinction)")
        }

        // (b) ONE elevated proxy (eyes alone) ⇒ score 0, NEVER fires (the ≥2 guard).
        do {
            var latch = mode.hysteresis
            var everActive = false
            for _ in 0..<(mode.hysteresis.enterDwellTicks + 20) {
                guard let out = mode.fuse([.eyes: eyesR(blinkDelta: 10)]) else {
                    assertionFailure("EmotionSelfTests: F5 must still fuse a single elevated proxy (score 0)"); break
                }
                assert(out.score == 0, "EmotionSelfTests: a single elevated proxy must score 0 (the ≥2 guard)")
                if latch.update(score: out.score) { everActive = true }
            }
            assert(!everActive, "EmotionSelfTests: a single elevated proxy must NEVER fire F5")
        }

        // (c) ladder: with one proxy, L0 shows the "needs a second arousal channel" fork; a
        //     two-proxy active state resolves; nil (eyes dark) ⇒ empty.
        let oneLadder = F5CovertArousalMode.ladder(output: mode.fuse([.eyes: eyesR(blinkDelta: 10)]), isActive: false)
        guard case .ambiguous(let fork) = oneLadder[0].status else {
            assertionFailure("EmotionSelfTests: F5 L0 must fork with a single proxy"); return
        }
        assert(fork == HonestyPhrases.covertArousalNeedsSecond, "EmotionSelfTests: the F5 L0 fork must be the 'needs a second arousal channel' copy")
        let darkEyes = ChannelReading(channel: .eyes, date: t, availability: .unavailable, quality: 0,
                                      valence: nil, arousal: nil, intensity: 0, features: [:], posterior: nil)
        assert(mode.fuse([.eyes: darkEyes]) == nil, "EmotionSelfTests: F5 must yield nil when the eyes lens is dark")
        assert(F5CovertArousalMode.ladder(output: nil, isActive: false).isEmpty, "EmotionSelfTests: a nil F5 output must yield no ladder")

        // (d) honesty sweep — the user-facing copy is banned-clean AND never says "covert"/"suppressed".
        let f5Copy = [
            HonestyPhrases.covertArousalRationale, HonestyPhrases.covertArousalConfound,
            HonestyPhrases.covertArousalL0, HonestyPhrases.covertArousalNeedsSecond,
            HonestyPhrases.covertArousalL1, HonestyPhrases.covertArousalL1Fork,
            HonestyPhrases.covertArousalVerdict, mode.title,
            HonestyPhrases.covertArousal(evidence: [.blinkRate, .gestureEnergy], confidence: 0.4)
        ]
        for c in f5Copy {
            assert(!HonestyPhrases.containsBanned(c), "EmotionSelfTests: F5 copy contains a banned substring: \(c)")
            assert(!c.localizedCaseInsensitiveContains("covert") && !c.localizedCaseInsensitiveContains("suppressed"),
                   "EmotionSelfTests: F5 user-facing copy must never say 'covert'/'suppressed' (the internal name only): \(c)")
        }
    }

    // MARK: - US-D14b — the comprehensive registry honesty lint (structural, all + future modes)

    /// US-D14b — `registryHonestyLint`: iterate EVERY registered mode in a freshly-constructed
    /// registry (the app's own set, so FUTURE modes are covered automatically) and (i) assert
    /// the PRD's own AC — non-empty `requires` + non-empty `rationale` — and (ii) sweep the
    /// title + rationale + confound + citation + every coupled pole name + every reachable
    /// ladder claim / fork / ruled-out reason through the banlist. This makes "no view can
    /// overclaim" STRUCTURAL: a new mode shipped with dirty copy traps at launch.
    private static func registryHonestyLint() {
        let modes = AffectHub().fusionRegistry.modes
        assert(modes.count >= 10, "EmotionSelfTests: expected all fusion constructs registered, got \(modes.count)")
        for id in [ConstructID.corroboratedPositivity, ConstructID.approachWithdrawal, ConstructID.dominance,
                   ConstructID.expansiveDisplay, ConstructID.covertArousal] {
            assert(modes.contains { $0.id == id }, "EmotionSelfTests: construct '\(id)' must be registered")
        }

        // Rich (positive-axis), rich-negative-axis, and poor synthetic states exercise resolved
        // rungs, ambiguous forks, ruled-out reasons, and BOTH pole verdicts across every ladder.
        let richEvidence: [SignalRef] = [.valence, .arousal, .blinkRate, .prolongedClosure, .eyeOpenVariance,
                                         .headPitch, .headYaw, .headMotionEnergy, .recentLaughter, .gestureRate,
                                         .gestureEnergy, .selfTouchRate, .cancelRate, .inputTempo,
                                         .au1, .au4, .au5, .au7, .au15, .sessionMinutes]
        let richContrib: [Channel: Double] = [.face: 0.9, .eyes: 0.9, .hands: 0.9, .head: 0.9,
                                              .voice: 0.9, .interaction: 0.9, .context: 30]
        func rich(axis: Double) -> FusionOutput {
            FusionOutput(namedState: "x", contributions: richContrib, confidence: 0.4, score: 0.8,
                         evidence: richEvidence, separabilityLimited: true, axis: axis)
        }
        let poor = FusionOutput(contributions: [:], confidence: 0.1, score: 0.05, evidence: [], axis: -0.05)

        func sweep(_ s: String, _ mode: any FusionMode) {
            assert(!HonestyPhrases.containsBanned(s),
                   "EmotionSelfTests: registry honesty lint — mode '\(mode.id)' surfaces banned copy: \(s)")
        }
        func sweepLadder(_ steps: [LadderStep], _ mode: any FusionMode) {
            for step in steps {
                sweep(step.claim, mode)
                switch step.status {
                case .resolved: break
                case .ambiguous(let fork): sweep(fork, mode)
                case .ruledOut(let reason): sweep(reason, mode)
                }
            }
        }

        var seen = Set<String>()
        for mode in modes {
            // The PRD's honesty AC (mirrors FusionRegistry.register's asserts, as a runtime guard).
            assert(!mode.requires.isEmpty, "EmotionSelfTests: mode '\(mode.id)' must declare required channels")
            assert(!mode.rationale.isEmpty, "EmotionSelfTests: mode '\(mode.id)' must carry a non-empty rationale")
            assert((0...1).contains(mode.confidenceCeiling), "EmotionSelfTests: mode '\(mode.id)' ceiling out of 0…1")
            assert(seen.insert(mode.id).inserted, "EmotionSelfTests: duplicate fusion mode id '\(mode.id)'")

            // Static surfaced copy.
            sweep(mode.title, mode)
            sweep(mode.rationale, mode)
            sweep(mode.confound, mode)
            if let c = mode.citation { sweep(c, mode) }

            // Coupled pole labels (the surfaced bipolar states).
            if let coupled = mode as? any CoupledFusionMode {
                if let n = coupled.poleName(forSign: 1) { sweep(n, mode) }
                if let n = coupled.poleName(forSign: -1) { sweep(n, mode) }
            }

            // Every reachable ladder claim / fork / reason across rich±axis × active/inactive + poor.
            for state in [FusionModeState(output: rich(axis: 0.8), isActive: true, availability: .available),
                          FusionModeState(output: rich(axis: -0.8), isActive: true, availability: .available),
                          FusionModeState(output: rich(axis: 0.8), isActive: false, availability: .available),
                          FusionModeState(output: poor, isActive: false, availability: .available)] {
                sweepLadder(mode.ladder(for: state), mode)
            }
        }

        // The lint must actually BITE: the same sweep catches deliberately dirty construct copy.
        assert(HonestyPhrases.containsBanned("this is a genuine smile, not fake"),
               "EmotionSelfTests: the registry honesty lint must catch dirty construct copy")
    }

    private static func ladderModel() {
        func out(calm: Double, proxy: Double, limited: Bool) -> FusionOutput {
            FusionOutput(contributions: [.face: calm, .eyes: proxy],
                         confidence: 0.2, score: 0.5, evidence: [.valence, .blinkRate],
                         separabilityLimited: limited)
        }

        // (a) nil output ⇒ no ladder.
        assert(F1ComposureMode.ladder(output: nil, isActive: false).isEmpty,
               "EmotionSelfTests: a nil output must yield no ladder")

        // (b) fully resolved, not gate-limited, latched active: L0/L1/L2 resolved + the
        //     permanent ruledOut rung last (no tentative rung).
        let resolved = F1ComposureMode.ladder(output: out(calm: 0.9, proxy: 0.8, limited: false), isActive: true)
        assert(resolved.count == 4, "EmotionSelfTests: a resolved non-limited F1 ladder has 4 rungs, got \(resolved.count)")
        assert(resolved[0].status == .resolved, "EmotionSelfTests: L0 must resolve on a calm face")
        assert(resolved[1].status == .resolved, "EmotionSelfTests: L1 must resolve on an elevated proxy")
        assert(resolved[2].status == .resolved, "EmotionSelfTests: L2 must resolve once latched")
        guard let refusal = resolved.last, case .ruledOut(let reason) = refusal.status else {
            assertionFailure("EmotionSelfTests: the last F1 rung must be the ruledOut refusal"); return
        }
        assert(reason == HonestyPhrases.composureLadderRuledOutReason,
               "EmotionSelfTests: the ruledOut rung must carry its refusal reason")
        assert(!HonestyPhrases.containsBanned(refusal.claim) && !HonestyPhrases.containsBanned(reason),
               "EmotionSelfTests: the refusal rung must be banned-clean")

        // (c) not calm / no proxy / not latched ⇒ those rungs are ambiguous forks.
        let unresolved = F1ComposureMode.ladder(output: out(calm: 0.2, proxy: 0.0, limited: false), isActive: false)
        guard case .ambiguous = unresolved[0].status else {
            assertionFailure("EmotionSelfTests: L0 must be ambiguous when not calm"); return
        }
        guard case .ambiguous = unresolved[1].status else {
            assertionFailure("EmotionSelfTests: L1 must be ambiguous with no proxy"); return
        }
        guard case .ambiguous = unresolved[2].status else {
            assertionFailure("EmotionSelfTests: L2 must be ambiguous when not latched"); return
        }

        // (d) the low-expresser gate inserts the tentative (ambiguous) rung.
        let limited = F1ComposureMode.ladder(output: out(calm: 0.9, proxy: 0.8, limited: true), isActive: true)
        assert(limited.count == 5, "EmotionSelfTests: a gate-limited F1 ladder adds the tentative rung (5), got \(limited.count)")
        guard let tentative = limited.first(where: { $0.claim == HonestyPhrases.composureLadderTentative }) else {
            assertionFailure("EmotionSelfTests: the gate-limited ladder must carry the tentative rung"); return
        }
        guard case .ambiguous = tentative.status else {
            assertionFailure("EmotionSelfTests: the tentative rung must be .ambiguous"); return
        }

        // (e) rung ids are unique (ForEach stability).
        assert(Set(limited.map(\.id)).count == limited.count, "EmotionSelfTests: ladder rung ids must be unique")

        // (f) F7 reuses the widget: a 2-rung ladder resolving on activation; nil ⇒ empty.
        let f7 = F7FrustrationMode()
        let f7State = FusionModeState(
            output: FusionOutput(contributions: [.face: 0.6, .interaction: 0.7],
                                 confidence: 0.5, score: 0.6, evidence: [.valence, .cancelRate]),
            isActive: true, availability: .available)
        let f7Ladder = f7.ladder(for: f7State)
        assert(f7Ladder.count == 2, "EmotionSelfTests: F7's minimal ladder has 2 rungs, got \(f7Ladder.count)")
        assert(f7Ladder[1].status == .resolved, "EmotionSelfTests: F7 L1 must resolve once latched")
        assert(f7.ladder(for: FusionModeState(output: nil, isActive: false, availability: .available)).isEmpty,
               "EmotionSelfTests: an F7 ladder with no output must be empty (the clean nil path)")
    }

    // MARK: - US-B7 — BOCPD change-point detection

    /// US-B7 — `ChangePointDetector` (BOCPD). Verified offline (0 false positives
    /// over 40 seeded stationary streams; a 0.8 step fires once at 0–3 samples), so
    /// these seeded assertions are exact with wide margin.
    private static func changePointDetection() {
        let dt = 1.0 / 15.0

        // (a) A stationary seeded-Gaussian stream ⇒ ZERO change-points. Seeded, so
        //     this is exactly 0 (no false-positive budget needed). 280 samples keeps
        //     it under the 300 truncation, so no fold interacts with the assertion.
        var det = ChangePointDetector()
        var rng = SeededGaussian(seed: 0x9E3779B97F4A7C15)
        var t = Date(timeIntervalSince1970: 0)
        var falsePositives = 0
        for _ in 0..<280 {
            t += dt
            if det.observe(0.05 * rng.next(), at: t) { falsePositives += 1 }
        }
        assert(falsePositives == 0,
               "EmotionSelfTests: BOCPD false-positive on a stationary stream (\(falsePositives))")

        // (b) An abrupt mean step (0 → 0.8 at sample 120) ⇒ fires within a bounded
        //     latency, and (c) EXACTLY ONCE (the cooldown suppresses re-firing while
        //     the run re-grows). Measured latency is 0–3 samples; assert ≤ 25 (margin).
        var det2 = ChangePointDetector()
        var rng2 = SeededGaussian(seed: 0xD1B54A32D192ED03)
        var t2 = Date(timeIntervalSince1970: 0)
        let stepAt = 120
        var fireCount = 0
        var latency = -1
        for i in 0..<260 {
            t2 += dt
            let mean = i < stepAt ? 0.0 : 0.8
            if det2.observe(mean + 0.05 * rng2.next(), at: t2) {
                fireCount += 1
                if latency < 0 { latency = i - stepAt }
            }
        }
        assert(fireCount == 1,
               "EmotionSelfTests: BOCPD must fire exactly once for one step (got \(fireCount))")
        assert(latency >= 0 && latency <= 25,
               "EmotionSelfTests: BOCPD step latency out of range (\(latency))")
    }

    // MARK: - US-B7 — narrator honesty (metric M7)

    /// US-B7 / M7 — every narrated insight (i) cites ≥1 present `SignalRef`,
    /// (ii) contains NONE of `HonestyPhrases.bannedSubstrings` (case-insensitive),
    /// (iii) states a confidence word, and (iv) is grounded in the Persona framing.
    private static func narratorHonesty() {
        let events: [AffectEvent] = [
            AffectEvent(channel: .face, kind: .stateShift, magnitude: 0.5, confidence: 0.85,
                        evidence: [.valence], baselineDelta: 0.5),
            AffectEvent(channel: .face, kind: .stateShift, magnitude: 0.4, confidence: 0.3,
                        evidence: [.arousal], baselineDelta: -0.4),
            AffectEvent(channel: .eyes, kind: .blink, magnitude: 1, confidence: 0.5,
                        evidence: [.blinkRate]),
            AffectEvent(channel: .eyes, kind: .eyeClosureProlonged, magnitude: 1, confidence: 0.6,
                        evidence: [.prolongedClosure]),
            AffectEvent(channel: .hands, kind: .selfTouch, magnitude: 0.7, confidence: 0.35,
                        evidence: [.selfTouchRate]),
            AffectEvent(channel: .hands, kind: .gestureBurst, magnitude: 0.9, confidence: 0.7,
                        evidence: [.gestureEnergy]),
            AffectEvent(channel: .head, kind: .headMotionSpike, magnitude: 0.6, confidence: 0.5,
                        evidence: [.headMotionEnergy]),
            AffectEvent(channel: .voice, kind: .vocalEvent, magnitude: 0.5, confidence: 0.4,
                        evidence: [.vocalF0]),
            AffectEvent(channel: .interaction, kind: .congruenceBreak, magnitude: 0.5, confidence: 0.2,
                        evidence: [.cancelRate, .arousal]),
            AffectEvent(channel: nil, kind: .congruenceBreak, magnitude: 0.7, confidence: 0.2,
                        evidence: [.arousal, .blinkRate]),
            AffectEvent(channel: nil, kind: .arousalConsensus, magnitude: 0.8, confidence: 0.65,
                        evidence: [.arousal, .blinkRate]),
            AffectEvent(channel: nil, kind: .channelAvailabilityChanged, magnitude: 0, confidence: 0.9,
                        evidence: [.arousal]),
            AffectEvent(channel: .face, kind: .lowExpresserFlag, magnitude: 0, confidence: 0.3,
                        evidence: [.confidence]),
            AffectEvent(channel: .face, kind: .baselineRetrack, magnitude: 0.02, confidence: 0.5,
                        evidence: [.au4], baselineDelta: 0.02),
            // US-C9 — F7 Frustration activation (a fused construct; nil channel).
            AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.6, confidence: 0.55,
                        evidence: [.valence, .cancelRate], baselineDelta: nil),
            // US-C10 — F1 Composure activation (a fused construct; nil channel; NO
            // interaction signal ⇒ routes to the composure template, not frustration).
            AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.5, confidence: 0.3,
                        evidence: [.valence, .blinkRate], baselineDelta: nil),
            // US-C11 — F3 Fatigue⇄Engagement activation, BOTH poles (constructID-routed):
            // blink family, NO interaction signal — the misroute the constructID fixes.
            AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.6, confidence: 0.4,
                        evidence: [.blinkRate, .prolongedClosure], baselineDelta: -0.7,
                        constructID: ConstructID.fatigueEngagement),
            AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.5, confidence: 0.3,
                        evidence: [.blinkRate], baselineDelta: 0.6,
                        constructID: ConstructID.fatigueEngagement),
            // US-D14a — F2 Cognitive load activation (constructID-routed; effort/load only).
            AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.6, confidence: 0.4,
                        evidence: [.blinkRate, .inputTempo], baselineDelta: nil,
                        constructID: ConstructID.cognitiveLoad),
            // US-D14a — F4 Frown+head-down lean (constructID-routed; the LEAN via the
            // baselineDelta code, cites the present AU4 + head-pitch).
            AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.4, confidence: 0.3,
                        evidence: [.au4, .headPitch], baselineDelta: F4Lean.effort.rawValue,
                        constructID: ConstructID.frownHeadDown),
            // US-D14b — F6/F10/F8/F9/F5 activations (constructID-routed; each M7-clean).
            AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.5, confidence: 0.4,
                        evidence: [.valence, .recentLaughter], constructID: ConstructID.corroboratedPositivity),
            AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.4, confidence: 0.3,
                        evidence: [.headMotionEnergy], baselineDelta: 0.5, constructID: ConstructID.approachWithdrawal),
            AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.4, confidence: 0.3,
                        evidence: [.headPitch, .headYaw], baselineDelta: 0.6, constructID: ConstructID.dominance),
            AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.5, confidence: 0.3,
                        evidence: [.headPitch, .valence], constructID: ConstructID.expansiveDisplay),
            AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.5, confidence: 0.4,
                        evidence: [.blinkRate, .gestureEnergy], constructID: ConstructID.covertArousal),
        ]
        for e in events {
            let text = TemplateNarrator.narrate(e, reading: nil).text
            assert(e.evidence.contains { text.localizedCaseInsensitiveContains($0.displayName) },
                   "EmotionSelfTests: narrated insight cites no present SignalRef: \(text)")
            assert(!HonestyPhrases.containsBanned(text),
                   "EmotionSelfTests: narrated insight contains a banned substring: \(text)")
            assert(HonestyPhrases.confidenceWords.contains { text.localizedCaseInsensitiveContains($0) },
                   "EmotionSelfTests: narrated insight missing a confidence word: \(text)")
            assert(text.localizedCaseInsensitiveContains("persona"),
                   "EmotionSelfTests: narrated insight missing the Persona framing: \(text)")
        }

        // The linter itself must actually catch violations (case-insensitively).
        assert(HonestyPhrases.containsBanned("this reads like concealment"),
               "EmotionSelfTests: banned-substring linter failed to catch a violation")
        assert(HonestyPhrases.containsBanned("YOUR FACE looks tense"),
               "EmotionSelfTests: banned-substring linter must be case-insensitive")
        assert(!HonestyPhrases.containsBanned("valence moved toward more positive"),
               "EmotionSelfTests: banned-substring linter false-positived on clean copy")

        // US-B8 — the interaction lens copy is held to the same honesty floor: no
        // banned substring, and specifically NEVER "stress" (already banned) and never
        // "frustration" as a state (F7 Frustration is a LATER fusion construct; this
        // lens alone shows effort/load).
        let interactionCopy = [
            HonestyPhrases.interactionScope,
            HonestyPhrases.interactionStarved,
            HonestyPhrases.interactionAmbiguity,
            Lens.interaction.scope
        ]
        for copy in interactionCopy {
            assert(!HonestyPhrases.containsBanned(copy),
                   "EmotionSelfTests: interaction copy contains a banned substring: \(copy)")
            assert(!copy.localizedCaseInsensitiveContains("stress"),
                   "EmotionSelfTests: interaction copy must never say 'stress': \(copy)")
            assert(!copy.localizedCaseInsensitiveContains("frustration"),
                   "EmotionSelfTests: interaction lens copy must not assert 'frustration' (F7 is later): \(copy)")
        }

        // US-C9 — the F7 Frustration CONSTRUCT copy is the sanctioned "frustration
        // (task friction)" framing. Unlike the interaction lens alone it IS allowed to
        // say "frustration", but must still be banned-clean, keep the Persona framing,
        // cite a present interaction signal, and state a confidence word separate from
        // intensity (the honesty sweep over the new template strings — 6f).
        let f7Phrase = HonestyPhrases.frustration(confidence: 0.55)
        assert(!HonestyPhrases.containsBanned(f7Phrase),
               "EmotionSelfTests: F7 construct phrase contains a banned substring: \(f7Phrase)")
        assert(f7Phrase.localizedCaseInsensitiveContains("persona"),
               "EmotionSelfTests: F7 construct phrase must keep the Persona framing: \(f7Phrase)")
        assert(f7Phrase.localizedCaseInsensitiveContains(SignalRef.cancelRate.displayName),
               "EmotionSelfTests: F7 construct phrase must cite the interaction signal: \(f7Phrase)")
        assert(HonestyPhrases.confidenceWords.contains { f7Phrase.localizedCaseInsensitiveContains($0) },
               "EmotionSelfTests: F7 construct phrase must state a confidence word: \(f7Phrase)")
        assert(!HonestyPhrases.frustrationConfound.isEmpty
               && !HonestyPhrases.containsBanned(HonestyPhrases.frustrationConfound),
               "EmotionSelfTests: F7 confound must be present and banned-clean")
        let f7Title = F7FrustrationMode().title
        assert(f7Title.localizedCaseInsensitiveContains("task friction"),
               "EmotionSelfTests: F7 title must carry the 'task friction' framing: \(f7Title)")
        assert(!HonestyPhrases.containsBanned(f7Title),
               "EmotionSelfTests: F7 title must be banned-clean: \(f7Title)")

        // US-C10 (6g) — the F1 Composure CONSTRUCT copy. The sanctioned divergence
        // framings "composed but activated" and "possible regulation" MUST pass the
        // banlist (they are the honest wording — NOT "concealment"/"suppression"). The
        // narration keeps the Persona framing, cites the present blink proxy, and states a
        // confidence word separate from intensity.
        let f1Phrase = HonestyPhrases.composure(confidence: 0.3)
        assert(!HonestyPhrases.containsBanned(f1Phrase),
               "EmotionSelfTests: F1 construct phrase contains a banned substring: \(f1Phrase)")
        assert(f1Phrase.localizedCaseInsensitiveContains("composed but activated"),
               "EmotionSelfTests: F1 phrase must carry 'composed but activated': \(f1Phrase)")
        assert(f1Phrase.localizedCaseInsensitiveContains("possible regulation"),
               "EmotionSelfTests: F1 phrase must carry 'possible regulation': \(f1Phrase)")
        assert(f1Phrase.localizedCaseInsensitiveContains("persona"),
               "EmotionSelfTests: F1 phrase must keep the Persona framing: \(f1Phrase)")
        assert(f1Phrase.localizedCaseInsensitiveContains(SignalRef.blinkRate.displayName),
               "EmotionSelfTests: F1 phrase must cite the blink proxy: \(f1Phrase)")
        assert(HonestyPhrases.confidenceWords.contains { f1Phrase.localizedCaseInsensitiveContains($0) },
               "EmotionSelfTests: F1 phrase must state a confidence word: \(f1Phrase)")

        // The sanctioned framings must PASS the banlist (a regression guard on the
        // ruling that these are honest, not concealment claims).
        assert(!HonestyPhrases.containsBanned("composed but activated"),
               "EmotionSelfTests: 'composed but activated' must PASS the banlist (sanctioned)")
        assert(!HonestyPhrases.containsBanned("possible regulation"),
               "EmotionSelfTests: 'possible regulation' must PASS the banlist (sanctioned)")

        // Every new F1/F7-ladder string is banned-clean (never "concealment"/"genuine",
        // even in negation — the deterministic linter can't read intent).
        let ladderCopy = [
            HonestyPhrases.composureTentative(confidence: 0.2),
            HonestyPhrases.composureRationale,
            HonestyPhrases.composureConfound,
            HonestyPhrases.composureLowExpresserNote,
            HonestyPhrases.composureLadderL0, HonestyPhrases.composureLadderL0Fork,
            HonestyPhrases.composureLadderL1, HonestyPhrases.composureLadderL1Fork,
            HonestyPhrases.composureLadderL2, HonestyPhrases.composureLadderL2Fork,
            HonestyPhrases.composureLadderTentative, HonestyPhrases.composureLadderTentativeFork,
            HonestyPhrases.composureLadderRuledOut, HonestyPhrases.composureLadderRuledOutReason,
            F1ComposureMode().title,
            HonestyPhrases.frustrationLadderL0, HonestyPhrases.frustrationLadderL0Fork,
            HonestyPhrases.frustrationLadderL1, HonestyPhrases.frustrationLadderL1Fork
        ]
        for copy in ladderCopy {
            assert(!HonestyPhrases.containsBanned(copy),
                   "EmotionSelfTests: F1/F7 ladder copy contains a banned substring: \(copy)")
        }

        // The narrator ROUTING: a constructStateChanged with NO interaction signal AND no
        // constructID (a legacy event) still narrates as F1 composure (the safe fallback).
        let f1Event = AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.5,
                                  confidence: 0.3, evidence: [.valence, .blinkRate])
        let f1Text = TemplateNarrator.narrate(f1Event, reading: nil).text
        assert(f1Text.localizedCaseInsensitiveContains("composed but activated"),
               "EmotionSelfTests: an interaction-free legacy construct event must narrate as F1 composure: \(f1Text)")

        // US-C11 — constructID ROUTING (the misroute regression): F3's blink-family
        // evidence carries NO `.cancelRate`, so the OLD evidence heuristic would have
        // narrated it as F1 composure; routing by constructID sends it to the fatigue
        // template. Each of F7/F1/F3 routes to its OWN template by id (disjoint).
        let f3Fatigued = AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.6,
                                     confidence: 0.4, evidence: [.blinkRate, .prolongedClosure],
                                     baselineDelta: -0.7, constructID: ConstructID.fatigueEngagement)
        let f3FatiguedText = TemplateNarrator.narrate(f3Fatigued, reading: nil).text
        assert(f3FatiguedText.localizedCaseInsensitiveContains("alertness declining"),
               "EmotionSelfTests: an F3 fatigued event must narrate 'alertness declining', not composure: \(f3FatiguedText)")
        assert(!f3FatiguedText.localizedCaseInsensitiveContains("composed but activated"),
               "EmotionSelfTests: an F3 event must NOT misroute to the F1 composure template: \(f3FatiguedText)")
        let f3Engaged = AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.5,
                                    confidence: 0.3, evidence: [.blinkRate], baselineDelta: 0.6,
                                    constructID: ConstructID.fatigueEngagement)
        assert(TemplateNarrator.narrate(f3Engaged, reading: nil).text.localizedCaseInsensitiveContains("focused engagement"),
               "EmotionSelfTests: an F3 engaged event must narrate as focused engagement")
        let f7Routed = AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.6,
                                   confidence: 0.5, evidence: [.valence, .cancelRate],
                                   constructID: ConstructID.frustration)
        assert(TemplateNarrator.narrate(f7Routed, reading: nil).text.localizedCaseInsensitiveContains("frustration"),
               "EmotionSelfTests: an F7 event (by id) must route to the frustration template")
        let f1Routed = AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.5,
                                   confidence: 0.3, evidence: [.valence, .blinkRate],
                                   constructID: ConstructID.composure)
        assert(TemplateNarrator.narrate(f1Routed, reading: nil).text.localizedCaseInsensitiveContains("composed but activated"),
               "EmotionSelfTests: an F1 event (by id) must route to the composure template")
        // Legacy fallback still works: a nil-id interaction-friction event narrates frustration.
        let legacyFrustration = AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.6,
                                            confidence: 0.5, evidence: [.valence, .cancelRate])
        assert(TemplateNarrator.narrate(legacyFrustration, reading: nil).text.localizedCaseInsensitiveContains("frustration"),
               "EmotionSelfTests: a legacy (nil-id) interaction-friction event must still narrate frustration")

        // US-D14a — F2/F4 constructID ROUTING to their OWN templates. F2 speaks effort/load
        // (never "stress"); F4 speaks the hedged lean recovered from the baselineDelta code
        // (never "angry"). F4's lowered-brow evidence has no `.cancelRate`, so — like F3 — the
        // old evidence heuristic would have misrouted it; the constructID fixes that.
        let f2Routed = AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.6, confidence: 0.4,
                                   evidence: [.blinkRate, .inputTempo], constructID: ConstructID.cognitiveLoad)
        let f2Text = TemplateNarrator.narrate(f2Routed, reading: nil).text
        assert(f2Text.localizedCaseInsensitiveContains("effort/load"),
               "EmotionSelfTests: an F2 event must narrate the effort/load framing: \(f2Text)")
        assert(!f2Text.localizedCaseInsensitiveContains("stress"),
               "EmotionSelfTests: an F2 narration must never say 'stress': \(f2Text)")
        let f4Routed = AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.4, confidence: 0.3,
                                   evidence: [.au4, .headPitch], baselineDelta: F4Lean.displeasureApproach.rawValue,
                                   constructID: ConstructID.frownHeadDown)
        let f4Text = TemplateNarrator.narrate(f4Routed, reading: nil).text
        assert(f4Text.localizedCaseInsensitiveContains("displeasure"),
               "EmotionSelfTests: an F4 displeasure-approach event must narrate the lean: \(f4Text)")
        assert(!f4Text.localizedCaseInsensitiveContains("angry"),
               "EmotionSelfTests: an F4 narration must never assert 'angry': \(f4Text)")

        // US-D14b — F6/F10/F8/F9/F5 constructID ROUTING to their OWN templates.
        // F6 speaks "echoed", never smile-authenticity.
        let f6Routed = AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.5, confidence: 0.4,
                                   evidence: [.valence, .recentLaughter], constructID: ConstructID.corroboratedPositivity)
        assert(TemplateNarrator.narrate(f6Routed, reading: nil).text.localizedCaseInsensitiveContains("echoed"),
               "EmotionSelfTests: an F6 event must narrate the echoed framing")
        // F10 — the §4.3 tie-break keys off the FACE reading's valence: a NEGATIVE face adds the
        // displeasure lean; a nil/neutral face gets direction language only.
        let f10Approach = AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.4, confidence: 0.3,
                                      evidence: [.headMotionEnergy], baselineDelta: 0.5, constructID: ConstructID.approachWithdrawal)
        assert(TemplateNarrator.narrate(f10Approach, reading: nil).text.localizedCaseInsensitiveContains("approach"),
               "EmotionSelfTests: an F10 approach event with a neutral face must narrate direction only")
        let negFaceReading = EmotionReading(date: Date(), distribution: EmotionDistribution(normalizing: [.sadness: 1]),
                                            dominant: .sadness, confidence: 0.6, intensity: 0.5, intensities: [:],
                                            valence: -0.6, arousal: 0.2, faceDetected: true, quality: 0.8)
        let f10Tie = TemplateNarrator.narrate(f10Approach, reading: negFaceReading).text
        assert(f10Tie.localizedCaseInsensitiveContains("displeasure") && !f10Tie.localizedCaseInsensitiveContains("angry"),
               "EmotionSelfTests: an F10 approach event with a NEGATIVE face must add the displeasure lean (never 'angry'): \(f10Tie)")
        // F8 — DISPLAY language (expansion / contraction) from the signed axis.
        let f8Routed = AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.4, confidence: 0.3,
                                   evidence: [.headPitch, .headYaw], baselineDelta: 0.6, constructID: ConstructID.dominance)
        assert(TemplateNarrator.narrate(f8Routed, reading: nil).text.localizedCaseInsensitiveContains("expansion display"),
               "EmotionSelfTests: an F8 + axis event must narrate the expansion display")
        // F9 — head-only display; "pride" only a gloss, NO power-pose causal claim.
        let f9Routed = AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.5, confidence: 0.3,
                                   evidence: [.headPitch, .valence], constructID: ConstructID.expansiveDisplay)
        let f9Text = TemplateNarrator.narrate(f9Routed, reading: nil).text
        assert(f9Text.localizedCaseInsensitiveContains("head-only") && f9Text.localizedCaseInsensitiveContains("expansive"),
               "EmotionSelfTests: an F9 event must narrate the head-only expansive display: \(f9Text)")
        // F5 — corroborated arousal; a level, never "concealment".
        let f5Routed = AffectEvent(channel: nil, kind: .constructStateChanged, magnitude: 0.5, confidence: 0.4,
                                   evidence: [.blinkRate, .gestureEnergy], constructID: ConstructID.covertArousal)
        assert(TemplateNarrator.narrate(f5Routed, reading: nil).text.localizedCaseInsensitiveContains("corroborated arousal"),
               "EmotionSelfTests: an F5 event must narrate corroborated arousal")
    }

    // MARK: - US-B7 — the event bus

    /// US-B7 — the `AffectHub` event bus: append + cap trims OLDEST first (append-only
    /// audit log), keeping the newest.
    private static func eventBus() {
        let hub = AffectHub()
        let cap = AffectHub.eventsCap
        let n = cap + 15
        for i in 0..<n {
            hub.emit(AffectEvent(channel: .face, kind: .baselineRetrack,
                                 magnitude: Double(i), confidence: 0.5, evidence: [.au4]))
        }
        assert(hub.events.count == cap,
               "EmotionSelfTests: event bus cap not enforced (\(hub.events.count) != \(cap))")
        assert(hub.events.first?.magnitude == Double(n - cap),
               "EmotionSelfTests: event bus must trim oldest first")
        assert(hub.events.last?.magnitude == Double(n - 1),
               "EmotionSelfTests: event bus must keep the newest event")
    }

    // MARK: - US-E15 — golden-trace record/replay harness

    /// US-E15 — the golden-trace recorder/replay harness lifted from unit math to a
    /// FULL-PIPELINE regression. The embedded fixture (`GoldenTraceFixture`) is
    /// serialized to JSONL, decoded back (the real file path), then replayed:
    ///   (a) decode succeeds; (b) replay is DETERMINISTIC (two replays are `==`);
    ///   (c) golden expectations hold — exact blink count, exactly ONE valence
    ///   state-shift in the documented post-step window, and ZERO shifts in the
    ///   stationary prefix; (d) a JSONL round-trip preserves tick count + fields and
    ///   leaves the replay unchanged.
    private static func goldenTraceReplay() {
        let fixture = GoldenTraceFixture.build()

        // Serialize → JSONL and check the framing (header line + one line per tick).
        guard let jsonl = try? fixture.jsonlString() else {
            assertionFailure("EmotionSelfTests: golden fixture failed to serialize"); return
        }
        let lines = jsonl.split(separator: "\n", omittingEmptySubsequences: true)
        assert(lines.count == fixture.ticks.count + 1,
               "EmotionSelfTests: JSONL must be a header line + one line per tick (\(lines.count) vs \(fixture.ticks.count + 1))")

        // (a) Decode succeeds — from the serialized bytes.
        guard let decoded = try? Trace(jsonlString: jsonl) else {
            assertionFailure("EmotionSelfTests: golden JSONL failed to decode"); return
        }
        assert(decoded.ticks.count == fixture.ticks.count,
               "EmotionSelfTests: decoded tick count mismatch (\(decoded.ticks.count) vs \(fixture.ticks.count))")

        // (b) Determinism — two replays of the same trace are byte-identical.
        let r1 = TraceReplayer.replay(decoded)
        let r2 = TraceReplayer.replay(decoded)
        assert(r1 == r2, "EmotionSelfTests: replay is not deterministic")

        // (c) Golden expectations.
        assert(r1.tickCount == GoldenTraceFixture.tickCount,
               "EmotionSelfTests: replay tickCount \(r1.tickCount) != \(GoldenTraceFixture.tickCount)")
        assert(r1.blinkCount == GoldenTraceFixture.expectedBlinks,
               "EmotionSelfTests: golden blink count \(r1.blinkCount) != \(GoldenTraceFixture.expectedBlinks)")
        assert(r1.blinksPerMinute.last == Double(GoldenTraceFixture.expectedBlinks),
               "EmotionSelfTests: final blinks/min \(String(describing: r1.blinksPerMinute.last)) != \(GoldenTraceFixture.expectedBlinks)")
        // Exactly one state-shift, on the valence axis, inside the documented window.
        assert(r1.stateShiftTicks.count == 1,
               "EmotionSelfTests: expected exactly one state-shift, got \(r1.stateShiftTicks)")
        assert(r1.valenceShiftTicks.count == 1 && r1.arousalShiftTicks.isEmpty,
               "EmotionSelfTests: the abrupt step must fire ONLY the valence axis (v:\(r1.valenceShiftTicks) a:\(r1.arousalShiftTicks))")
        if let shift = r1.stateShiftTicks.first {
            let rel = shift - GoldenTraceFixture.stepTick
            assert(GoldenTraceFixture.shiftWindow.contains(rel),
                   "EmotionSelfTests: state-shift at tick \(shift) (rel \(rel)) outside window \(GoldenTraceFixture.shiftWindow)")
        }
        // ZERO shifts anywhere in the stationary/blink prefix (before the step).
        assert(r1.stateShiftTicks.allSatisfy { $0 >= GoldenTraceFixture.stepTick },
               "EmotionSelfTests: a state-shift fired in the stationary prefix: \(r1.stateShiftTicks)")

        // (d) Round-trip: encode(decode(fixture)) preserves tick count + fields, and
        //     the replay is invariant across the round-trip.
        guard let reJSONL = try? decoded.jsonlString(),
              let reDecoded = try? Trace(jsonlString: reJSONL) else {
            assertionFailure("EmotionSelfTests: golden re-encode/decode failed"); return
        }
        assert(reDecoded.ticks.count == decoded.ticks.count,
               "EmotionSelfTests: round-trip changed tick count")
        func approxOpt(_ a: Double?, _ b: Double?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (x?, y?): return abs(x - y) < 1e-9
            default: return false
            }
        }
        for (a, b) in zip(reDecoded.ticks, decoded.ticks) {
            assert(a.facePresent == b.facePresent, "EmotionSelfTests: round-trip facePresent drift")
            assert(approxOpt(a.eyeOpenLeft, b.eyeOpenLeft), "EmotionSelfTests: round-trip eyeOpenLeft drift")
            assert(abs(a.t.timeIntervalSinceReferenceDate - b.t.timeIntervalSinceReferenceDate) < 1e-9,
                   "EmotionSelfTests: round-trip tick date drift")
            assert(abs(a.faceReading.valence - b.faceReading.valence) < 1e-9,
                   "EmotionSelfTests: round-trip valence drift")
        }
        assert(TraceReplayer.replay(reDecoded) == r1,
               "EmotionSelfTests: replay changed across a JSONL round-trip")
    }

    /// US-E15 — the never-pixels guarantee. It is enforced by TYPE DESIGN (the
    /// `TraceTick` schema has no image/buffer field), so this is belt-and-braces:
    /// reflect a real tick and assert no stored property — at any depth — is a
    /// pixel/image/surface container type.
    private static func traceSchemaNoPixels() {
        guard let tick = GoldenTraceFixture.build().ticks.first else {
            assertionFailure("EmotionSelfTests: fixture produced no ticks"); return
        }
        let forbidden = ["pixelbuffer", "cvpixel", "cvimage", "cgimage", "ciimage",
                         "iosurface", "cmsamplebuffer", "mtltexture", "uiimage", "nsimage"]
        func scan(_ mirror: Mirror, depth: Int) {
            guard depth < 5 else { return }
            for child in mirror.children {
                let typeName = String(describing: type(of: child.value)).lowercased()
                for bad in forbidden {
                    assert(!typeName.contains(bad),
                           "EmotionSelfTests: TraceTick must never carry pixels — found \(typeName)")
                }
                scan(Mirror(reflecting: child.value), depth: depth + 1)
            }
        }
        scan(Mirror(reflecting: tick), depth: 0)
    }

    // MARK: - US-lab — Lab Mode replay-parameter study

    /// US-lab (PRD v2 §5.7 point 2 / §6.8) — the `TraceReplayer.replaySeries` parameter
    /// study that backs the Lab A/B panel. Covers:
    ///   (a) determinism — two `replaySeries` runs of the embedded fixture are `==`;
    ///   (b) REGRESSION LAW — the `ReplayResult` goldens are UNCHANGED, and the series'
    ///       blink/shift lanes agree with the golden path (same downstream math);
    ///   (c) params A/B — two configs that differ ONLY in the congruence-enter threshold
    ///       produce DIFFERENT divergence-break counts on a synthetic anti-correlated
    ///       face+eyes trace built to straddle them;
    ///   (d) mlWeight A/B — `.fixed(0)` vs `.fixed(1)` on a tick whose geometry and FER+
    ///       disagree give DIFFERENT re-fused dominants (the re-fusion path works), and a
    ///       trace WITHOUT distributions reports `hasDistributions == false` (params-only);
    ///   (e) `Lens` Codable round-trip (the detachable-window value type);
    ///   (f) per-channel trace coverage — a trace carrying recorded
    ///       interaction readings drives + latches the F7 replay lane deterministically,
    ///       survives the JSONL round-trip, and a trace WITHOUT them leaves F7 honestly
    ///       inert; nil per-channel readings are OMITTED keys (fixture bytes unchanged).
    private static func labReplay() {
        let dt = 1.0 / 15.0
        let t0 = Date(timeIntervalSinceReferenceDate: 900_000)
        func at(_ i: Int) -> Date { t0.addingTimeInterval(Double(i) * dt) }

        func faceReading(at t: Date, valence: Double, arousal: Double,
                         detected: Bool = true, quality: Double = 0.9) -> EmotionReading {
            EmotionReading(date: t, distribution: .neutralRest, dominant: .neutral,
                           confidence: 0.5, intensity: 0, intensities: [:],
                           valence: valence, arousal: arousal, faceDetected: detected, quality: quality)
        }
        func header() -> TraceHeader {
            TraceHeader(schemaVersion: TraceHeader.currentSchemaVersion, startedAt: t0,
                        appVersion: "labtest", baselineFingerprint: "lab-fixture", notes: "US-lab synthetic")
        }

        // ---- (a) determinism + (b) regression law, on the embedded golden fixture ----
        let fixture = GoldenTraceFixture.build()
        let s1 = TraceReplayer.replaySeries(fixture)
        let s2 = TraceReplayer.replaySeries(fixture)
        assert(s1 == s2, "EmotionSelfTests: replaySeries is not deterministic on the fixture")

        let golden = TraceReplayer.replay(fixture)
        assert(golden.blinkCount == GoldenTraceFixture.expectedBlinks,
               "EmotionSelfTests: ReplayResult golden blink count moved (\(golden.blinkCount))")
        assert(golden.stateShiftTicks.count == 1 && golden.valenceShiftTicks.count == 1 && golden.arousalShiftTicks.isEmpty,
               "EmotionSelfTests: ReplayResult golden state-shift goldens moved")
        // The series' duplicated lanes must AGREE with the golden ReplayResult path.
        assert(s1.blinkCount == golden.blinkCount,
               "EmotionSelfTests: series blink lane disagrees with ReplayResult (\(s1.blinkCount) vs \(golden.blinkCount))")
        assert(s1.stateShiftCount == golden.stateShiftTicks.count,
               "EmotionSelfTests: series shift lane disagrees with ReplayResult (\(s1.stateShiftCount) vs \(golden.stateShiftTicks.count))")

        // ---- (c) congruence-threshold params A/B ----
        // A face+eyes trace whose signed arousal votes are near-exact NEGATIVES ⇒ windowed
        // synchrony ≈ −1 sustained. Config A (default congruence-enter 0.0) latches ONE
        // divergence (−1 ≤ 0.0); config B (enter −1.5, below the cosine floor) can NEVER
        // latch (−1 > −1.5) ⇒ zero breaks. Same trace, one knob, different break counts.
        var congTicks: [TraceTick] = []
        for i in 0..<40 {
            let t = at(i)
            let phase = sin(0.6 * Double(i))
            let faceArousal = 0.3 * phase                    // face signed vote ≈ +0.6·sin
            let mag = 0.6 * abs(phase)                       // eyes magnitude
            let eyes = ChannelReading(
                channel: .eyes, date: t, availability: .live, quality: 0.8,
                valence: nil, arousal: Meter(value: mag, confidence: 0.3), intensity: 0,
                features: [.blinkRate: -phase],              // sign carrier ⇒ eyes signed vote = −0.6·sin
                posterior: nil)
            congTicks.append(TraceTick(
                t: t, facePresent: true, eyeOpenLeft: 0.2, eyeOpenRight: 0.2,
                yaw: 0, roll: 0, pitch: 0, auVector: [:],
                faceReading: faceReading(at: t, valence: 0, arousal: faceArousal),
                eyesReading: eyes, eventsEmitted: []))
        }
        let congTrace = Trace(header: header(), ticks: congTicks)
        let configA = TraceReplayer.ReplayConfig.default                    // congruence-enter 0.0
        var configB = TraceReplayer.ReplayConfig.default
        configB.congruenceEnter = -1.5                                      // below the cosine floor
        let breaksA = TraceReplayer.replaySeries(congTrace, config: configA).congruenceBreakCount
        let breaksB = TraceReplayer.replaySeries(congTrace, config: configB).congruenceBreakCount
        assert(breaksA >= 1, "EmotionSelfTests: expected ≥1 congruence break at enter 0.0, got \(breaksA)")
        assert(breaksB == 0, "EmotionSelfTests: expected 0 congruence breaks at enter −1.5, got \(breaksB)")
        assert(breaksA != breaksB,
               "EmotionSelfTests: congruence-threshold A/B must differ (A=\(breaksA), B=\(breaksB))")

        // ---- (d) mlWeight A/B on a tick whose geometry & FER+ disagree ----
        let geo = EmotionDistribution(normalizing: [.anger: 0.7, .neutral: 0.3])       // dominant anger
        let ml = EmotionDistribution(normalizing: [.happiness: 0.7, .neutral: 0.3])     // dominant happiness
        var abTicks: [TraceTick] = []
        for i in 0..<3 {
            let t = at(i)
            abTicks.append(TraceTick(
                t: t, facePresent: true, eyeOpenLeft: 0.2, eyeOpenRight: 0.2,
                yaw: 0, roll: 0, pitch: 0, auVector: [:],
                faceReading: faceReading(at: t, valence: 0, arousal: 0),
                eyesReading: nil, eventsEmitted: [],
                geometryDistribution: geo, mlDistribution: ml))
        }
        let abTrace = Trace(header: header(), ticks: abTicks)
        var wFixed0 = TraceReplayer.ReplayConfig.default; wFixed0.mlWeight = .fixed(0)
        var wFixed1 = TraceReplayer.ReplayConfig.default; wFixed1.mlWeight = .fixed(1)
        let sFixed0 = TraceReplayer.replaySeries(abTrace, config: wFixed0)
        let sFixed1 = TraceReplayer.replaySeries(abTrace, config: wFixed1)
        assert(sFixed0.hasDistributions, "EmotionSelfTests: a trace with distributions must report hasDistributions")
        assert(sFixed0.ticks.last?.refusedDominant == .anger,
               "EmotionSelfTests: mlWeight .fixed(0) must re-fuse to the GEOMETRY dominant (anger), got \(String(describing: sFixed0.ticks.last?.refusedDominant))")
        assert(sFixed1.ticks.last?.refusedDominant == .happiness,
               "EmotionSelfTests: mlWeight .fixed(1) must re-fuse to the FER+ dominant (happiness), got \(String(describing: sFixed1.ticks.last?.refusedDominant))")
        assert(sFixed0.ticks.last?.refusedDominant != sFixed1.ticks.last?.refusedDominant,
               "EmotionSelfTests: mlWeight A/B must diverge on a disagreeing tick")

        // Old trace (no distributions — the fixture) ⇒ categorical A/B UNAVAILABLE (params-only).
        assert(!s1.hasDistributions, "EmotionSelfTests: a pre-US-lab trace must report no distributions (params-only A/B)")
        assert(s1.ticks.allSatisfy { $0.refusedDominant == nil },
               "EmotionSelfTests: no distributions ⇒ every re-fused dominant must be nil")
        // …and, carrying no interaction readings, its F7 lane must stay honestly INERT.
        assert(s1.f7Activations == 0 && s1.ticks.allSatisfy { $0.f7Score == 0 },
               "EmotionSelfTests: a trace with no interaction readings must leave F7 inert")

        // ---- (f) F7 genuinely replays on a trace carrying interaction readings
        //          (the additive per-channel TraceTick fields) ----
        // A negative-leaning face + sustained interaction friction, recorded per tick the
        // way `TraceRecorder.capture` now does ⇒ the construct lane fuses F7 and latches
        // it after its documented enter dwell (38 ticks); deterministic across runs; and
        // decoding a PRE-additive JSONL line (no per-channel keys) yields nil readings.
        do {
            func interR(at t: Date) -> ChannelReading {
                ChannelReading(channel: .interaction, date: t, availability: .live, quality: 0.8,
                               valence: nil, arousal: nil, intensity: 0.7,
                               features: [.cancelRate: 0.4, .inputTempo: 10], posterior: nil)
            }
            var f7Ticks: [TraceTick] = []
            for i in 0..<50 {
                let t = at(i)
                f7Ticks.append(TraceTick(
                    t: t, facePresent: true, eyeOpenLeft: 0.2, eyeOpenRight: 0.2,
                    yaw: 0, roll: 0, pitch: 0, auVector: [:],
                    faceReading: faceReading(at: t, valence: -0.6, arousal: 0),
                    eyesReading: nil, eventsEmitted: [],
                    interactionReading: interR(at: t)))
            }
            let f7Trace = Trace(header: header(), ticks: f7Ticks)
            let f7A = TraceReplayer.replaySeries(f7Trace)
            let f7B = TraceReplayer.replaySeries(f7Trace)
            assert(f7A == f7B, "EmotionSelfTests: replaySeries must stay deterministic with per-channel readings")
            assert(f7A.ticks.contains { $0.f7Score > 0 },
                   "EmotionSelfTests: a recorded interaction reading must drive the F7 replay lane")
            assert(f7A.f7Activations >= 1,
                   "EmotionSelfTests: sustained negative-face + friction must latch F7 in replay, got \(f7A.f7Activations)")
            // JSONL round-trip: the per-channel readings survive; a pre-additive line decodes nil.
            guard let rt = try? TraceReplayer.replaySeries(jsonl: f7Trace.jsonlData()) else {
                assertionFailure("EmotionSelfTests: an interaction-bearing trace must round-trip JSONL"); return
            }
            assert(rt.f7Activations == f7A.f7Activations,
                   "EmotionSelfTests: the JSONL round-trip must preserve the F7 replay")
            // The legacy-compat guarantee: the fixture — which leaves every per-channel
            // reading nil — encodes with NO such keys (nil optionals are omitted by
            // synthesized Codable), so pre-additive traces and the golden fixture bytes
            // are unchanged; decoding a key-less line yields nil readings (the round-trip
            // of the fixture through `Trace(jsonl:)` above IS that decode path).
            assert(!(try! String(decoding: fixture.jsonlData(), as: UTF8.self)).contains("interactionReading"),
                   "EmotionSelfTests: nil per-channel readings must be OMITTED keys (fixture bytes unchanged)")
        }

        // ---- (e) Lens Codable round-trip (the detachable-window value type) ----
        let enc = JSONEncoder(); let dec = JSONDecoder()
        for lens in Lens.allCases {
            guard let data = try? enc.encode(lens), let back = try? dec.decode(Lens.self, from: data) else {
                assertionFailure("EmotionSelfTests: Lens failed Codable round-trip: \(lens)"); continue
            }
            assert(back == lens, "EmotionSelfTests: Lens Codable round-trip changed \(lens) → \(back)")
        }

        print("   • US-lab replay A/B: congruence breaks A=\(breaksA) vs B=\(breaksB); mlWeight fixed(0)→\(String(describing: sFixed0.ticks.last?.refusedDominant)) vs fixed(1)→\(String(describing: sFixed1.ticks.last?.refusedDominant))")
    }

    // MARK: - US-C8 — dynamic channel weighting + confidence algebra

    /// US-C8 — the categorical-pool weighting (PRD v2 §5.1 L2a / §5.4 / §8.1). Covers
    /// (a) the r=0 → identity acceptance criterion; (b) the byte-identical disabled
    /// path (`effectiveMLWeight` returns 0.35 verbatim); (c) the `DynamicFaceWeight`
    /// clamp + monotonicity + zero-drive anchor; and (d) the geometry-ambiguity
    /// `normalizedEntropy` helper (uniform > peaked).
    private static func logPoolWeights() {
        let geometry = EmotionDistribution(normalizing: [.anger: 0.6, .neutral: 0.4])
        let ml = EmotionDistribution(normalizing: [.happiness: 0.7, .neutral: 0.3])

        // (a) weight 0 ⇒ the r=0 channel has ZERO influence — the "r=0 drops to
        //     identity" AC. `EmotionDistribution.fused` is an eps-smoothed log-opinion
        //     pool (EmotionTypes.swift): at w=0 the `other` term vanishes, so the map
        //     depends ONLY on geometry. Proven by fusing the SAME geometry with two
        //     DIFFERENT experts at weight 0 and getting the identical result, with the
        //     geometry argmax preserved (the honest "identity": nothing from `other`).
        let viaML = geometry.fused(with: ml, weight: 0)
        let viaOther = geometry.fused(with: EmotionDistribution(normalizing: [.fear: 1]), weight: 0)
        for e in Emotion.allCases {
            assert(abs(viaML[e] - viaOther[e]) < 1e-12,
                   "EmotionSelfTests: an r=0 channel must not influence the fusion (\(e))")
        }
        assert(viaML.dominant.emotion == geometry.dominant.emotion,
               "EmotionSelfTests: r=0 fusion must preserve the geometry argmax")

        // (b) disabled path: the weight-selection rule returns the 0.35 constant
        //     verbatim regardless of the (unused) dynamic inputs — this is what
        //     guarantees byte-identical default fusion.
        let base = 0.35
        for fi in stride(from: 0.0, through: 1.0, by: 0.25) {
            for amb in stride(from: 0.0, through: 1.0, by: 0.25) {
                let w = DynamicFaceWeight.effectiveMLWeight(
                    dynamicEnabled: false, base: base,
                    faceIntensity: fi, faceAmbiguity: amb, mlConfidence: 0.9)
                assert(w == base,
                       "EmotionSelfTests: disabled dynamic weighting must return base 0.35 exactly, got \(w)")
            }
        }

        // (c) enabled: at ZERO drive the weight equals `base` exactly (today's anchor);
        //     it stays within [minWeight, maxWeight] across a full sweep; and it is
        //     monotone NON-DECREASING in each of intensity, ambiguity, ML confidence.
        let atRest = DynamicFaceWeight.mlWeight(base: base, faceIntensity: 0, faceAmbiguity: 0, mlConfidence: 1)
        assert(atRest == base, "EmotionSelfTests: dynamic weight at zero drive must equal base, got \(atRest)")

        let lo = DynamicFaceWeight.minWeight, hi = DynamicFaceWeight.maxWeight
        var prev = -1.0
        for fi in stride(from: 0.0, through: 1.0, by: 0.1) {
            let w = DynamicFaceWeight.mlWeight(base: base, faceIntensity: fi, faceAmbiguity: 0.3, mlConfidence: 0.8)
            assert(w >= lo - 1e-12 && w <= hi + 1e-12, "EmotionSelfTests: dynamic weight escaped [\(lo),\(hi)]: \(w)")
            assert(w >= prev - 1e-12, "EmotionSelfTests: dynamic weight must be non-decreasing in intensity")
            prev = w
        }
        prev = -1.0
        for amb in stride(from: 0.0, through: 1.0, by: 0.1) {
            let w = DynamicFaceWeight.mlWeight(base: base, faceIntensity: 0.5, faceAmbiguity: amb, mlConfidence: 0.8)
            assert(w >= prev - 1e-12, "EmotionSelfTests: dynamic weight must be non-decreasing in ambiguity")
            prev = w
        }
        prev = -1.0
        for c in stride(from: 0.0, through: 1.0, by: 0.1) {
            let w = DynamicFaceWeight.mlWeight(base: base, faceIntensity: 0.8, faceAmbiguity: 0.8, mlConfidence: c)
            assert(w >= prev - 1e-12, "EmotionSelfTests: dynamic weight must be non-decreasing in ML confidence")
            prev = w
        }
        let peak = DynamicFaceWeight.mlWeight(base: base, faceIntensity: 1, faceAmbiguity: 1, mlConfidence: 1)
        assert(abs(peak - hi) < 1e-12, "EmotionSelfTests: peak drive + confident ML must reach maxWeight, got \(peak)")

        // (d) the ambiguity helper: uniform entropy > peaked; normalized to [0,1].
        var uni = [Emotion: Double]()
        for e in Emotion.allCases { uni[e] = 1 }
        let uniform = EmotionDistribution(normalizing: uni)
        let peaked = EmotionDistribution(normalizing: [.anger: 1])
        assert(uniform.normalizedEntropy > peaked.normalizedEntropy,
               "EmotionSelfTests: uniform entropy must exceed peaked entropy")
        assert(abs(uniform.normalizedEntropy - 1) < 1e-9, "EmotionSelfTests: uniform normalized entropy must be 1")
        assert(peaked.normalizedEntropy < 1e-9, "EmotionSelfTests: one-hot normalized entropy must be 0")
    }

    /// US-C8 — Guo-2017 temperature scaling of FER+: T=1 is identity (byte-identical
    /// default), T>1 raises entropy, T<1 lowers it, renormalization holds, and the
    /// argmax is preserved by the monotone map.
    private static func temperatureScaling() {
        let dist = EmotionDistribution(normalizing: [.happiness: 0.6, .surprise: 0.25, .neutral: 0.15])

        let same = DynamicFaceWeight.temperatured(dist, T: 1)
        for e in Emotion.allCases {
            assert(abs(same[e] - dist[e]) < 1e-12, "EmotionSelfTests: T=1 temperature must be identity (\(e))")
        }

        let hot = DynamicFaceWeight.temperatured(dist, T: 2)
        let cold = DynamicFaceWeight.temperatured(dist, T: 0.5)
        assert(hot.normalizedEntropy > dist.normalizedEntropy, "EmotionSelfTests: T=2 must raise entropy")
        assert(cold.normalizedEntropy < dist.normalizedEntropy, "EmotionSelfTests: T=0.5 must lower entropy")

        func sum(_ d: EmotionDistribution) -> Double { Emotion.allCases.reduce(0) { $0 + d[$1] } }
        assert(abs(sum(hot) - 1) < 1e-9 && abs(sum(cold) - 1) < 1e-9,
               "EmotionSelfTests: temperatured distribution must renormalize to 1")
        assert(hot.dominant.emotion == dist.dominant.emotion && cold.dominant.emotion == dist.dominant.emotion,
               "EmotionSelfTests: temperature must not change the argmax")
    }

    /// US-C8 — the confidence algebra `c_k = q_cal · a · exp(−Δt/τ) · q_data` (§5.4):
    /// availability zeroing (unavailable ⇒ 0, degraded ⇒ ½), recency halving at
    /// τ·ln2, and clamping to [0,1].
    private static func confidenceAlgebra() {
        let full = ChannelConfidence.confidence(calibrationQuality: 1, availability: .live,
                                                secondsSinceUpdate: 0, tau: 1, dataQuality: 1)
        assert(abs(full - 1) < 1e-12, "EmotionSelfTests: a perfect channel must have confidence 1, got \(full)")

        let dark = ChannelConfidence.confidence(calibrationQuality: 1, availability: .unavailable,
                                                secondsSinceUpdate: 0, tau: 1, dataQuality: 1)
        assert(dark == 0, "EmotionSelfTests: an unavailable channel must have 0 confidence")

        let degraded = ChannelConfidence.confidence(calibrationQuality: 1, availability: .degraded,
                                                    secondsSinceUpdate: 0, tau: 1, dataQuality: 1)
        assert(abs(degraded - 0.5) < 1e-12, "EmotionSelfTests: a degraded channel halves confidence, got \(degraded)")

        let tau = 3.0
        let halfLife = tau * Foundation.log(2.0)
        let halved = ChannelConfidence.confidence(calibrationQuality: 1, availability: .live,
                                                  secondsSinceUpdate: halfLife, tau: tau, dataQuality: 1)
        assert(abs(halved - 0.5) < 1e-9, "EmotionSelfTests: recency must halve at τ·ln2, got \(halved)")

        let over = ChannelConfidence.confidence(calibrationQuality: 5, availability: .live,
                                                secondsSinceUpdate: 0, tau: 1, dataQuality: 5)
        assert(over >= 0 && over <= 1, "EmotionSelfTests: confidence must clamp to [0,1], got \(over)")
        let neg = ChannelConfidence.confidence(calibrationQuality: -2, availability: .live,
                                               secondsSinceUpdate: 0, tau: 1, dataQuality: 1)
        assert(neg == 0, "EmotionSelfTests: negative quality must clamp to 0")
    }

    /// US-C8 — the dimensional-combine seam (PRD v2 §7.2 seam b). With a NIL transform
    /// both branches (facePresent true/false) pass the raw V/A through UNCHANGED
    /// (byte-identical), and an installed transform is applied identically at both,
    /// keyed off `facePresent`. Exercises the real `combineVA` both sites route through.
    private static func vaTransformSeam() {
        let engine = EmotionEngine()
        func vaEqual(_ a: ValenceArousal, _ b: ValenceArousal) -> Bool {
            a.valence == b.valence && a.arousal == b.arousal
        }

        // Default: no construct installed ⇒ the seam is nil ⇒ identity at both sites.
        assert(engine.vaTransform == nil, "EmotionSelfTests: vaTransform must default to nil (byte-identical)")
        let raw: ValenceArousal = (valence: 0.42, arousal: -0.17)
        assert(vaEqual(engine.combineVA(raw, facePresent: false), raw)
               && vaEqual(engine.combineVA(raw, facePresent: true), raw),
               "EmotionSelfTests: a nil vaTransform must pass raw V/A through unchanged at BOTH sites")

        // An installed transform is applied at both sites and can branch on facePresent.
        engine.vaTransform = { va, facePresent in
            facePresent ? (valence: va.valence * 0.5, arousal: va.arousal) : (valence: 0, arousal: 0)
        }
        let tFace = engine.combineVA(raw, facePresent: true)
        assert(abs(tFace.valence - 0.21) < 1e-12 && tFace.arousal == raw.arousal,
               "EmotionSelfTests: an installed vaTransform must be applied at the face site")
        let tNoFace = engine.combineVA(raw, facePresent: false)
        assert(tNoFace.valence == 0 && tNoFace.arousal == 0,
               "EmotionSelfTests: vaTransform must see facePresent=false at the no-face site")
        engine.vaTransform = nil
    }

    // MARK: - US-C10a — the congruence / incongruence engine

    /// US-C10a — the `CongruenceEngine` (PRD v2 §4.4, options 1 + 2). Drives the pure
    /// core with synthetic votes: (a) two agreeing streams ⇒ high consensus + named
    /// agreeing + no break; (b) sustained opposite-sign streams ⇒ synchrony drops and
    /// EXACTLY ONE divergence event fires across the dwell (hysteresis), named diverging;
    /// (c) an r=0 channel is excluded (its vote flips nothing); (d) a single voter ⇒
    /// insufficient (no consensus claimed); (e) centered-cosine math sanity; (f) re-arm ⇒
    /// a recovery then a second divergence fires a SECOND event. Plus the honesty floor
    /// on the new labels + narrated templates. Synthetic votes only — no channels, no view.
    private static func congruenceEngine() {
        let dt = 1.0 / 15.0
        let t0 = Date(timeIntervalSinceReferenceDate: 700_000)
        func at(_ i: Int) -> Date { t0.addingTimeInterval(Double(i) * dt) }
        // A varying, always-POSITIVE drive: trajectories co-vary (so cosine is defined)
        // while staying same-sign for the consensus checks.
        func drive(_ i: Int) -> Double { 0.5 + 0.2 * sin(0.5 * Double(i)) }
        func vote(_ a: Double, _ r: Double) -> ChannelVote { ChannelVote(signedArousalDelta: a, reliability: r) }
        // Small window + dwell so the re-arm test flushes quickly and stays deterministic.
        func testEngine() -> CongruenceEngine {
            var e = CongruenceEngine()
            e.windowDuration = 1.0     // 1 s ≈ 15 ticks
            e.divergenceDwell = 0.4    // 0.4 s ≈ 6 ticks
            return e
        }

        // (e) centered-cosine sanity — the pure static, no engine state.
        let up = [1.0, 2, 3, 4]
        assert((CongruenceEngine.centeredCosine(up, up) ?? 0) > 0.999,
               "EmotionSelfTests: identical trajectories must cosine ~ +1")
        assert((CongruenceEngine.centeredCosine(up, [4.0, 3, 2, 1]) ?? 0) < -0.999,
               "EmotionSelfTests: inverted trajectories must cosine ~ −1")
        let orth = CongruenceEngine.centeredCosine([-1, 1, 1, -1], [1, 1, -1, -1]) ?? .nan
        assert(abs(orth) < 1e-9, "EmotionSelfTests: orthogonal trajectories must cosine ~ 0 (got \(orth))")
        assert(CongruenceEngine.centeredCosine([2, 2, 2, 2], up) == nil,
               "EmotionSelfTests: a constant trajectory has no correlation (nil)")

        // (a) Two agreeing streams (same sign) ⇒ consensus high, named agreeing, no break.
        do {
            var eng = testEngine()
            var breaks = 0
            var last = CongruenceUpdate(state: .insufficient, divergenceBegan: false, agreementBegan: false)
            for i in 0..<40 {
                let d = drive(i)
                last = eng.update(votes: [.face: vote(d, 0.8), .eyes: vote(d, 0.6)], at: at(i))
                if last.divergenceBegan { breaks += 1 }
            }
            assert((last.state.consensus ?? 0) > 0.9, "EmotionSelfTests: agreeing streams must give high consensus")
            assert(last.state.named == .agreeing,
                   "EmotionSelfTests: same-sign streams must be named agreeing, got \(last.state.named)")
            assert(breaks == 0, "EmotionSelfTests: agreeing streams must not fire a divergence break")
        }

        // (b) Sustained opposite signs ⇒ synchrony drops, EXACTLY ONE break, named diverging.
        do {
            var eng = testEngine()
            var breaks = 0
            var last = CongruenceUpdate(state: .insufficient, divergenceBegan: false, agreementBegan: false)
            for i in 0..<40 {
                let d = drive(i)
                last = eng.update(votes: [.face: vote(d, 0.8), .eyes: vote(-d, 0.6)], at: at(i))
                if last.divergenceBegan { breaks += 1 }
            }
            assert((last.state.synchrony ?? 1) < -0.5, "EmotionSelfTests: anti-phase streams must drop synchrony negative")
            assert(breaks == 1, "EmotionSelfTests: a sustained divergence must fire EXACTLY ONE break, got \(breaks)")
            assert(last.state.named == .diverging,
                   "EmotionSelfTests: sustained opposite signs must be named diverging, got \(last.state.named)")
        }

        // (c) An r=0 channel is excluded — its (opposite-sign) vote flips nothing: the
        //     state is identical to face-only, and it never appears as a vote.
        do {
            var withZero = testEngine()
            var faceOnly = testEngine()
            for i in 0..<20 {
                let d = drive(i)
                let a = withZero.update(votes: [.face: vote(d, 0.8), .eyes: vote(-0.9, 0.0)], at: at(i))
                let b = faceOnly.update(votes: [.face: vote(d, 0.8)], at: at(i))
                assert(a.state == b.state, "EmotionSelfTests: an r=0 vote must not change the state")
                assert(a.state.named == .insufficient,
                       "EmotionSelfTests: one voter (after r=0 exclusion) is insufficient")
                assert(a.state.votes[.eyes] == nil, "EmotionSelfTests: an r=0 channel must not be retained as a vote")
                assert(!a.divergenceBegan, "EmotionSelfTests: an r=0 channel must not fire a divergence")
            }
        }

        // (d) A single voter ⇒ insufficient (no consensus claimed).
        do {
            var eng = testEngine()
            let u = eng.update(votes: [.face: vote(0.6, 0.9)], at: at(0))
            assert(u.state.named == .insufficient, "EmotionSelfTests: a single voter must be insufficient")
            assert(u.state.consensus == nil, "EmotionSelfTests: a single voter claims no consensus")
        }

        // (f) Re-arm: diverge → recover → diverge again ⇒ TWO breaks total. Long phases so
        //     each fully flushes the 1 s window before the next target is asserted.
        do {
            var eng = testEngine()
            var breaks = 0
            var i = 0
            func feed(_ count: Int, _ makeVotes: (Int) -> [Channel: ChannelVote]) {
                for _ in 0..<count {
                    if eng.update(votes: makeVotes(i), at: at(i)).divergenceBegan { breaks += 1 }
                    i += 1
                }
            }
            feed(60) { j in [.face: vote(drive(j), 0.8), .eyes: vote(-drive(j), 0.6)] }   // diverge #1
            assert(breaks == 1, "EmotionSelfTests: first sustained divergence must fire one break, got \(breaks)")
            feed(60) { j in [.face: vote(drive(j), 0.8), .eyes: vote(drive(j), 0.6)] }    // recover ⇒ re-arm
            feed(60) { j in [.face: vote(drive(j), 0.8), .eyes: vote(-drive(j), 0.6)] }   // diverge #2
            assert(breaks == 2, "EmotionSelfTests: a recovery then a new divergence must fire a SECOND break, got \(breaks)")
        }

        // Honesty floor: the congruence labels + narrated templates are banned-clean and
        // keep the Persona framing (the M7 grammar the FM narrator will later reuse).
        for named in [NamedCongruence.insufficient, .agreeing, .mixed, .diverging] {
            if let label = HonestyPhrases.congruenceStateLabel(named) {
                assert(!HonestyPhrases.containsBanned(label),
                       "EmotionSelfTests: congruence label must be banned-clean: \(label)")
            }
        }
        assert(HonestyPhrases.congruenceStateLabel(.insufficient) == nil,
               "EmotionSelfTests: insufficient must render NO ring judgment (nil label)")
        let brk = HonestyPhrases.congruenceBreak(evidence: [.arousal, .blinkRate], confidence: 0.3)
        let agr = HonestyPhrases.arousalConsensus(evidence: [.arousal, .blinkRate], confidence: 0.8)
        for line in [brk, agr] {
            assert(!HonestyPhrases.containsBanned(line),
                   "EmotionSelfTests: congruence narration must be banned-clean: \(line)")
            assert(line.localizedCaseInsensitiveContains("persona"),
                   "EmotionSelfTests: congruence narration must keep the Persona framing: \(line)")
        }
    }

    // MARK: - US-D12 — the voice prosody math + speech gate

    /// US-D12 — the `ProsodyMath` pure core + the eyes speech-gate. (a) YIN on synthesized
    /// 440 Hz and 220 Hz sines ⇒ F0 within ±3 %; (b) RMS of a known-amplitude sine ⇒ the
    /// analytic A/√2; (c) VAD: silence ⇒ unvoiced, a loud periodic sine ⇒ voiced; (d) the
    /// arousal mapping is monotone in the F0 delta and the intensity delta, clamped to
    /// [0, 1], with confidence never exceeding the maturity ceiling; (e) the speech gate
    /// scales the eyes lens's arousal CONFIDENCE by exactly the documented factor; (g) the
    /// voice CONGRUENCE VOTE — `signedActivation` inverts the published meter exactly, a
    /// live elevated-F0 channel votes positive with positive reliability and is retained
    /// by the congruence engine, and a disabled lens never votes (§4.4: voice owns
    /// arousal, so it joins face/eyes/hands/head in consensus). Pure math + synthetic
    /// buffers — no mic, no AVFoundation.
    private static func prosodyMath() {
        func sine(_ f: Double, _ rate: Double, _ n: Int, _ amp: Float) -> [Float] {
            (0..<n).map { amp * Float(sin(2 * Double.pi * f * Double($0) / rate)) }
        }
        let rate = 8000.0

        // (a) YIN on clean sines — within a documented ±3 % of the true F0.
        let (f440, ap440) = ProsodyMath.estimateF0(sine(440, rate, 2048, 0.5), sampleRate: rate,
                                                   minF0: 70, maxF0: 500, threshold: 0.15)
        assert(f440 != nil, "EmotionSelfTests: a clean 440 Hz sine must be voiced (non-nil F0)")
        assert(abs((f440 ?? 0) - 440) <= 440 * 0.03,
               "EmotionSelfTests: YIN 440 Hz must be within 3%, got \(f440 ?? -1)")
        assert(ap440 < 0.15, "EmotionSelfTests: a clean sine must be highly periodic (low aperiodicity)")
        let (f220, _) = ProsodyMath.estimateF0(sine(220, rate, 2048, 0.5), sampleRate: rate,
                                               minF0: 70, maxF0: 500, threshold: 0.15)
        assert(f220 != nil && abs((f220 ?? 0) - 220) <= 220 * 0.03,
               "EmotionSelfTests: YIN 220 Hz must be within 3%, got \(f220 ?? -1)")

        // (b) RMS of a sine (integer number of periods) equals the analytic A/√2.
        let amp: Float = 0.5
        let measuredRMS = ProsodyMath.rms(sine(300, rate, 4000, amp))   // 300·4000/8000 = 150 periods
        let analyticRMS = Double(amp) / 2.0.squareRoot()
        assert(abs(measuredRMS - analyticRMS) < 5e-3,
               "EmotionSelfTests: RMS of a sine must equal A/√2, got \(measuredRMS) vs \(analyticRMS)")

        // (c) VAD (energy floor + periodicity): silence ⇒ unvoiced; a loud sine ⇒ voiced.
        var math = ProsodyMath()
        let t0 = Date(timeIntervalSinceReferenceDate: 900_000)
        let fSilence = math.ingest(samples: [Float](repeating: 0, count: 2048), sampleRate: rate, date: t0)
        assert(!fSilence.voiced, "EmotionSelfTests: silence must be unvoiced (energy floor)")
        let fVoice = math.ingest(samples: sine(200, rate, 2048, 0.4), sampleRate: rate,
                                 date: t0.addingTimeInterval(0.1))
        assert(fVoice.voiced && fVoice.f0 != nil,
               "EmotionSelfTests: a loud periodic sine must be voiced")
        assert(math.isSpeaking, "EmotionSelfTests: the most-recent voiced frame must set isSpeaking")

        // (d) arousal mapping — monotone in both deltas, clamped, confidence ≤ ceiling.
        func arousal(_ f0d: Double, _ intd: Double, maturity: Double = 1, avail: Double = 1) -> Meter {
            ProsodyMath.arousal(f0Delta: f0d, intensityDelta: intd,
                                f0Scale: 60, intensityScale: 0.08,
                                maturity: maturity, availability: avail, maxConfidence: 0.5)
        }
        let mid = arousal(0, 0).value
        assert(arousal(40, 0).value > mid, "EmotionSelfTests: arousal must rise with a positive F0 delta")
        assert(arousal(-40, 0).value < mid, "EmotionSelfTests: arousal must fall with a negative F0 delta")
        assert(arousal(0, 0.05).value > mid, "EmotionSelfTests: arousal must rise with a positive intensity delta")
        assert((0...1).contains(arousal(1000, 1000).value) && arousal(1000, 1000).value == 1,
               "EmotionSelfTests: arousal value must clamp to 1 at the top")
        assert(arousal(-1000, -1000).value == 0,
               "EmotionSelfTests: arousal value must clamp to 0 at the bottom")
        let maturity = 0.4, maxC = 0.5
        let m = arousal(20, 0.02, maturity: maturity)
        assert(m.confidence <= maxC * maturity + 1e-9,
               "EmotionSelfTests: arousal confidence must not exceed the maturity ceiling (\(m.confidence))")
        assert(arousal(20, 0.02, maturity: 1).confidence <= maxC + 1e-9,
               "EmotionSelfTests: arousal confidence must never exceed maxConfidence")

        // (e) the speech gate scales the EYES arousal confidence by exactly the factor.
        let ekey = EyeChannel.enabledKey
        let esaved = UserDefaults.standard.object(forKey: ekey)
        UserDefaults.standard.set(true, forKey: ekey)
        let base = Date(timeIntervalSinceReferenceDate: 950_000)
        func analysis(_ open: Double, _ d: Date) -> FrameAnalysis {
            FrameAnalysis(extraction: nil, imageSize: CGSize(width: 100, height: 100), date: d,
                          facePresent: true, eyeOpenLeft: open, eyeOpenRight: open,
                          yaw: nil, roll: nil, pitch: nil)
        }
        // Two channels driven by IDENTICAL scripts (no hub ⇒ deterministic); gate only one
        // on the final tick, then compare the published arousal confidence.
        func driveConfidence(gatedFinal: Bool) -> Double? {
            let ch = EyeChannel()
            for i in 0..<3 { ch.ingest(analysis(0.2, base.addingTimeInterval(Double(i) * 0.066))) }
            ch.speechGateActive = gatedFinal
            ch.ingest(analysis(0.2, base.addingTimeInterval(3 * 0.066)))
            return ch.reading.arousal?.confidence
        }
        let ungated = driveConfidence(gatedFinal: false)
        let gated = driveConfidence(gatedFinal: true)
        assert(ungated != nil && gated != nil,
               "EmotionSelfTests: a live eyes lens must publish an arousal meter to gate")
        if let u = ungated, let g = gated {
            assert(u > 0, "EmotionSelfTests: ungated eyes arousal confidence must be positive")
            assert(abs(g - u * EyeChannel.speechGateConfidenceFactor) < 1e-9,
                   "EmotionSelfTests: speech gate must scale eyes arousal confidence by the documented factor, got \(g) vs \(u)")
        }
        restore(ekey, esaved)

        // (g) VOICE congruence vote (§4.4 — voice OWNS arousal, so it VOTES like
        //     eyes/hands/head). The signed activation exactly inverts the published
        //     meter's 0.5-centred encoding; a live channel with an elevated voiced F0
        //     exposes a positive signed vote with positive reliability that the
        //     congruence engine retains; a DISABLED lens never votes.
        do {
            // Pure mapping: at-baseline meter (0.5) ⇒ 0; ProsodyMath's +full-F0 /
            // flat-intensity blend (activation +0.5 ⇒ value 0.75) ⇒ +0.5; mirrored ⇒ −0.5.
            assert(abs(VoiceChannel.signedActivation(from: Meter(value: 0.5, confidence: 1))) < 1e-9,
                   "EmotionSelfTests: an at-baseline voice meter must map to a 0 signed vote")
            let upMeter = ProsodyMath.arousal(f0Delta: 60, intensityDelta: 0, f0Scale: 60,
                                              intensityScale: 0.08, maturity: 1, availability: 1,
                                              maxConfidence: 0.5)
            assert(abs(VoiceChannel.signedActivation(from: upMeter) - 0.5) < 1e-9,
                   "EmotionSelfTests: +full-scale F0 (flat intensity) must map to a +0.5 signed vote")
            let downMeter = ProsodyMath.arousal(f0Delta: -60, intensityDelta: 0, f0Scale: 60,
                                                intensityScale: 0.08, maturity: 1, availability: 1,
                                                maxConfidence: 0.5)
            assert(abs(VoiceChannel.signedActivation(from: downMeter) + 0.5) < 1e-9,
                   "EmotionSelfTests: −full-scale F0 (flat intensity) must map to a −0.5 signed vote")

            // Channel + hub-idiom vote. Construct the hub FIRST (voice.connect resets the
            // enabled flag — the mic-never-auto-arms law), THEN enable; drive two synthetic
            // snapshots: the first voiced sample SEEDS the per-user F0 baseline to itself
            // (zero delta), the second, higher one reads as a positive delta against the
            // slow-retracked baseline. Synthetic past dates ⇒ the save throttle never
            // persists these baselines (the lastSave guard).
            let vkey = VoiceChannel.enabledKey
            let vsaved = UserDefaults.standard.object(forKey: vkey)
            let hub = AffectHub()
            hub.applyThermalPolicy(.full, changedFrom: nil, tier: .nominal)
            UserDefaults.standard.set(true, forKey: vkey)
            let t0v = Date(timeIntervalSinceReferenceDate: 960_000)
            func snap(_ f0: Double, at t: Date) -> ProsodySnapshot {
                ProsodySnapshot(date: t, engineRunning: true, unavailableReason: nil,
                                f0Median: f0, f0Variance: 4, latestVoicedF0: f0,
                                intensityMedian: 0.05, voicedIntensityMedian: 0.05,
                                currentLevel: 0.05, voicedFraction: 0.8, onsetRate: 2,
                                isSpeaking: true, frameCount: 10, voicedCount: 8,
                                laughter: false, cry: false)
            }
            hub.voice.apply(snap(150, at: t0v))                                // seeds F0 baseline ≈150
            hub.voice.apply(snap(220, at: t0v.addingTimeInterval(1)))          // ≈ +68 Hz vs the slow baseline
            assert(hub.voice.availability == .live,
                   "EmotionSelfTests: a dense voiced snapshot stream must read .live")
            guard let signed = hub.voice.signedArousalDelta else {
                assertionFailure("EmotionSelfTests: a live voice reading must expose a signed arousal vote")
                restore(vkey, vsaved); return
            }
            assert(signed > 0,
                   "EmotionSelfTests: a positive voiced-F0 delta must be a positive signed vote, got \(signed)")
            let rel = ChannelConfidence.confidence(
                calibrationQuality: hub.voice.baselineLearned ? 1 : 0.5,
                availability: hub.voice.availability, secondsSinceUpdate: 0,
                tau: 1, dataQuality: hub.voice.quality)
            assert(rel > 0, "EmotionSelfTests: a live voice reading must have positive reliability")
            var eng = CongruenceEngine()
            let upd = eng.update(votes: [
                .face: ChannelVote(signedArousalDelta: 0.5, reliability: 0.8),
                .voice: ChannelVote(signedArousalDelta: signed, reliability: rel)
            ], at: t0v.addingTimeInterval(1))
            assert(upd.state.votes[.voice] != nil,
                   "EmotionSelfTests: voice must be retained as a congruence voter")
            assert(upd.state.named != .insufficient,
                   "EmotionSelfTests: face + voice ⇒ two voters ⇒ not insufficient")
            // The disabled lens must NEVER vote.
            UserDefaults.standard.set(false, forKey: vkey)
            assert(hub.voice.signedArousalDelta == nil,
                   "EmotionSelfTests: a disabled voice lens must not expose a vote")
            restore(vkey, vsaved)
        }
    }

    // MARK: - US-D13a — the hand kinematics core + hands vote inclusion

    /// US-D13a — the `HandKinematics` pure core + the hands congruence vote. Synthetic
    /// joint-position streams only (no ARKit, no device): (a) a known-displacement stream ⇒
    /// motion energy matches the analytic speed; (b) GAP robustness — a 0.5 s tracking hole
    /// with a large jump does NOT spike the windowed energy (≤ the continuous case); (c)
    /// self-touch — an approach below threshold with dwell ⇒ exactly ONE event (refractory
    /// holds), the rate is 1/min, and a still-present touch ticks again past the refractory (a
    /// RATE, never a one-shot); (d) aperture — open vs pinched skeletons order correctly; (e)
    /// gesture bursts — N separated motion spikes count as N bursts; (f) a live hands reading
    /// with a positive energy delta yields a positive `ChannelVote` retained by the congruence
    /// engine.
    private static func handKinematics() {
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

        // A 7-joint hand at distinct base positions, all shifted by `offset` (so a per-frame
        // offset step is a known per-joint displacement). Wrist↔middle-knuckle is a non-zero
        // hand-scale reference, so aperture is well-defined.
        func hand(_ side: HandSide, at t: Date, offset: SIMD3<Double>, tracked: Bool = true) -> HandJointsSample {
            let bases: [HandJoint: SIMD3<Double>] = [
                .wrist:         SIMD3(0.00, 0.00, 0.00),
                .thumbTip:      SIMD3(0.02, 0.06, 0.00),
                .indexTip:      SIMD3(0.00, 0.10, 0.00),
                .middleTip:     SIMD3(0.01, 0.10, 0.00),
                .ringTip:       SIMD3(0.02, 0.09, 0.00),
                .littleTip:     SIMD3(0.03, 0.08, 0.00),
                .middleKnuckle: SIMD3(0.01, 0.05, 0.00)
            ]
            var p: [HandJoint: SIMD3<Double>] = [:]
            for (j, b) in bases { p[j] = b + offset }
            return HandJointsSample(side: side, date: t, positions: p, isTracked: tracked)
        }

        // (a) Known displacement: +0.01 m/frame at dt 0.05 s ⇒ 0.2 m/s per joint ⇒ mean 0.2.
        do {
            var k = HandKinematics()
            for i in 0..<10 { k.ingest(hand(.left, at: at(Double(i) * 0.05), offset: SIMD3(Double(i) * 0.01, 0, 0))) }
            let e = k.meanJointSpeed(now: at(0.45))
            assert(abs(e - 0.2) < 1e-6, "EmotionSelfTests: motion energy must match the analytic 0.2 m/s, got \(e)")
        }

        // (b) GAP robustness: a 0.5 s hole (> maxSampleDt) with a 20 m jump is SKIPPED, so the
        //     windowed energy does NOT spike (a naive |Δ|/Δt would read ~40 m/s here).
        var continuousE = 0.0
        do {
            var kc = HandKinematics()
            for i in 0..<10 { kc.ingest(hand(.left, at: at(Double(i) * 0.05), offset: SIMD3(Double(i) * 0.01, 0, 0))) }
            continuousE = kc.meanJointSpeed(now: at(0.45))
        }
        do {
            var kg = HandKinematics()
            for i in 0..<5 { kg.ingest(hand(.left, at: at(Double(i) * 0.05), offset: SIMD3(Double(i) * 0.01, 0, 0))) } // t 0…0.20
            kg.ingest(hand(.left, at: at(0.70), offset: SIMD3(20.04, 0, 0)))                                          // 0.5 s hole + 20 m jump → skipped
            for i in 0..<3 { kg.ingest(hand(.left, at: at(0.75 + Double(i) * 0.05), offset: SIMD3(20.05 + Double(i) * 0.01, 0, 0))) }
            let gapE = kg.meanJointSpeed(now: at(0.85))
            assert(gapE <= continuousE + 1e-6,
                   "EmotionSelfTests: gap-window energy (\(gapE)) must not exceed the continuous case (\(continuousE))")
            assert(gapE < 1.0, "EmotionSelfTests: a tracking gap must NOT spike the motion energy, got \(gapE)")
        }

        // (c) Self-touch: dwell ⇒ one event, refractory holds, rate math, then a re-tick.
        do {
            var ks = HandKinematics()
            ks.ingestHead(SIMD3(0, 0, 0), at: at(0))
            func nearHand(at t: Date) -> HandJointsSample {
                let p: [HandJoint: SIMD3<Double>] = [
                    .wrist: SIMD3(0.50, 0, 0), .thumbTip: SIMD3(0.40, 0, 0),
                    .indexTip: SIMD3(0.10, 0, 0),                       // 0.10 m from the head ⇒ near (< 0.12)
                    .middleTip: SIMD3(0.40, 0, 0), .ringTip: SIMD3(0.45, 0, 0),
                    .littleTip: SIMD3(0.50, 0, 0), .middleKnuckle: SIMD3(0.48, 0, 0)
                ]
                return HandJointsSample(side: .left, date: t, positions: p, isTracked: true)
            }
            for i in 0...20 { ks.ingest(nearHand(at: at(Double(i) * 0.05))) }   // t 0…1.0 (< 2 s refractory)
            assert(ks.selfTouchTotal == 1,
                   "EmotionSelfTests: a sustained touch under the refractory must be exactly ONE event, got \(ks.selfTouchTotal)")
            assert(ks.selfTouchRate(now: at(1.0)) == 1,
                   "EmotionSelfTests: one self-touch in the window must read 1/min, got \(ks.selfTouchRate(now: at(1.0)))")
            for i in 21...60 { ks.ingest(nearHand(at: at(Double(i) * 0.05))) }  // t 1.05…3.0 (past the 2.3 s refractory)
            assert(ks.selfTouchTotal == 2,
                   "EmotionSelfTests: past the refractory a still-present touch ticks again (a RATE), got \(ks.selfTouchTotal)")
        }

        // (d) Aperture: open (wider thumb↔index) must exceed pinched; exact = gap / hand scale.
        do {
            func skeleton(thumbIndexGap g: Double) -> [HandJoint: SIMD3<Double>] {
                [.wrist: SIMD3(0, 0, 0), .middleKnuckle: SIMD3(0, 0.10, 0),   // hand scale = 0.10
                 .thumbTip: SIMD3(0, 0.20, 0), .indexTip: SIMD3(g, 0.20, 0)]  // thumb↔index = g
            }
            let pinched = HandKinematics.aperture(skeleton(thumbIndexGap: 0.01)) ?? .nan
            let open = HandKinematics.aperture(skeleton(thumbIndexGap: 0.09)) ?? .nan
            assert(open > pinched, "EmotionSelfTests: an open hand must have a larger aperture than a pinched one (\(open) vs \(pinched))")
            assert(abs(pinched - 0.1) < 1e-9 && abs(open - 0.9) < 1e-9,
                   "EmotionSelfTests: aperture = thumb↔index / hand-scale (got \(pinched), \(open))")
        }

        // (e) Gesture bursts: three separated motion spikes (> the 0.6 s burst refractory apart)
        //     count as three bursts; the slow inter-spike drift never triggers one.
        do {
            var kb = HandKinematics()
            var x = 0.0
            for i in 0...40 {
                let big = (i == 1 || i == 14 || i == 27)            // t = 0.05, 0.70, 1.35 (≈0.65 s apart)
                x += big ? 0.05 : 0.001                             // 0.05 m/0.05 s = 1.0 m/s burst; 0.001 m = 0.02 m/s slow
                kb.ingest(hand(.left, at: at(Double(i) * 0.05), offset: SIMD3(x, 0, 0)))
            }
            assert(kb.gestureBurstTotal == 3,
                   "EmotionSelfTests: three separated motion spikes must count as three bursts, got \(kb.gestureBurstTotal)")
            assert(kb.gestureRate(now: at(2.0)) == 3,
                   "EmotionSelfTests: three bursts in the window must read 3/min, got \(kb.gestureRate(now: at(2.0)))")
        }

        // (f) Hands vote inclusion: a live, positive-energy hands reading yields a positive
        //     ChannelVote retained by the congruence engine alongside a face vote.
        do {
            let key = HandsChannel.enabledKey
            let saved = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            let hub = AffectHub()
            let snap = HandKinematicsSnapshot(
                date: at(100), hasData: true, tracked: true, meanJointSpeed: 0.4,
                handAperture: 0.5, selfTouchRate: 0, gestureRate: 2,
                newSelfTouchEvents: 0, newGestureBursts: 0,
                sampleCount: 30, headSeen: true, ingestCount: 100)
            hub.hands.apply(snap)
            assert(hub.hands.availability == .live,
                   "EmotionSelfTests: a dense, tracked hands snapshot must read .live")
            assert((hub.hands.reading.arousal?.value ?? 0) > 0,
                   "EmotionSelfTests: high motion energy must give a positive hands arousal")
            guard let signed = hub.hands.signedArousalDelta else {
                assertionFailure("EmotionSelfTests: a live hands reading must expose a signed arousal vote")
                restore(key, saved); return
            }
            assert(signed > 0, "EmotionSelfTests: a positive motion-energy delta must be a positive signed vote, got \(signed)")
            let rel = ChannelConfidence.confidence(
                calibrationQuality: hub.hands.restingLearned ? 1 : 0.5,
                availability: hub.hands.availability, secondsSinceUpdate: 0,
                tau: 1, dataQuality: hub.hands.quality)
            assert(rel > 0, "EmotionSelfTests: a live, dense hands reading must have positive reliability")
            var eng = CongruenceEngine()
            let up = eng.update(votes: [
                .face: ChannelVote(signedArousalDelta: 0.5, reliability: 0.8),
                .hands: ChannelVote(signedArousalDelta: signed, reliability: rel)
            ], at: snap.date)
            assert(up.state.votes[.hands] != nil,
                   "EmotionSelfTests: hands must be retained as a congruence voter")
            assert(up.state.named != .insufficient,
                   "EmotionSelfTests: face + hands ⇒ two voters ⇒ not insufficient")
            restore(key, saved)
        }
    }

    /// US-D13b — the `HeadPoseMath` pure core + `HeadChannel`: (a) neutral-pose delta math;
    /// (b) the `dominanceLean` formula incl. the GAZE-GATE HEDGE (down+away ⇒ negative,
    /// back+level ⇒ positive, down+TOWARD ⇒ closer to neutral than down+away); (c) gap-aware
    /// angular motion energy (a tracking hole doesn't spike); (d) the dual-source channel
    /// wiring (a moving 6DoF stream ⇒ live + positive arousal + a retained congruence vote +
    /// the master-law shape). Synthetic poses only — no ARKit, no Vision.
    private static func headPose() {
        let t0 = Date(timeIntervalSinceReferenceDate: 900_000)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-9 }

        // (a) Neutral-pose delta math: signed component-wise Δ from a seeded neutral.
        do {
            let neutral = HeadPose(pitch: 0.10, yaw: -0.20, roll: 0.05)
            let pose = HeadPose(pitch: 0.40, yaw: 0.10, roll: 0.00)
            let d = HeadPoseMath.delta(pose, from: neutral)
            assert(approx(d.pitch, 0.30) && approx(d.yaw, 0.30) && approx(d.roll, -0.05),
                   "EmotionSelfTests: head pose delta wrong (\(d.pitch), \(d.yaw), \(d.roll))")
        }

        // (b) dominanceLean — the two innate displays + the gaze-gate hedge.
        do {
            let pScale = HeadChannel.dominancePitchScale, yScale = HeadChannel.dominanceYawScale
            let downAway = HeadPoseMath.dominanceLean(pitchDelta: -0.4, yawDelta: 0.5, pitchScale: pScale, yawScale: yScale)
            let backLevel = HeadPoseMath.dominanceLean(pitchDelta: 0.4, yawDelta: 0.0, pitchScale: pScale, yawScale: yScale)
            let downToward = HeadPoseMath.dominanceLean(pitchDelta: -0.4, yawDelta: 0.0, pitchScale: pScale, yawScale: yScale)
            assert(downAway < 0, "EmotionSelfTests: head-down + turned-away must read withdrawal (negative), got \(downAway)")
            assert(backLevel > 0, "EmotionSelfTests: head-back + level must read expansion (positive), got \(backLevel)")
            // THE gaze-gate hedge: a straight look-down (yaw ≈ 0) must NOT read full withdrawal —
            // it must be CLOSER to neutral than the same down-pitch WITH a turn-away.
            assert(downToward > downAway,
                   "EmotionSelfTests: down+toward must be closer to neutral than down+away (\(downToward) !> \(downAway))")
            assert(abs(downToward) < abs(downAway),
                   "EmotionSelfTests: the gaze-gate hedge — a straight look-down stays near neutral (\(downToward) vs \(downAway))")
            // Bounds.
            for lean in [downAway, backLevel, downToward] {
                assert((-1...1).contains(lean), "EmotionSelfTests: dominanceLean out of [−1,1]: \(lean)")
            }
        }

        // (c) GAP robustness: a 0.5 s hole (> maxSampleDt) with a big yaw jump is SKIPPED, so
        //     the windowed angular energy does NOT spike (a naive |Δ|/Δt would read ~6 rad/s).
        func poseYaw(_ y: Double) -> HeadPose { HeadPose(pitch: 0, yaw: y, roll: 0) }
        var continuousE = 0.0
        do {
            var kc = HeadPoseMath()
            for i in 0..<10 { kc.ingest(poseYaw(Double(i) * 0.02), at: at(Double(i) * 0.05), source: .windowed) }
            continuousE = kc.angularMotionEnergy(now: at(0.45))
            assert(abs(continuousE - 0.4) < 1e-6, "EmotionSelfTests: head motion energy must match the analytic 0.4 rad/s, got \(continuousE)")
        }
        do {
            var kg = HeadPoseMath()
            for i in 0..<5 { kg.ingest(poseYaw(Double(i) * 0.02), at: at(Double(i) * 0.05), source: .windowed) }   // t 0…0.20
            kg.ingest(poseYaw(3.08), at: at(0.70), source: .windowed)                                             // 0.5 s hole + ~3 rad jump → skipped
            for i in 0..<3 { kg.ingest(poseYaw(3.10 + Double(i) * 0.02), at: at(0.75 + Double(i) * 0.05), source: .windowed) }
            let gapE = kg.angularMotionEnergy(now: at(0.85))
            assert(gapE <= continuousE + 1e-6,
                   "EmotionSelfTests: gap-window head energy (\(gapE)) must not exceed the continuous case (\(continuousE))")
            assert(gapE < 1.0, "EmotionSelfTests: a head-tracking gap must NOT spike the motion energy, got \(gapE)")
        }

        // (d) Dual-source channel: a moving 6DoF stream ⇒ live + positive arousal + a retained
        //     congruence vote + the master-law shape (no valence, no posterior, has dominanceLean).
        do {
            let key = HeadChannel.enabledKey
            let saved = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            let hub = AffectHub()
            hub.applyThermalPolicy(.full, changedFrom: nil, tier: .nominal)   // deterministic: never thermally paused
            var lastDate = at(0)
            for i in 0..<20 {
                lastDate = at(Double(i) * 0.1)                      // ~10 Hz immersive poll
                hub.head.applyImmersive(pose: poseYaw(Double(i) * 0.05), at: lastDate)   // 0.05 rad/step ⇒ 0.5 rad/s
            }
            assert(hub.head.availability == .live,
                   "EmotionSelfTests: a dense, moving 6DoF stream must read .live")
            assert(hub.head.activeSource == .immersive6DoF,
                   "EmotionSelfTests: the 6DoF source must be active while it is fresh")
            assert((hub.head.reading.arousal?.value ?? 0) > 0,
                   "EmotionSelfTests: sustained head motion must give a positive head arousal")
            assert(hub.head.reading.valence == nil && hub.head.reading.posterior == nil,
                   "EmotionSelfTests: head owns dominance/arousal — never valence, never a posterior")
            assert(hub.head.reading.features[.dominanceLean] != nil && hub.head.reading.features[.headMotionEnergy] != nil,
                   "EmotionSelfTests: a live head reading must carry dominanceLean + headMotionEnergy")
            guard let signed = hub.head.signedArousalDelta else {
                assertionFailure("EmotionSelfTests: a live head reading must expose a signed arousal vote")
                restore(key, saved); return
            }
            assert(signed > 0, "EmotionSelfTests: a positive head motion-energy delta must be a positive signed vote, got \(signed)")
            let rel = ChannelConfidence.confidence(
                calibrationQuality: hub.head.restingLearned ? 1 : 0.5,
                availability: hub.head.availability, secondsSinceUpdate: 0,
                tau: 1, dataQuality: hub.head.quality)
            assert(rel > 0, "EmotionSelfTests: a live, dense head reading must have positive reliability")
            var eng = CongruenceEngine()
            let up = eng.update(votes: [
                .face: ChannelVote(signedArousalDelta: 0.5, reliability: 0.8),
                .head: ChannelVote(signedArousalDelta: signed, reliability: rel)
            ], at: lastDate)
            assert(up.state.votes[.head] != nil,
                   "EmotionSelfTests: head must be retained as a congruence voter")
            restore(key, saved)
        }
    }

    /// US-D13b — the THERMAL GOVERNOR: (d) the pure policy map (all four tiers ⇒ the exact
    /// documented `SensingPolicy`); (e) the engine guard identity (`mlScoringEnabled`
    /// defaults true ⇒ byte-identical) + the nominal governor leaving the face pipeline
    /// unchanged; the aux-gate application + recovery; and (f) the honesty sweep of the new
    /// head + thermal copy.
    private static func thermalGovernor() {
        // (d) The pure policy map — exact values per PRD §8.1.
        assert(SensingPolicy.policy(for: .nominal) ==
               SensingPolicy(faceInterval: 1.0 / 15.0, ferPlusEnabled: true, immersivePollHz: 10, auxChannelsEnabled: true),
               "EmotionSelfTests: nominal policy wrong")
        assert(SensingPolicy.policy(for: .fair) == SensingPolicy.policy(for: .nominal),
               "EmotionSelfTests: fair must share nominal's core (FM reserved-off)")
        assert(SensingPolicy.policy(for: .serious) ==
               SensingPolicy(faceInterval: 1.0 / 8.0, ferPlusEnabled: false, immersivePollHz: 5, auxChannelsEnabled: true),
               "EmotionSelfTests: serious policy wrong")
        assert(SensingPolicy.policy(for: .critical) ==
               SensingPolicy(faceInterval: 1.0 / 8.0, ferPlusEnabled: false, immersivePollHz: 2, auxChannelsEnabled: false),
               "EmotionSelfTests: critical policy wrong")
        assert(SensingPolicy.full == SensingPolicy.policy(for: .nominal),
               "EmotionSelfTests: .full must equal the nominal policy")

        // (e) Engine guard identity: a fresh engine defaults FER+ scoring ON — the
        //     byte-identical anchor (independent of the live thermal state).
        assert(EmotionEngine().mlScoringEnabled == true,
               "EmotionSelfTests: mlScoringEnabled must default true (byte-identical FER+ scoring)")

        // Application + recovery, driven DETERMINISTICALLY (never read the live thermal state
        // — a warm CI box would flake). Force a known FULL baseline first (`changedFrom: nil`
        // ⇒ knobs reset, no insight), then drive CRITICAL, then recover to NOMINAL.
        let hub = AffectHub()
        hub.applyThermalPolicy(.full, changedFrom: nil, tier: .nominal)
        assert(hub.face.mlScoringEnabled == true && hub.face.minProcessInterval == 1.0 / 15.0
               && hub.auxThermallyPaused == false,
               "EmotionSelfTests: the FULL policy must be byte-identical (FER+ on, 1/15, aux on)")

        hub.applyThermalPolicy(.policy(for: .critical), changedFrom: .nominal, tier: .critical)
        assert(hub.face.minProcessInterval == 1.0 / 8.0 && hub.face.mlScoringEnabled == false,
               "EmotionSelfTests: critical must halve the face cadence + drop FER+")
        assert(hub.auxThermallyPaused,
               "EmotionSelfTests: critical must pause aux sensing")
        assert(hub.eyes.thermalPaused && hub.hands.thermalPaused && hub.voice.thermalPaused && hub.head.thermalPaused,
               "EmotionSelfTests: critical must pause every aux channel (eyes/hands/voice/head)")
        assert(hub.events.contains { $0.kind == .channelAvailabilityChanged },
               "EmotionSelfTests: a tier change must emit a .channelAvailabilityChanged event")
        assert(hub.insights.contains { $0.kind == .channelAvailabilityChanged },
               "EmotionSelfTests: a tier change must narrate ONE governor insight")

        hub.applyThermalPolicy(.full, changedFrom: .critical, tier: .nominal)
        assert(hub.face.minProcessInterval == 1.0 / 15.0 && hub.face.mlScoringEnabled == true,
               "EmotionSelfTests: recovery to nominal must restore the face pipeline")
        assert(hub.auxThermallyPaused == false && !hub.head.thermalPaused,
               "EmotionSelfTests: recovery to nominal must resume aux sensing")

        // (f) Honesty sweep — every new head + thermal string is banned-substring-clean, the
        //     withdrawal line keeps the gaze caveat, and the governor copy is non-alarming.
        let copy = [
            HonestyPhrases.headScope,
            HonestyPhrases.headAmbiguity,
            HonestyPhrases.headHonesty,
            HonestyPhrases.headDominanceLine(lean: 0.5),
            HonestyPhrases.headDominanceLine(lean: -0.5),
            HonestyPhrases.headDominanceLine(lean: 0),
            HonestyPhrases.thermalReduced(warmth: "warm"),
            HonestyPhrases.thermalReduced(warmth: "running hot"),
            HonestyPhrases.thermalRestored,
            Lens.head.scope
        ]
        for c in copy {
            assert(!HonestyPhrases.containsBanned(c),
                   "EmotionSelfTests: head/thermal copy contains a banned substring: \(c)")
        }
        assert(HonestyPhrases.headHonesty.localizedCaseInsensitiveContains("gaze"),
               "EmotionSelfTests: the head honesty paragraph must keep the gaze caveat")
        assert(HonestyPhrases.headDominanceLine(lean: -0.5).localizedCaseInsensitiveContains("gaze"),
               "EmotionSelfTests: the withdrawal line must keep the gaze caveat (Witkower)")
        // The governor insights themselves must be banned-clean (they land in the same feed).
        for entry in hub.insights where entry.kind == .channelAvailabilityChanged {
            assert(!HonestyPhrases.containsBanned(entry.text),
                   "EmotionSelfTests: a governor insight contains a banned substring: \(entry.text)")
        }
    }

    /// Deterministic standard-normal generator (SplitMix64 + Box-Muller) so the BOCPD
    /// self-test streams are exactly reproducible — no flaky false-positive budget.
    private struct SeededGaussian {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x1234567 : seed }

        private mutating func nextU64() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        private mutating func nextUnit() -> Double {
            (Double(nextU64() >> 11) + 0.5) * (1.0 / 9007199254740992.0)
        }
        mutating func next() -> Double {
            let u1 = max(nextUnit(), 1e-12)
            let u2 = nextUnit()
            return (-2.0 * Foundation.log(u1)).squareRoot() * Foundation.cos(2.0 * Double.pi * u2)
        }
    }

    /// the uncertainty-display grammar (VSUP, quantile dotplot, forked meter,
    /// multi-label chip) + the fused-aura pure helpers. All pure math + the default-off
    /// guard; no view is instantiated. Also sweeps the new honesty copy through the banlist.
    private static func uncertaintyWidgets() {
        func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

        // (a) VSUP: saturation is monotone NON-DECREASING in confidence (never higher as
        //     confidence falls), c == 1 returns the base unchanged, and the coarsen bins are
        //     stable + drawn from the expected discrete set.
        let vsupBase: (h: Double, s: Double, b: Double) = (0.5, 1.0, 0.9)
        var lastSat = -1.0
        for step in 0...20 {
            let c = Double(step) / 20
            let s = VSUP.adjust(vsupBase, confidence: c).s
            assert(s >= lastSat - 1e-12, "EmotionSelfTests: VSUP saturation must not fall as confidence rises")
            lastSat = s
        }
        assert(VSUP.adjust(vsupBase, confidence: 0.2).s <= VSUP.adjust(vsupBase, confidence: 0.8).s,
               "EmotionSelfTests: lower confidence must not yield higher saturation")
        let full = VSUP.adjust(vsupBase, confidence: 1)
        assert(approx(full.h, vsupBase.h) && approx(full.s, vsupBase.s) && approx(full.b, vsupBase.b),
               "EmotionSelfTests: VSUP at confidence 1 must return the base color unchanged")
        // Coarsen: monotone, in the discrete {0, 1/3, 2/3, 1} set, and stable within a bin.
        let allowedBins = [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0]
        var lastBin = -1.0
        for step in 0...20 {
            let c = Double(step) / 20
            let bin = VSUP.coarsen(c)
            assert(allowedBins.contains { approx($0, bin) }, "EmotionSelfTests: VSUP.coarsen produced an off-grid value \(bin)")
            assert(bin >= lastBin - 1e-12, "EmotionSelfTests: VSUP.coarsen must be monotone")
            lastBin = bin
        }
        assert(approx(VSUP.coarsen(0.1), VSUP.coarsen(0.24)),
               "EmotionSelfTests: VSUP.coarsen must be stable inside a bin")
        assert(approx(VSUP.coarsen(0), 0) && approx(VSUP.coarsen(1), 1),
               "EmotionSelfTests: VSUP.coarsen endpoints must be 0 and 1")

        // (b) QuantileDotplot: dots span center±spread, count as configured, all finite, and a
        //     degenerate (0) spread collapses to a tight cluster at center.
        let center = 0.2, spread = 0.3
        let dots = QuantileDotplot.dotValues(center: center, spread: spread, range: -1...1, count: 15)
        assert(dots.count == 15, "EmotionSelfTests: dotplot must produce the configured dot count")
        assert(dots.allSatisfy { $0.isFinite }, "EmotionSelfTests: dotplot values must all be finite")
        assert(dots.min()! < center && dots.max()! > center, "EmotionSelfTests: dots must straddle the center")
        assert(dots.min()! <= center - spread && dots.max()! >= center + spread,
               "EmotionSelfTests: dots must span at least center±spread")
        let tight = QuantileDotplot.dotValues(center: center, spread: 0, range: -1...1, count: 15)
        assert(tight.count == 15 && tight.allSatisfy { approx($0, center, 1e-12) },
               "EmotionSelfTests: a zero spread must collapse to a tight cluster at center (no NaN)")
        // Clamping keeps everything inside the range even when the estimate hugs an edge.
        let clamped = QuantileDotplot.dotValues(center: 0.95, spread: 0.5, range: -1...1, count: 15)
        assert(clamped.allSatisfy { $0 >= -1 - 1e-9 && $0 <= 1 + 1e-9 },
               "EmotionSelfTests: dotplot values must clamp into the range")

        // (c) StateOfMindRamp: endpoint hues match the anchors, the midpoint hue ordering holds
        //     (purple > blue > orange), and the valence input clamps.
        assert(approx(StateOfMindRamp.color(valence: -1).h, StateOfMindRamp.unpleasant.h),
               "EmotionSelfTests: valence −1 must map to the unpleasant (purple) hue anchor")
        assert(approx(StateOfMindRamp.color(valence: 1).h, StateOfMindRamp.pleasant.h),
               "EmotionSelfTests: valence +1 must map to the pleasant (orange) hue anchor")
        let hNeg = StateOfMindRamp.color(valence: -1).h
        let hMid = StateOfMindRamp.color(valence: 0).h
        let hPos = StateOfMindRamp.color(valence: 1).h
        assert(hNeg > hMid && hMid > hPos, "EmotionSelfTests: ramp hue must decrease purple → blue → orange")
        assert(approx(StateOfMindRamp.color(valence: -5).h, hNeg) && approx(StateOfMindRamp.color(valence: 5).h, hPos),
               "EmotionSelfTests: StateOfMindRamp must clamp its valence input")

        // (d) CombinedArousal: r = 0 (and nil meters) are EXCLUDED, weights renormalize, the
        //     default reliability is the meter's own confidence, and an empty set ⇒ nil.
        let excluded = CombinedArousal.compute(
            meters: [.face: Meter(value: 1.0, confidence: 0.9), .eyes: Meter(value: -1.0, confidence: 0.9)],
            reliabilities: [.face: 0, .eyes: 1])
        assert(excluded != nil && approx(excluded!.value, -1.0) && approx(excluded!.confidence, 1.0),
               "EmotionSelfTests: CombinedArousal must exclude r = 0 channels (value + confidence)")
        let weighted = CombinedArousal.compute(
            meters: [.face: Meter(value: 1.0, confidence: 1), .eyes: Meter(value: -1.0, confidence: 1)],
            reliabilities: [.face: 1, .eyes: 3])
        assert(weighted != nil && approx(weighted!.value, -0.5),
               "EmotionSelfTests: CombinedArousal weights must renormalize ((1·1 + 3·−1)/4 = −0.5)")
        let defaulted = CombinedArousal.compute(
            meters: [.face: Meter(value: 0.5, confidence: 0.8)], reliabilities: [:])
        assert(defaulted != nil && approx(defaulted!.value, 0.5) && approx(defaulted!.confidence, 0.8),
               "EmotionSelfTests: CombinedArousal must default reliability to the meter's confidence")
        assert(CombinedArousal.compute(meters: [:], reliabilities: [:]) == nil,
               "EmotionSelfTests: CombinedArousal over nothing must be nil")
        assert(CombinedArousal.compute(meters: [.face: nil], reliabilities: [.face: 1]) == nil,
               "EmotionSelfTests: a nil meter must not contribute")
        assert(CombinedArousal.compute(meters: [.face: Meter(value: 1, confidence: 0.5)], reliabilities: [.face: 0]) == nil,
               "EmotionSelfTests: an all-zero-reliability set must be nil")

        // (e) MultiLabelChip: a wide top-2 margin ⇒ a single label; a narrow margin ⇒ two,
        //     ordered by probability; a tighter threshold flips a borderline case back to one.
        let wide = EmotionDistribution(normalizing: [.happiness: 0.8, .neutral: 0.2])
        let wideLabels = MultiLabelChip.topLabels(for: wide)
        assert(wideLabels == [.happiness], "EmotionSelfTests: a wide margin must give a single label")
        let narrow = EmotionDistribution(normalizing: [.happiness: 0.45, .surprise: 0.40, .neutral: 0.15])
        let narrowLabels = MultiLabelChip.topLabels(for: narrow)
        assert(narrowLabels == [.happiness, .surprise],
               "EmotionSelfTests: a narrow margin must give the top-2 labels, ordered by probability")
        assert(MultiLabelChip.topLabels(for: narrow, margin: 0.01) == [.happiness],
               "EmotionSelfTests: a tighter threshold must not hedge a borderline case")

        // (f) Fused-aura DEFAULT-OFF guard: with the key absent, the flag reads false — the
        //     byte-identical face-driven path. A throwaway suite proves the UserDefaults-absent
        //     path without touching the app's real defaults.
        let suiteName = "FusedAuraTests." + UUID().uuidString
        if let suite = UserDefaults(suiteName: suiteName) {
            assert(suite.object(forKey: FusedAura.enabledKey) == nil,
                   "EmotionSelfTests: the fused-aura key must be absent in a fresh suite")
            assert(suite.bool(forKey: FusedAura.enabledKey) == false,
                   "EmotionSelfTests: an absent fused-aura key must read false (default-off guard)")
            suite.removePersistentDomain(forName: suiteName)
        } else {
            assertionFailure("EmotionSelfTests: could not create a throwaway UserDefaults suite")
        }

        // Honesty sweep: every new user-facing string is banned-substring-clean.
        for s in [HonestyPhrases.auraFusedToggleLabel, HonestyPhrases.auraFusedExplainer,
                  HonestyPhrases.arousalWideAxisTitle, HonestyPhrases.arousalWideAxisCaption,
                  HonestyPhrases.eyesForkLowLabel, HonestyPhrases.eyesForkHighLabel,
                  HonestyPhrases.eyesForkExplainer,
                  HonestyPhrases.multiLabelPrefix] {
            assert(!HonestyPhrases.containsBanned(s),
                   "EmotionSelfTests: new honesty string overclaims (banned substring): \(s)")
        }
    }

    /// US-E17 — the ESM ground-truth loop math: Lin's CCC (a hand-computed case + the
    /// perfect/anti/too-few edges), split-conformal APS (score/predict + a seeded
    /// coverage test + the min-sample gate), the QuickMood label-mapping totality, the
    /// SelfReport JSONL round-trip (incl. nil inferred fields + a malformed-line skip),
    /// and the never-interruptive prompt cooldown. Pure + deterministic; the only object
    /// built is a MEMORY-ONLY `EsmStore` (never touches the app's real ESM file).
    private static func esmAndConformal() {
        func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

        // (a) Lin's CCC. Hand-computed case x=[1,2,3,4], y=[1.1,2.1,2.9,4.2]:
        //     x̄=2.5, ȳ=2.575; population varX=1.25, varY=1.286875, cov=1.2625;
        //     denom = 1.25+1.286875+(−0.075)² = 2.5425; CCC = 2·1.2625/2.5425 = 0.99311701.
        let ccc = Concordance.ccc([1, 2, 3, 4], [1.1, 2.1, 2.9, 4.2])
        assert(ccc != nil && approx(ccc!, 0.99311701),
               "EmotionSelfTests: CCC hand-case wrong, got \(String(describing: ccc))")
        assert(Concordance.ccc([1, 2, 3, 4], [1, 2, 3, 4]).map { approx($0, 1) } == true,
               "EmotionSelfTests: perfect concordance must be 1")
        assert((Concordance.ccc([1, 2, 3, 4], [4, 3, 2, 1]) ?? 0) < 0,
               "EmotionSelfTests: anti-concordance must be negative")
        assert(Concordance.ccc([1, 2], [1, 2]) == nil, "EmotionSelfTests: CCC must be nil under 3 pairs")
        assert(Concordance.ccc([1, 2, 3], [1, 2]) == nil, "EmotionSelfTests: mismatched lengths must be nil")
        assert(Concordance.ccc([2, 2, 2], [2, 2, 2]) == nil,
               "EmotionSelfTests: a zero-variance pair has no concordance (nil)")

        // (b) APS score: cumulative desc mass up to & including the true label.
        let d = EmotionDistribution(normalizing: [.neutral: 0.5, .happiness: 0.3, .sadness: 0.2])
        assert(approx(ConformalCalibrator.score(d, trueLabel: .neutral), 0.5),
               "EmotionSelfTests: APS score for the top label must be its own mass")
        assert(approx(ConformalCalibrator.score(d, trueLabel: .happiness), 0.8),
               "EmotionSelfTests: APS score must accumulate down to the true label")
        assert(approx(ConformalCalibrator.score(d, trueLabel: .sadness), 1.0),
               "EmotionSelfTests: APS score for the last label must reach 1")

        // APS predict: the smallest desc prefix whose cumulative mass reaches qhat.
        assert(ConformalCalibrator.predict(d, qhat: 0.4) == [.neutral],
               "EmotionSelfTests: qhat below the top mass yields the single top label")
        assert(ConformalCalibrator.predict(d, qhat: 0.6) == [.neutral, .happiness],
               "EmotionSelfTests: qhat between prefixes yields the top-2 set")
        assert(ConformalCalibrator.predict(d, qhat: 1.0) == [.neutral, .happiness, .sadness],
               "EmotionSelfTests: qhat = 1 yields the full support")

        // (b cont.) Min-sample gate: 19 pairs ⇒ uncalibrated; 20 ⇒ calibrated.
        let stub = ConformalCalibrator.Pair(posterior: d, trueLabel: .neutral)
        if case let .uncalibrated(n) = ConformalCalibrator.calibrate(Array(repeating: stub, count: 19)) {
            assert(n == 19, "EmotionSelfTests: uncalibrated must carry the mappable-pair count")
        } else {
            assertionFailure("EmotionSelfTests: 19 pairs (< 20) must be .uncalibrated")
        }
        assert(ConformalCalibrator.calibrate(Array(repeating: stub, count: 20)).isCalibrated,
               "EmotionSelfTests: 20 pairs (= minSamples) must calibrate")

        // (b cont.) Seeded coverage: calibrate on N=40 synthetic 3-class posteriors, then
        //     assert empirical coverage on 200 held-out draws ≥ 1−α−slack (slack = 0.1,
        //     documented). Balanced classes (index-cycled), deterministic SeededGaussian.
        let classes: [Emotion] = [.neutral, .happiness, .sadness]
        let trueMean = 1.8, noise = 1.0
        func draw(index i: Int, rng: inout SeededGaussian) -> (EmotionDistribution, Emotion) {
            let y = classes[i % classes.count]
            var scores: [Emotion: Double] = [:]
            for c in classes { scores[c] = exp((c == y ? trueMean : 0) + noise * rng.next()) }
            return (EmotionDistribution(normalizing: scores), y)
        }
        var rng = SeededGaussian(seed: 0xE5_1AB0_C0FFEE)
        var calib: [ConformalCalibrator.Pair] = []
        for i in 0..<40 {
            let (p, y) = draw(index: i, rng: &rng)
            calib.append(ConformalCalibrator.Pair(posterior: p, trueLabel: y))
        }
        guard case let .calibrated(qhat, _) = ConformalCalibrator.calibrate(calib) else {
            assertionFailure("EmotionSelfTests: 40 pairs must calibrate")
            return
        }
        var covered = 0
        let testN = 200
        for i in 0..<testN {
            let (p, y) = draw(index: i, rng: &rng)
            if ConformalCalibrator.predict(p, qhat: qhat).contains(y) { covered += 1 }
        }
        let coverage = Double(covered) / Double(testN)
        let slack = 0.1
        assert(coverage >= 1 - ConformalCalibrator.alpha - slack,
               "EmotionSelfTests: conformal coverage \(coverage) below 1−α−slack (\(1 - ConformalCalibrator.alpha - slack))")
        print("   • US-E17 conformal coverage on 200 held-out draws: \(coverage) (target ≥ \(1 - ConformalCalibrator.alpha))")

        // (c) Label-mapping totality on the shipped quick-label set — every QuickMood maps
        //     to BOTH an Emotion (for conformal) and a distinct HKStateOfMind.Label (write).
        let documented: [QuickMood: Emotion] = [
            .calm: .neutral, .content: .happiness, .happy: .happiness, .surprised: .surprise,
            .sad: .sadness, .anxious: .fear, .frustrated: .anger, .angry: .anger]
        for mood in QuickMood.allCases {
            assert(mood.emotion != nil, "EmotionSelfTests: QuickMood \(mood) must map to an Emotion (totality)")
            assert(mood.emotion == documented[mood],
                   "EmotionSelfTests: QuickMood \(mood) emotion mapping drifted from the documented one")
        }
        assert(Set(QuickMood.allCases.map { HealthWriter.hkLabel(for: $0) }).count == QuickMood.allCases.count,
               "EmotionSelfTests: each QuickMood must map to a DISTINCT HKStateOfMind.Label")
        // primaryEmotion picks the first mappable label; empty labels ⇒ nil.
        assert(sampleReport(labels: ["frustrated", "happy"]).primaryEmotion == .anger,
               "EmotionSelfTests: primaryEmotion must be the first-selected mappable label")
        assert(sampleReport(labels: []).primaryEmotion == nil,
               "EmotionSelfTests: no labels ⇒ no primary emotion (excluded from calibration)")

        // (d) SelfReport JSONL round-trip — nil inferred fields, full fields, and a
        //     malformed middle line that must be skipped (append-only tolerance).
        let nilReport = SelfReport(
            t: Date(timeIntervalSinceReferenceDate: 555), valence: -0.3, labels: ["calm"],
            inferredValence: nil, inferredArousal: nil, inferredConfidence: nil,
            dominantEmotion: nil, inferredPosterior: nil, healthSaved: false)
        do {
            let back = EsmStore.parseReports(try EsmStore.encodeLine(nilReport))
            assert(back.count == 1, "EmotionSelfTests: a single report must round-trip to one record")
            let b = back[0]
            assert(b.id == nilReport.id && approx(b.valence, -0.3) && b.labels == ["calm"],
                   "EmotionSelfTests: report identity/valence/labels lost in JSONL round-trip")
            assert(b.inferredValence == nil && b.inferredArousal == nil && b.inferredConfidence == nil
                   && b.dominantEmotion == nil && b.inferredPosterior == nil && b.healthSaved == false,
                   "EmotionSelfTests: nil inferred fields must round-trip as nil")

            let dist = EmotionDistribution(normalizing: [.happiness: 0.6, .neutral: 0.4])
            let full = SelfReport(
                t: Date(timeIntervalSinceReferenceDate: 999), valence: 0.5,
                labels: ["happy", "content"], inferredValence: 0.42, inferredArousal: -0.1,
                inferredConfidence: 0.7, dominantEmotion: Emotion.happiness.rawValue,
                inferredPosterior: dist, healthSaved: true)
            let fb = EsmStore.parseReports(try EsmStore.encodeLine(full))
            assert(fb.count == 1 && approx(fb[0].inferredValence ?? .nan, 0.42)
                   && fb[0].inferredPosterior != nil && fb[0].dominantEmotion == "happiness"
                   && fb[0].healthSaved,
                   "EmotionSelfTests: full report (incl. posterior) must round-trip")

            var multi = try EsmStore.encodeLine(nilReport)
            multi.append(contentsOf: Data("this is not json\n".utf8))   // torn/garbage line
            multi.append(try EsmStore.encodeLine(full))
            assert(EsmStore.parseReports(multi).count == 2,
                   "EmotionSelfTests: a malformed line must be skipped, the valid ones kept")
        } catch {
            assertionFailure("EmotionSelfTests: SelfReport JSONL encode threw \(error)")
        }

        // (e) Prompt cooldown (PRD OQ14). Pure policy: eligible only ≥60 s after the shift
        //     AND ≥5 min since the last prompt.
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func at(_ s: Double) -> Date { t.addingTimeInterval(s) }
        assert(!EsmPromptPolicy.isEligible(shiftAt: nil, lastPromptAt: nil, now: t),
               "EmotionSelfTests: no shift ⇒ never eligible")
        assert(!EsmPromptPolicy.isEligible(shiftAt: t, lastPromptAt: nil, now: at(30)),
               "EmotionSelfTests: <60 s after a shift must not be eligible")
        assert(EsmPromptPolicy.isEligible(shiftAt: t, lastPromptAt: nil, now: at(60)),
               "EmotionSelfTests: eligible at exactly shift+60 s")
        // A second shift while the last prompt is <5 min old ⇒ suppressed.
        let promptAt = at(60), secondShift = at(120)
        assert(!EsmPromptPolicy.isEligible(shiftAt: secondShift, lastPromptAt: promptAt, now: at(180)),
               "EmotionSelfTests: a second shift within the 5 min prompt cooldown must be suppressed")
        assert(EsmPromptPolicy.isEligible(shiftAt: secondShift, lastPromptAt: promptAt, now: promptAt.addingTimeInterval(301)),
               "EmotionSelfTests: eligible again once >5 min past the last prompt")

        // (e cont.) EsmStore latches the FIRST shift and consumes it on surface (memory-only).
        let store = EsmStore(persistenceDirectory: nil)
        store.noteStateShift(at: t)
        store.noteStateShift(at: at(10))                 // ignored while one is pending (latched)
        assert(store.lastShiftAt == t, "EmotionSelfTests: the first shift must latch; later ones are ignored")
        assert(!store.shouldSurfacePrompt(now: at(30)), "EmotionSelfTests: <60 s ⇒ store not eligible")
        assert(store.shouldSurfacePrompt(now: at(70)), "EmotionSelfTests: ≥60 s + no prior prompt ⇒ eligible")
        store.notePromptSurfaced(at: at(70))
        assert(store.lastShiftAt == nil, "EmotionSelfTests: surfacing must consume the pending shift")
        assert(!store.shouldSurfacePrompt(now: at(80)), "EmotionSelfTests: no pending shift ⇒ not eligible")

        // (f) Honesty sweep: every new ESM/ground-truth string is banned-substring-clean.
        var sweep = [
            HonestyPhrases.selfReportManualButton, HonestyPhrases.selfReportBannerText,
            HonestyPhrases.selfReportBannerCTA, HonestyPhrases.selfReportBannerDismiss,
            HonestyPhrases.selfReportTitle, HonestyPhrases.selfReportSubtitle,
            HonestyPhrases.selfReportValencePrompt, HonestyPhrases.selfReportValenceLow,
            HonestyPhrases.selfReportValenceHigh, HonestyPhrases.selfReportLabelsPrompt,
            HonestyPhrases.selfReportSaveButton, HonestyPhrases.selfReportSavingButton,
            HonestyPhrases.selfReportHealthNote, HonestyPhrases.healthUnavailableReason,
            HonestyPhrases.healthDeniedReason, HonestyPhrases.healthSaveFailedReason,
            HonestyPhrases.groundTruthTitle, HonestyPhrases.groundTruthBlurb,
            HonestyPhrases.groundTruthEmpty, HonestyPhrases.groundTruthHealthSaved,
            HonestyPhrases.conformalLearning(have: 5, need: 20),
            HonestyPhrases.conformalCalibrated(sampleCount: 25),
            HonestyPhrases.groundTruthCCC(ccc: 0.52, pairedCount: 8),
            HonestyPhrases.groundTruthCCCNeedsMore(pairedCount: 2),
            HonestyPhrases.groundTruthHealthLocalOnly(reason: HonestyPhrases.healthDeniedReason),
        ]
        sweep += QuickMood.allCases.map(\.displayName)
        sweep += [-1.0, -0.5, 0.0, 0.5, 1.0].map(HonestyPhrases.valenceWord)
        for s in sweep {
            assert(!HonestyPhrases.containsBanned(s),
                   "EmotionSelfTests: ESM copy overclaims (banned substring): \(s)")
        }
    }

    /// Build a `SelfReport` with only the fields a mapping test needs (nil inferred snapshot).
    private static func sampleReport(labels: [String]) -> SelfReport {
        SelfReport(t: Date(timeIntervalSinceReferenceDate: 0), valence: 0, labels: labels,
                   inferredValence: nil, inferredArousal: nil, inferredConfidence: nil,
                   dominantEmotion: nil, inferredPosterior: nil, healthSaved: false)
    }
}
#endif
