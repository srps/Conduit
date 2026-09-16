// SPDX-License-Identifier: Apache-2.0
import Foundation

extension String {
    /// Text of a NUL-terminated `CChar` buffer filled by a C API, decoded as
    /// UTF-8 with repair. The array form of `String(cString:)` is deprecated.
    init(nulTerminated buffer: [CChar]) {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        self.init(decoding: bytes, as: UTF8.self)
    }
}
