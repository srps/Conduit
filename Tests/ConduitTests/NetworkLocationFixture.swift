// SPDX-License-Identifier: Apache-2.0
import PlatformMac
import ConduitShared

enum NetworkLocationFixture {
    static let home = "11111111-1111-1111-1111-111111111111"
    static let office = "22222222-2222-2222-2222-222222222222"
    static func store() -> FakeNetworkLocationStore {
        FakeNetworkLocationStore(snapshot: .init(activeLocationID: home, services: [
            .init(locationID: home, serviceID: "33333333-3333-3333-3333-333333333333", name: "Wi-Fi", enabled: true,
                  proxies: ["HTTPProxy": .text("home.example"), "HTTPPort": .number(8080), "HTTPEnable": .number(1)],
                  dns: ["ServerAddresses": .list(["192.0.2.1"])]),
            .init(locationID: office, serviceID: "44444444-4444-4444-4444-444444444444", name: "Wi-Fi", enabled: true,
                  proxies: ["HTTPProxy": .text("office.example"), "HTTPPort": .number(8081), "HTTPEnable": .number(1)],
                  dns: ["ServerAddresses": .list(["192.0.2.2"])])
        ]))
    }
}
