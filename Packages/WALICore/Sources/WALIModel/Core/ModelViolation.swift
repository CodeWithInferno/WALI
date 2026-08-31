/// A stable, presentation-neutral explanation of a rejected model value or transition.
public struct ModelViolation: Error, Codable, Sendable, Hashable {
    /// Stable machine-readable violation codes.
    public enum Code: String, Codable, Sendable, Hashable {
        /// A typed UUID-shaped identifier was not canonical.
        case invalidIdentifier = "invalid_identifier"

        /// An open inert tag did not match its bounded ASCII grammar.
        case invalidTag = "invalid_tag"

        /// A content digest did not match its algorithm's lexical form.
        case invalidDigest = "invalid_digest"

        /// A schema version was structurally invalid.
        case invalidSchema = "invalid_schema"

        /// A record used a structurally valid but unsupported schema.
        case unsupportedSchema = "unsupported_schema"

        /// User text contained no non-whitespace content.
        case blankText = "blank_text"

        /// User text exceeded its UTF-8 bound.
        case textTooLong = "text_too_long"

        /// A numeric value was outside its domain.
        case invalidNumber = "invalid_number"

        /// A display fingerprint was not normalized or bounded.
        case invalidFingerprint = "invalid_fingerprint"

        /// A generation was not positive.
        case invalidGeneration = "invalid_generation"

        /// A required collection was empty.
        case emptyCollection = "empty_collection"

        /// One release repeated an artifact content identity.
        case duplicateArtifactID = "duplicate_artifact_id"

        /// One digest appeared with conflicting artifact metadata.
        case conflictingArtifactMetadata = "conflicting_artifact_metadata"

        /// One variant repeated a binding role.
        case duplicateArtifactRole = "duplicate_artifact_role"

        /// One release repeated a variant identity.
        case duplicateVariantID = "duplicate_variant_id"

        /// An encoded semantic set contained the same element more than once.
        case duplicateEncodedElement = "duplicate_encoded_element"

        /// A record referenced an element it did not contain.
        case missingReference = "missing_reference"

        /// A reducer input was not valid from the current lifecycle state.
        case invalidTransition = "invalid_transition"

        /// An asynchronous callback carried a future generation.
        case futureGeneration = "future_generation"

        /// A newly begun generation skipped the exact successor.
        case generationGap = "generation_gap"

        /// One attempt generation received two distinct terminal outcomes.
        case conflictingTerminalOutcome = "conflicting_terminal_outcome"

        /// A reducer input attempted to reopen or change a terminal job.
        case terminalJob = "terminal_job"

        /// Decoded fields formed an impossible lifecycle combination.
        case invalidCombination = "invalid_combination"
    }

    /// Structured context that callers may map to diagnostics or localized presentation.
    public struct Context: Codable, Sendable, Hashable {
        /// Stable field or axis associated with the violation.
        public let field: String

        /// Stable operation tag when the violation arose from a reducer input.
        public let operation: String?

        /// Supplied generation when generation ordering is relevant.
        public let generation: UInt64?

        /// Required generation when generation ordering is relevant.
        public let expectedGeneration: UInt64?

        /// Creates structured violation context.
        public init(
            field: String,
            operation: String? = nil,
            generation: UInt64? = nil,
            expectedGeneration: UInt64? = nil
        ) {
            self.field = field
            self.operation = operation
            self.generation = generation
            self.expectedGeneration = expectedGeneration
        }
    }

    /// Stable violation code.
    public let code: Code

    /// Structured, nonlocalized context.
    public let context: Context

    /// Creates a model violation.
    public init(code: Code, context: Context) {
        self.code = code
        self.context = context
    }
}

package func modelViolation(
    _ code: ModelViolation.Code,
    field: String,
    operation: String? = nil,
    generation: UInt64? = nil,
    expectedGeneration: UInt64? = nil
) -> ModelViolation {
    ModelViolation(
        code: code,
        context: ModelViolation.Context(
            field: field,
            operation: operation,
            generation: generation,
            expectedGeneration: expectedGeneration
        )
    )
}
