import Foundation
import Testing
@testable import WALIModel

@Suite("Playback reducer")
struct PlaybackReducerTests {
    @Test("Ready replacement waits for an explicit first-frame commit")
    func firstFrameGate() throws {
        var state = try playbackState()
        let generation = try PlaybackGeneration(1)

        var transition = try PlaybackReducer.reduce(
            state,
            .beginReplacement(generation: generation, selection: playbackSelection())
        )
        #expect(transition.disposition == .applied)
        #expect(transition.state.replacementStatus == .requested(generation))
        #expect(transition.state.effectiveMode == .preparing)

        state = transition.state
        transition = try PlaybackReducer.reduce(state, .preparationStarted(generation: generation))
        #expect(transition.state.replacementStatus == .preparing(generation))

        state = transition.state
        transition = try PlaybackReducer.reduce(state, .preparationReady(generation: generation))
        #expect(transition.state.activePlayback == nil)
        #expect(transition.state.replacementStatus == .ready(generation))
        #expect(transition.state.effectiveMode == .preparing)

        let duplicate = try PlaybackReducer.reduce(
            transition.state,
            .preparationReady(generation: generation)
        )
        #expect(duplicate.disposition == .duplicate)

        transition = try PlaybackReducer.reduce(
            transition.state,
            .commitReplacement(generation: generation)
        )
        #expect(transition.state.activePlayback?.generation == generation)
        #expect(transition.state.activePlayback?.selection == (try playbackSelection()))
        #expect(transition.state.replacementStatus == .none)
        #expect(transition.state.effectiveMode == .playing)
    }

    @Test("Generation checks distinguish duplicate, stale, gap, and future events")
    func generationChecks() throws {
        let first = try PlaybackGeneration(1)
        let second = try PlaybackGeneration(2)
        let third = try PlaybackGeneration(3)
        var state = try committedPlayback(generation: first)

        let duplicateCommit = try PlaybackReducer.reduce(
            state,
            .commitReplacement(generation: first)
        )
        #expect(duplicateCommit.disposition == .duplicate)

        var transition = try PlaybackReducer.reduce(
            state,
            .beginReplacement(generation: second, selection: alternatePlaybackSelection())
        )
        state = transition.state

        let oldCallback = try PlaybackReducer.reduce(
            state,
            .preparationFailed(generation: first)
        )
        #expect(oldCallback.disposition == .stale)
        #expect(oldCallback.state == state)

        expectViolation(.futureGeneration) {
            _ = try PlaybackReducer.reduce(
                state,
                .preparationFailed(generation: third)
            )
        }

        state = try committedPlayback(generation: first)
        expectViolation(.generationGap) {
            _ = try PlaybackReducer.reduce(
                state,
                .beginReplacement(generation: third, selection: alternatePlaybackSelection())
            )
        }

        transition = try PlaybackReducer.reduce(
            state,
            .beginReplacement(generation: second, selection: alternatePlaybackSelection())
        )
        let repeatedBegin = try PlaybackReducer.reduce(
            transition.state,
            .beginReplacement(generation: second, selection: alternatePlaybackSelection())
        )
        #expect(repeatedBegin.disposition == .duplicate)
    }

    @Test("Failed replacement preserves an already active wallpaper")
    func replacementFailurePreservesActive() throws {
        let first = try PlaybackGeneration(1)
        let second = try PlaybackGeneration(2)
        let oldActive = try #require(try committedPlayback(generation: first).activePlayback)
        var state = try committedPlayback(generation: first)

        state = try PlaybackReducer.reduce(
            state,
            .beginReplacement(generation: second, selection: alternatePlaybackSelection())
        ).state
        state = try PlaybackReducer.reduce(
            state,
            .preparationStarted(generation: second)
        ).state
        state = try PlaybackReducer.reduce(
            state,
            .preparationFailed(generation: second)
        ).state

        #expect(state.activePlayback == oldActive)
        #expect(state.failure?.scope == .replacementOnly)
        #expect(state.failure?.generation == second)
        #expect(state.replacementPreparation == nil)
        #expect(state.replacementStatus == .failed(second))
        #expect(state.effectiveMode == .playing)
    }

