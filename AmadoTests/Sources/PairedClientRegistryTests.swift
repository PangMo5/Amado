import Foundation
import Testing

@testable import AmadoKit

@Suite("Paired client registry")
struct PairedClientRegistryTests {
  @Test
  func `iPhone display name is stable and derived from its UUID`() throws {
    let id = try #require(UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890"))

    #expect(PairedDeviceName.iPhone(id) == "iPhone ABCDEF")
  }

  @Test
  func `Authenticated first contact migrates an existing phone`() throws {
    let identity = PairedClientIdentity(id: UUID(), name: "Shirou's iPhone")
    let now = Date(timeIntervalSince1970: 1_000)
    var registry = PairedClientRegistry()

    registry.register(identity, at: now, clearsRevocation: false)

    let client = try #require(registry.clients.first)
    #expect(client.id == identity.id)
    #expect(client.name == identity.name)
    #expect(client.pairedAt == now)
    #expect(client.lastSeenAt == now)
  }

  @Test
  func `Background contact cannot restore a phone removed on the Mac`() {
    let identity = PairedClientIdentity(id: UUID(), name: "iPhone")
    var registry = PairedClientRegistry()
    registry.register(identity, at: Date(timeIntervalSince1970: 1_000), clearsRevocation: true)
    registry.remove(identity.id, revoke: true)

    registry.register(
      identity,
      at: Date(timeIntervalSince1970: 2_000),
      clearsRevocation: false,
    )

    #expect(registry.clients.isEmpty)
    #expect(registry.isRevoked(identity.id))
  }

  @Test
  func `Explicit pairing restores a phone removed on the Mac`() {
    let identity = PairedClientIdentity(id: UUID(), name: "iPhone")
    var registry = PairedClientRegistry(revokedClientIDs: [identity.id])

    registry.register(
      identity,
      at: Date(timeIntervalSince1970: 2_000),
      clearsRevocation: true,
    )

    #expect(registry.clients.map(\.id) == [identity.id])
    #expect(!registry.isRevoked(identity.id))
  }

  @Test
  func `Phone initiated removal allows a later explicit repair`() {
    let identity = PairedClientIdentity(id: UUID(), name: "iPhone")
    var registry = PairedClientRegistry()
    registry.register(identity, at: Date(timeIntervalSince1970: 1_000), clearsRevocation: true)

    registry.remove(identity.id, revoke: false)

    #expect(registry.clients.isEmpty)
    #expect(!registry.isRevoked(identity.id))
  }

  @Test
  func `Phone initiated removal does not clear a Mac side revocation`() {
    let identity = PairedClientIdentity(id: UUID(), name: "iPhone")
    var registry = PairedClientRegistry(revokedClientIDs: [identity.id])

    registry.remove(identity.id, revoke: false)

    #expect(registry.isRevoked(identity.id))
  }

  @Test
  func `A known phone keeps its identity when a legacy name becomes its generated label`() throws {
    let id = UUID()
    let generatedName = PairedDeviceName.iPhone(id)
    let firstSeenAt = Date(timeIntervalSince1970: 1_000)
    let renamedAt = Date(timeIntervalSince1970: 2_000)
    var registry = PairedClientRegistry()

    registry.register(
      PairedClientIdentity(id: id, name: "iPhone 17 Pro Max"),
      at: firstSeenAt,
      clearsRevocation: true,
    )
    registry.register(
      PairedClientIdentity(id: id, name: generatedName),
      at: renamedAt,
      clearsRevocation: false,
    )

    let client = try #require(registry.clients.first)
    #expect(registry.clients.count == 1)
    #expect(client.id == id)
    #expect(client.name == generatedName)
    #expect(client.pairedAt == firstSeenAt)
    #expect(client.lastSeenAt == renamedAt)
  }
}
