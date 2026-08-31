package let openTagMaximumUTF8Length = 64
package let fingerprintMaximumUTF8Length = 128

package func validateCanonicalUUIDString(_ value: String, field: String) throws {
    let bytes = Array(value.utf8)
    guard bytes.count == 36 else {
        throw modelViolation(.invalidIdentifier, field: field)
    }

    let hyphenOffsets = [8, 13, 18, 23]
    for index in bytes.indices {
        if hyphenOffsets.contains(index) {
            guard bytes[index] == 45 else {
                throw modelViolation(.invalidIdentifier, field: field)
            }
        } else if !isLowercaseHex(bytes[index]) {
            throw modelViolation(.invalidIdentifier, field: field)
        }
    }
}

package func validateOpenTag(_ value: String, field: String) throws {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty,
          bytes.count <= openTagMaximumUTF8Length,
          bytes.contains(46),
          isLowercaseASCIIAlphaNumeric(bytes[0]),
          isLowercaseASCIIAlphaNumeric(bytes[bytes.count - 1])
    else {
        throw modelViolation(.invalidTag, field: field)
    }

    var previousWasSeparator = false
    for byte in bytes {
        if isLowercaseASCIIAlphaNumeric(byte) {
            previousWasSeparator = false
        } else if byte == 46 || byte == 45 {
            guard !previousWasSeparator else {
                throw modelViolation(.invalidTag, field: field)
            }
            previousWasSeparator = true
        } else {
            throw modelViolation(.invalidTag, field: field)
        }
    }
}

package func validateFingerprint(_ value: String, field: String) throws {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty,
          bytes.count <= fingerprintMaximumUTF8Length,
          isLowercaseASCIIAlphaNumeric(bytes[0]),
          isLowercaseASCIIAlphaNumeric(bytes[bytes.count - 1])
    else {
        throw modelViolation(.invalidFingerprint, field: field)
    }

    for byte in bytes {
        guard isLowercaseASCIIAlphaNumeric(byte)
                || byte == 46
                || byte == 95
                || byte == 58
                || byte == 45
        else {
            throw modelViolation(.invalidFingerprint, field: field)
        }
    }
}

package func validateBoundedNonblankText(
    _ value: String,
    maximumUTF8Length: Int,
    field: String
) throws {
    guard value.utf8.count <= maximumUTF8Length else {
        throw modelViolation(.textTooLong, field: field)
    }
    guard !value.isEmpty, value.contains(where: { !$0.isWhitespace }) else {
        throw modelViolation(.blankText, field: field)
    }
}

package func isLowercaseHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...102).contains(byte)
}

package func isLowercaseASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...122).contains(byte)
}