    @Test("Failure blocks playback only when no active wallpaper exists")
    func blockingFailure() throws {
        let first = try PlaybackGeneration(1)
        var state = try playbackState()
        state = try PlaybackReducer.reduce(
            state,
            .beginReplacement(generation: first, selection: playbackSelection())
        ).state
        state = try PlaybackReducer.reduce(
            state,
            .preparationFailed(generation: first)
        ).state

        #expect(state.activePlayback == nil)
        #expect(state.failure?.scope == .blocking)
        #expect(state.effectiveMode == .blockingFailure)
    }

    @Test("User pause and automatic reasons compose orthogonally")
    func pauseComposition() throws {
        var state = try committedPlayback(generation: PlaybackGeneration(1))
        state = try PlaybackReducer.reduce(state, .setUserPause(true)).state
        state = try PlaybackReducer.reduce(
            state,
            .setAutomaticReason(.systemSleep, present: true)
        ).state
        state = try PlaybackReducer.reduce(
            state,
            .setAutomaticReason(.displayAsleep, present: true)
        ).state
        #expect(state.effectiveMode == .userPaused)

        state = try PlaybackReducer.reduce(state, .setUserPause(false)).state
        #expect(state.effectiveMode == .automaticallyPaused)

        state = try PlaybackReducer.reduce(
            state,
            .setAutomaticReason(.systemSleep, present: false)
        ).state
        #expect(state.effectiveMode == .automaticallyPaused)

        state = try PlaybackReducer.reduce(
            state,
            .setAutomaticReason(.displayAsleep, present: false)
        ).state
        #expect(state.effectiveMode == .playing)
    }

    @Test("Unknown valid automatic reason is preserved and conservatively pauses")
    func unknownPauseReason() throws {
        let unknown = try AutomaticPauseReasonID("vendor.future-reason")
        var state = try committedPlayback(generation: PlaybackGeneration(1))
        state = try PlaybackReducer.reduce(
            state,
            .setAutomaticReason(unknown, present: true)
        ).state

        #expect(state.automaticPauseReasons == [unknown])
        #expect(state.effectiveMode == .automaticallyPaused)

        let decoded = try JSONDecoder().decode(
            PlaybackState.self,
            from: JSONEncoder().encode(state)
        )
        #expect(decoded == state)
        #expect(decoded.automaticPauseReasons == [unknown])
    }

    @Test("Pause changes never destroy replacement preparation")
    func pausePreservesPreparation() throws {
        let first = try PlaybackGeneration(1)
        var state = try playbackState()
        state = try PlaybackReducer.reduce(
            state,
            .beginReplacement(generation: first, selection: playbackSelection())
        ).state
        let replacement = state.replacementPreparation

        state = try PlaybackReducer.reduce(state, .setUserPause(true)).state
        state = try PlaybackReducer.reduce(
            state,
            .setAutomaticReason(.thermalPressure, present: true)
        ).state

        #expect(state.replacementPreparation == replacement)
    }

    @Test("Stopped mode has precedence over failure and pauses")
    func stoppedPrecedence() throws {
        let first = try PlaybackGeneration(1)
        var state = try playbackState()
        state = try PlaybackReducer.reduce(
            state,
            .beginReplacement(generation: first, selection: playbackSelection())
        ).state
        state = try PlaybackReducer.reduce(
            state,
            .preparationFailed(generation: first)
        ).state
        state = try PlaybackReducer.reduce(state, .setUserPause(true)).state
        state = try PlaybackReducer.reduce(state, .setDesiredRunning(false)).state

        #expect(state.effectiveMode == .stopped)
    }

