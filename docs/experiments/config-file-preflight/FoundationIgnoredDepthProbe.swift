// SPDX-License-Identifier: Apache-2.0
import Foundation
struct Root: Decodable { let profileName: String }
for depth in [64, 128, 256, 510, 511, 512, 513, 1024, 4096] {
    let source = "{\"profileName\":\"probe\",\"ignored\":" + String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth) + "}"
    let data = Data(source.utf8)
    do {
        let value = try JSONDecoder().decode(Root.self, from: data)
        print("depth=\(depth) accepted=\(value.profileName == "probe") bytes=\(data.count)")
    } catch {
        print("depth=\(depth) accepted=false bytes=\(data.count)")
    }
}
