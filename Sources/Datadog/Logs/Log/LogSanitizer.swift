/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation

/// Sanitizes `Log` representation received from the user, so it can match Datadog log constraints.
internal struct LogSanitizer {
    struct Constraints {
        /// Attribute names reserved for Datadog.
        /// If any of those is used by user, the attribute will be ignored.
        static let reservedAttributeNames: Set<String> = [
            "host", "message", "status", "service", "source", "error.kind", "error.message", "error.stack", "ddtags"
        ]
        /// Maximum number of nested levels in attribute name. E.g. `person.address.street` has 3 levels.
        /// If attribute name exceeds this number, extra levels are escaped by using `_` character (`one.two.(...).nine.ten_eleven_twelve`).
        static let maxNestedLevelsInAttributeName: Int = 9
        /// Maximum number of attributes in log.
        /// If this number is exceeded, extra attributes will be ignored.
        static let maxNumberOfAttributes: Int = 256
        /// Allowed first character of a tag name (given as ASCII values ranging from lowercased `a` to `z`) .
        /// Tags with name starting with different character will be dropped.
        static let allowedTagNameFirstCharacterASCIIRange: [UInt8] = Array(97...122)
        /// Maximum lenght of the tag.
        /// Tags exceeting this lenght will be trunkated.
        static let maxTagLength: Int = 200
        /// Tag keys reserved for Datadog.
        /// If any of those is used by user, the tag will be ignored.
        static let reservedTagKeys: Set<String> = [
            "host", "device", "source", "service"
        ]
        /// Maximum number of attributes in log.
        /// If this number is exceeded, extra attributes will be ignored.
        static let maxNumberOfTags: Int = 100
    }

    func sanitize(log: Log) -> Log {
        return Log(
            date: log.date,
            status: log.status,
            message: log.message,
            serviceName: log.serviceName,
            loggerName: log.loggerName,
            loggerVersion: log.loggerVersion,
            threadName: log.threadName,
            applicationVersion: log.applicationVersion,
            userInfo: log.userInfo,
            networkConnectionInfo: log.networkConnectionInfo,
            mobileCarrierInfo: log.mobileCarrierInfo,
            attributes: sanitize(attributes: log.attributes),
            tags: sanitize(tags: log.tags)
        )
    }

    // MARK: - Attributes sanitization

    private func sanitize(attributes rawAttributes: [String: EncodableValue]?) -> [String: EncodableValue]? {
        if let rawAttributes = rawAttributes {
            var attributes = removeInvalidAttributes(rawAttributes)
            attributes = removeReservedAttributes(attributes)
            attributes = sanitizeAttributeNames(attributes)
            attributes = limitToMaxNumberOfAttributes(attributes)
            return attributes
        } else {
            return nil
        }
    }

    private func removeInvalidAttributes(_ attributes: [String: EncodableValue]) -> [String: EncodableValue] {
        // Attribute name cannot be empty
        return attributes.filter { attribute in
            if attribute.key.isEmpty {
                userLogger.error("Attribute key is empty. This attribute will be ignored.")
                return false
            }
            return true
        }
    }

    private func removeReservedAttributes(_ attributes: [String: EncodableValue]) -> [String: EncodableValue] {
        return attributes.filter { attribute in
            if Constraints.reservedAttributeNames.contains(attribute.key) {
                userLogger.error("'\(attribute.key)' is a reserved attribute name. This attribute will be ignored.")
                return false
            }
            return true
        }
    }

    private func sanitizeAttributeNames(_ attributes: [String: EncodableValue]) -> [String: EncodableValue] {
        let sanitizedAttributes: [(String, EncodableValue)] = attributes.map { name, value in
            let sanitizedName = sanitize(attributeName: name)
            if sanitizedName != name {
                userLogger.error("Attribute '\(name)' was modified to '\(sanitizedName)' to match Datadog constraints.")
                return (sanitizedName, value)
            } else {
                return (name, value)
            }
        }
        return Dictionary(uniqueKeysWithValues: sanitizedAttributes)
    }

