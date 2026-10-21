import Foundation
import Testing
@testable import bitchat

@MainActor
struct GeographicCommandRetirementTests {
    @Test(arguments: [false, true], [false, true])
    func discoveryNeverAdvertisesTheRetiredDropCommand(isGeographicPublic: Bool, isGeographicPrivate: Bool) {
        let aliases = CommandInfo.all(isGeoPublic: isGeographicPublic, isGeoDM: isGeographicPrivate).map(\.alias)
        #expect(!aliases.contains("/drop"))
    }

    @Test
    func actualHelpRouteDoesNotAdvertiseOrResolveGeographicWork() throws {
        let processor = CommandProcessor(contextProvider: nil, meshService: nil,
            identityManager: MockIdentityManager(MockKeychain()))
        // Exercise the actual help route: its catalogue must retain ordinary
        // messaging commands without advertising the retired /drop command.
        let result = processor.process("/help")
        guard case .success(let rendered) = result else {
            Issue.record("The ordinary help route must remain available")
            return
        }
        let text = try #require(rendered)
        #expect(!text.contains("/drop"))
        #expect(text.contains("/msg"))
        #expect(text.contains("/help"))
    }

    @Test
    func ordinaryMeshCommandDiscoveryStaysAvailable() {
        let aliases = Set(CommandInfo.all(isGeoPublic: false, isGeoDM: false).map(\.alias))
        #expect(aliases.isSuperset(of: ["/msg", "/help", "/clear", "/who", "/ping", "/trace"]))
    }
}
