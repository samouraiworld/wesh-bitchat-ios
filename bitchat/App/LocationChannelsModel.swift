import Combine
import Foundation

@MainActor
final class LocationChannelsModel: ObservableObject {
    @Published private(set) var permissionState: LocationChannelManager.PermissionState
    @Published private(set) var availableChannels: [GeohashChannel]
    @Published private(set) var selectedChannel: ChannelID
    @Published private(set) var teleported: Bool
    @Published private(set) var bookmarks: [String]
    @Published private(set) var bookmarkNames: [String: String]
    @Published private(set) var locationNames: [GeohashChannelLevel: String]
    @Published private(set) var userTorEnabled: Bool

    private let manager: LocationChannelManager
    private let network: NetworkActivationService

    init(
        manager: LocationChannelManager? = nil,
        network: NetworkActivationService? = nil
    ) {
        let manager = manager ?? .shared
        let network = network ?? .shared

        self.manager = manager
        self.network = network
        self.permissionState = manager.permissionState
        self.availableChannels = manager.availableChannels
        self.selectedChannel = manager.selectedChannel
        self.teleported = manager.teleported
        self.bookmarks = manager.bookmarks
        self.bookmarkNames = manager.bookmarkNames
        self.locationNames = manager.locationNames
        self.userTorEnabled = network.userTorEnabled

        bind()
    }

    func select(_ channel: ChannelID) {
        manager.select(channel)
    }

    private func bind() {
        manager.$permissionState
            .receive(on: DispatchQueue.main)
            .assign(to: &$permissionState)

        manager.$availableChannels
            .receive(on: DispatchQueue.main)
            .assign(to: &$availableChannels)

        manager.$selectedChannel
            .receive(on: DispatchQueue.main)
            .assign(to: &$selectedChannel)

        manager.$teleported
            .receive(on: DispatchQueue.main)
            .assign(to: &$teleported)

        manager.$bookmarks
            .receive(on: DispatchQueue.main)
            .assign(to: &$bookmarks)

        manager.$bookmarkNames
            .receive(on: DispatchQueue.main)
            .assign(to: &$bookmarkNames)

        manager.$locationNames
            .receive(on: DispatchQueue.main)
            .assign(to: &$locationNames)

        network.$userTorEnabled
            .receive(on: DispatchQueue.main)
            .assign(to: &$userTorEnabled)
    }
}
