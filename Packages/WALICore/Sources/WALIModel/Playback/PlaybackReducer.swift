/// Pure package-scoped playback reducer used by WALIEngine.
package enum PlaybackReducer {
    /// Applies one input or returns an expected race disposition.
    package static func reduce(
        _ state: PlaybackState,
        _ input: PlaybackInput
    ) throws -> PlaybackTransition {
        switch input {
        case let .beginReplacement(generation, selection):
            return try beginReplacement(state, generation: generation, selection: selection)
        case let .preparationStarted(generation):
            return try preparationStarted(state, generation: generation)
        case let .preparationReady(generation):
            return try preparationReady(state, generation: generation)
        case let .commitReplacement(generation):
            return try commitReplacement(state, generation: generation)
        case let .preparationFailed(generation):
            return try preparationFailed(state, generation: generation)
        case let .setDesiredRunning(desiredRunning):
            guard desiredRunning != state.desiredRunning else {
                return PlaybackTransition(state: state, disposition: .duplicate)
            }
            return PlaybackTransition(
                state: try PlaybackState(
                    schema: state.schema,
                    desiredRunning: desiredRunning,
                    userPaused: state.userPaused,
                    automaticPauseReasons: state.automaticPauseReasons,
                    selectedQuality: state.selectedQuality,
                    activePlayback: state.activePlayback,
                    replacementPreparation: state.replacementPreparation,
                    failure: state.failure
                ),
                disposition: .applied
            )
        case let .setUserPause(userPaused):
            guard userPaused != state.userPaused else {
                return PlaybackTransition(state: state, disposition: .duplicate)
            }
            return PlaybackTransition(
                state: try PlaybackState(
                    schema: state.schema,
                    desiredRunning: state.desiredRunning,
                    userPaused: userPaused,
                    automaticPauseReasons: state.automaticPauseReasons,
                    selectedQuality: state.selectedQuality,
                    activePlayback: state.activePlayback,
                    replacementPreparation: state.replacementPreparation,
                    failure: state.failure
                ),
                disposition: .applied
            )
        case let .setAutomaticReason(reason, present):
            var reasons = state.automaticPauseReasons
            let contains = reasons.contains(reason)
            guard contains != present else {
                return PlaybackTransition(state: state, disposition: .duplicate)
            }
            if present {
                reasons.append(reason)
            } else {
                reasons.removeAll { $0 == reason }
            }
            return PlaybackTransition(
                state: try PlaybackState(
                    schema: state.schema,
                    desiredRunning: state.desiredRunning,
                    userPaused: state.userPaused,
                    automaticPauseReasons: reasons,
                    selectedQuality: state.selectedQuality,
                    activePlayback: state.activePlayback,
                    replacementPreparation: state.replacementPreparation,
                    failure: state.failure
                ),
                disposition: .applied
            )
        }
    }

    private static func beginReplacement(
        _ state: PlaybackState,
        generation: PlaybackGeneration,
        selection: PlaybackSelection
    ) throws -> PlaybackTransition {
        if let replacement = state.replacementPreparation,
           replacement.generation == generation {
            guard replacement.selection == selection else {
                throw violation(
                    .invalidTransition,
                    field: "playback.replacementSelection",
                    input: .beginReplacement(generation: generation, selection: selection),
                    generation: generation
                )
            }
            return PlaybackTransition(state: state, disposition: .duplicate)
        }

        let latest = state.latestGeneration?.rawValue ?? 0
        if generation.rawValue <= latest {
            return PlaybackTransition(state: state, disposition: .stale)
        }
        guard state.replacementPreparation == nil else {
            throw violation(
                .invalidTransition,
                field: "playback.replacementPreparation",
                input: .beginReplacement(generation: generation, selection: selection),
                generation: generation
            )
        }
        guard latest < UInt64.max else {
            throw violation(
                .generationGap,
                field: "playback.generation",
                input: .beginReplacement(generation: generation, selection: selection),
                generation: generation
            )
        }
        let expected = latest + 1
        guard generation.rawValue == expected else {
            throw violation(
                .generationGap,
                field: "playback.generation",
                input: .beginReplacement(generation: generation, selection: selection),
                generation: generation,
                expected: expected
            )
        }

        return PlaybackTransition(
            state: try lifecycleState(
                state,
                activePlayback: state.activePlayback,
                replacement: .requested(generation: generation, selection: selection),
                failure: nil
            ),
            disposition: .applied
        )
    }

    private static func preparationStarted(
        _ state: PlaybackState,
        generation: PlaybackGeneration
    ) throws -> PlaybackTransition {
        guard let replacement = state.replacementPreparation else {
            return try absentReplacementDisposition(state, generation: generation, input: .preparationStarted(generation: generation))
        }
        guard try isCurrent(
            generation,
            replacement: replacement,
            input: .preparationStarted(generation: generation)
        ) else {
            return PlaybackTransition(state: state, disposition: .stale)
        }
        switch replacement {
        case let .requested(_, selection):
            return PlaybackTransition(
                state: try lifecycleState(
                    state,
                    activePlayback: state.activePlayback,
                    replacement: .preparing(generation: generation, selection: selection),
                    failure: nil
                ),
                disposition: .applied
            )
        case .preparing, .ready:
            return PlaybackTransition(state: state, disposition: .duplicate)
        }
    }

    private static func preparationReady(
        _ state: PlaybackState,
        generation: PlaybackGeneration
    ) throws -> PlaybackTransition {
        guard let replacement = state.replacementPreparation else {
            return try absentReplacementDisposition(state, generation: generation, input: .preparationReady(generation: generation))
        }
        guard try isCurrent(
            generation,
            replacement: replacement,
            input: .preparationReady(generation: generation)
        ) else {
            return PlaybackTransition(state: state, disposition: .stale)
        }
        switch replacement {
        case .requested:
            throw violation(
                .invalidTransition,
                field: "playback.replacementPreparation",
                input: .preparationReady(generation: generation),
                generation: generation
            )
        case let .preparing(_, selection):
            return PlaybackTransition(
                state: try lifecycleState(
                    state,
                    activePlayback: state.activePlayback,
                    replacement: .ready(
                        PreparedPlayback(generation: generation, selection: selection)
                    ),
                    failure: nil
                ),
                disposition: .applied
            )
        case .ready:
            return PlaybackTransition(state: state, disposition: .duplicate)
        }
    }

    private static func commitReplacement(
        _ state: PlaybackState,
        generation: PlaybackGeneration
    ) throws -> PlaybackTransition {
        guard let replacement = state.replacementPreparation else {
            if state.activePlayback?.generation == generation {
                return PlaybackTransition(state: state, disposition: .duplicate)
            }
            return try absentReplacementDisposition(state, generation: generation, input: .commitReplacement(generation: generation))
        }
        guard try isCurrent(
            generation,
            replacement: replacement,
            input: .commitReplacement(generation: generation)
        ) else {
            return PlaybackTransition(state: state, disposition: .stale)
        }
        guard case let .ready(playback) = replacement else {
            throw violation(
                .invalidTransition,
                field: "playback.replacementPreparation",
                input: .commitReplacement(generation: generation),
                generation: generation
            )
        }
        return PlaybackTransition(
            state: try lifecycleState(
                state,
                activePlayback: playback,
                replacement: nil,
                failure: nil
            ),
            disposition: .applied
        )
    }

    private static func preparationFailed(
        _ state: PlaybackState,
        generation: PlaybackGeneration
    ) throws -> PlaybackTransition {
        guard let replacement = state.replacementPreparation else {
            if state.failure?.generation == generation {
                return PlaybackTransition(state: state, disposition: .duplicate)
            }
            return try absentReplacementDisposition(state, generation: generation, input: .preparationFailed(generation: generation))
        }
        guard try isCurrent(
            generation,
            replacement: replacement,
            input: .preparationFailed(generation: generation)
        ) else {
            return PlaybackTransition(state: state, disposition: .stale)
        }
        let failure = PlaybackFailure(
            generation: generation,
            scope: state.activePlayback == nil ? .blocking : .replacementOnly
        )
        return PlaybackTransition(
            state: try lifecycleState(
                state,
                activePlayback: state.activePlayback,
                replacement: nil,
                failure: failure
            ),
            disposition: .applied
        )
    }

    private static func absentReplacementDisposition(
        _ state: PlaybackState,
        generation: PlaybackGeneration,
        input: PlaybackInput
    ) throws -> PlaybackTransition {
        let latest = state.latestGeneration?.rawValue ?? 0
        if generation.rawValue <= latest {
            return PlaybackTransition(state: state, disposition: .stale)
        }
        throw violation(
            .futureGeneration,
            field: "playback.generation",
            input: input,
            generation: generation,
            expected: latest
        )
    }

    private static func isCurrent(
        _ generation: PlaybackGeneration,
        replacement: ReplacementPreparation,
        input: PlaybackInput
    ) throws -> Bool {
        if generation.rawValue < replacement.generation.rawValue {
            return false
        }
        guard generation == replacement.generation else {
            throw violation(
                .futureGeneration,
                field: "playback.generation",
                input: input,
                generation: generation,
                expected: replacement.generation.rawValue
            )
        }
        return true
    }

    private static func lifecycleState(
        _ state: PlaybackState,
        activePlayback: PreparedPlayback?,
        replacement: ReplacementPreparation?,
        failure: PlaybackFailure?
    ) throws -> PlaybackState {
        try PlaybackState(
            schema: state.schema,
            desiredRunning: state.desiredRunning,
            userPaused: state.userPaused,
            automaticPauseReasons: state.automaticPauseReasons,
            selectedQuality: state.selectedQuality,
            activePlayback: activePlayback,
            replacementPreparation: replacement,
            failure: failure
        )
    }

    private static func violation(
        _ code: ModelViolation.Code,
        field: String,
        input: PlaybackInput,
        generation: PlaybackGeneration,
        expected: UInt64? = nil
    ) -> ModelViolation {
        modelViolation(
            code,
            field: field,
            operation: input.operationTag,
            generation: generation.rawValue,
            expectedGeneration: expected
        )
    }
}
