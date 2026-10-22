import SwiftUI

// MARK: - Ring Typography System

public extension Font {
    enum Ring {
        /// Title - SF Pro 13pt Semibold (popover headers)
        public static let title = Font.system(size: 13, weight: .semibold)

        /// Headline - SF Pro 12pt Medium (section headers)
        public static let headline = Font.system(size: 12, weight: .medium)

        /// Body - SF Pro 12pt Regular (primary text)
        public static let body = Font.system(size: 12, weight: .regular)

        /// Caption - SF Pro 11pt Regular (secondary info)
        public static let caption = Font.system(size: 11, weight: .regular)

        /// Timestamp - SF Mono 11pt Regular (times, IDs)
        public static let timestamp = Font.system(size: 11, weight: .regular, design: .monospaced)

        /// Mono - SF Mono 11pt Medium (device names in events)
        public static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)

        /// Small - SF Pro 10pt Regular (badges, minor labels)
        public static let small = Font.system(size: 10, weight: .regular)
    }
}