    private func sanitize(attributeName: String) -> String {
        // Attribute name can only have `Constants.maxNestedLevelsInAttributeName` levels. Escape extra levels with "_".
        var dotsCount = 0
        var sanitized = ""
        for char in attributeName {
            if char == "." {
                dotsCount += 1
                sanitized.append(dotsCount > Constraints.maxNestedLevelsInAttributeName ? "_" : char)
            } else {
                sanitized.append(char)
            }
        }
        return sanitized
    }

    private func limitToMaxNumberOfAttributes(_ attributes: [String: EncodableValue]) -> [String: EncodableValue] {
        // Only `Constants.maxNumberOfAttributes` of attributes are allowed.
        if attributes.count > Constraints.maxNumberOfAttributes {
            let extraAttributesCount = attributes.count - Constraints.maxNumberOfAttributes
            userLogger.error("Number of attributes exceeds the limit of \(Constraints.maxNumberOfAttributes). \(extraAttributesCount) attribute(s) will be ignored.")
            return Dictionary(uniqueKeysWithValues: attributes.dropLast(extraAttributesCount))
        } else {
            return attributes
        }
    }

    // MARK: - Tags sanitization

    private func sanitize(tags rawTags: [String]?) -> [String]? {
        if let rawTags = rawTags {
            let tags = rawTags
                .map { $0.lowercased() }
                .filter { startsWithAllowedCharacter(tag: $0) }
                .map { replaceIllegalCharactersIn(tag: $0) }
                .map { removeTrailingCommasIn(tag: $0) }
                .map { limitToMaxLength(tag: $0) }
                .filter { isNotReserved(tag: $0) }
            return limitToMaxNumberOfTags(tags)
        } else {
            return nil
        }
    }

    private func startsWithAllowedCharacter(tag: String) -> Bool {
        guard let firstCharacter = tag.first?.asciiValue else {
            userLogger.error("Tag is empty and will be ignored.")
            return false
        }

        // Tag must start with a letter
        if Constraints.allowedTagNameFirstCharacterASCIIRange.contains(firstCharacter) {
            return true
        } else {
            userLogger.error("Tag '\(tag)' starts with an invalid character and will be ignored.")
            return false
        }
    }

    private func replaceIllegalCharactersIn(tag: String) -> String {
        let sanitized = tag.replacingOccurrences(of: #"[^a-z0-9_:.\/-]"#, with: "_", options: .regularExpression)
        if sanitized != tag {
            userLogger.warn("Tag '\(tag)' was modified to '\(sanitized)' to match Datadog constraints.")
        }
        return sanitized
    }

    private func removeTrailingCommasIn(tag: String) -> String {
        // If present, remove trailing commas `:`
        var sanitized = tag
        while sanitized.last == ":" { _ = sanitized.removeLast() }
        if sanitized != tag {
            userLogger.warn("Tag '\(tag)' was modified to '\(sanitized)' to match Datadog constraints.")
        }
        return sanitized
    }

    private func limitToMaxLength(tag: String) -> String {
        if tag.count > Constraints.maxTagLength {
            let sanitized = String(tag.prefix(Constraints.maxTagLength))
            userLogger.warn("Tag '\(tag)' was modified to '\(sanitized)' to match Datadog constraints.")
            return sanitized
        } else {
            return tag
        }
    }

    private func isNotReserved(tag: String) -> Bool {
        if let colonIndex = tag.firstIndex(of: ":") {
            let key = String(tag.prefix(upTo: colonIndex))
            if Constraints.reservedTagKeys.contains(key) {
                userLogger.error("'\(key)' is a reserved tag key. This tag will be ignored.")
                return false
            } else {
                return true
            }
        } else {
            return true
        }
    }

    private func limitToMaxNumberOfTags(_ tags: [String]) -> [String] {
        // Only `Constraints.maxNumberOfTags` of tags are allowed.
        if tags.count > Constraints.maxNumberOfTags {
            let extraTagsCount = tags.count - Constraints.maxNumberOfTags
            userLogger.error("Number of tags exceeds the limit of \(Constraints.maxNumberOfTags). \(extraTagsCount) attribute(s) will be ignored.")
            return tags.dropLast(extraTagsCount)
        } else {
            return tags
        }
    }
}