    @Test("Semantic pause set encodes sorted and rejects duplicate encoded elements")
    func pauseSetCoding() throws {
        let first = try AutomaticPauseReasonID("vendor.zeta")
        let second = try AutomaticPauseReasonID("vendor.alpha")
        let state = try PlaybackState(
            schema: .current,
            desiredRunning: true,
            userPaused: false,
            automaticPauseReasons: [first, second],
            selectedQuality: .balanced,
            activePlayback: nil,
            replacementPreparation: nil,
            failure: nil
        )
        let encoded = try logicalJSON(state)
        #expect(
            encoded.contains(
                "\"automaticPauseReasons\":[\"vendor.alpha\",\"vendor.zeta\"]"
            )
        )

        let duplicate = encoded.replacingOccurrences(
            of: "[\"vendor.alpha\",\"vendor.zeta\"]",
            with: "[\"vendor.alpha\",\"vendor.alpha\"]"
        )
        expectViolation(.duplicateEncodedElement) {
            _ = try JSONDecoder().decode(
                PlaybackState.self,
                from: Data(duplicate.utf8)
            )
        }

        let invalidFixture = try #require(
            JSONSerialization.jsonObject(
                with: fixtureData(named: "model-records-invalid-v1")
            ) as? [String: Any]
        )
        let fixtureRecord = try JSONSerialization.data(
            withJSONObject: try #require(invalidFixture["duplicatePauseReasons"])
        )
        expectViolation(.duplicateEncodedElement) {
            _ = try JSONDecoder().decode(PlaybackState.self, from: fixtureRecord)
        }

        for (key, type) in [
            ("invalidReplacementPreparation", ReplacementPreparation.self as any Decodable.Type),
            ("invalidPlaybackInput", PlaybackInput.self as any Decodable.Type)
        ] {
            let data = try JSONSerialization.data(
                withJSONObject: try #require(invalidFixture[key])
            )
            expectViolation(.invalidCombination) {
                _ = try JSONDecoder().decode(type, from: data)
            }
        }
    }

    @Test("Associated playback lifecycle inputs use explicit stable tags")
    func inputTags() throws {
        let input = PlaybackInput.beginReplacement(
            generation: try PlaybackGeneration(1),
            selection: try playbackSelection()
        )
        #expect(
            try logicalJSON(input)
                == "{\"generation\":1,\"selection\":{\"releaseID\":\"\(releaseIDText)\",\"variantID\":\"\(variantIDText)\"},\"tag\":\"begin_replacement\"}"
        )
    }

    @Test("Golden playback fixture round trips")
    func playbackFixture() throws {
        let fixture = try JSONDecoder().decode(
            PlaybackFixture.self,
            from: fixtureData(named: "model-records-v1")
        )
        let roundTrip = try JSONDecoder().decode(
            PlaybackState.self,
            from: JSONEncoder().encode(fixture.playbackState)
        )
        #expect(roundTrip == fixture.playbackState)
        #expect(roundTrip.schema == .current)
    }
}

private struct PlaybackFixture: Decodable {
    let playbackState: PlaybackState
}

private func playbackSelection() throws -> PlaybackSelection {
    try PlaybackSelection(
        releaseID: AssetReleaseID(releaseIDText),
        variantID: AssetVariantID(variantIDText)
    )
}

private func alternatePlaybackSelection() throws -> PlaybackSelection {
    try PlaybackSelection(
        releaseID: AssetReleaseID(alternateReleaseIDText),
        variantID: AssetVariantID(alternateVariantIDText)
    )
}

private func playbackState() throws -> PlaybackState {
    try PlaybackState(
        schema: .current,
        desiredRunning: true,
        userPaused: false,
        automaticPauseReasons: [],
        selectedQuality: .balanced,
        activePlayback: nil,
        replacementPreparation: nil,
        failure: nil
    )
}

private func committedPlayback(generation: PlaybackGeneration) throws -> PlaybackState {
    var state = try playbackState()
    state = try PlaybackReducer.reduce(
        state,
        .beginReplacement(generation: generation, selection: playbackSelection())
    ).state
    state = try PlaybackReducer.reduce(
        state,
        .preparationStarted(generation: generation)
    ).state
    state = try PlaybackReducer.reduce(
        state,
        .preparationReady(generation: generation)
    ).state
    return try PlaybackReducer.reduce(
        state,
        .commitReplacement(generation: generation)
    ).state
}
