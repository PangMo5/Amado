import Foundation
import Testing

@testable import Amado

@Suite("Lock response channel")
struct LockResponseChannelTests {
  @Test
  func `delivers an answer that arrives while the transport is waiting`() async {
    let channel = LockResponseChannel()
    let waiter = Task { await channel.firstResponse() }
    try? await Task.sleep(for: .milliseconds(10))

    channel.respond(with: Data("late".utf8))

    #expect(await waiter.value == Data("late".utf8))
  }

  @Test
  func `delivers an answer that arrives before anyone waits`() async {
    let channel = LockResponseChannel()
    channel.respond(with: Data("early".utf8))

    #expect(await channel.firstResponse() == Data("early".utf8))
  }

  @Test
  func `gives up when the reducer never answers`() async {
    let channel = LockResponseChannel()

    #expect(await channel.firstResponse(timeout: .milliseconds(20)) == nil)
  }

  @Test
  func `ignores an answer that arrives after the wait expired`() async {
    let channel = LockResponseChannel()

    #expect(await channel.firstResponse(timeout: .milliseconds(20)) == nil)

    // The reducer answering late must not trap on an already-resumed waiter.
    channel.respond(with: Data("too late".utf8))
    #expect(await channel.firstResponse(timeout: .milliseconds(20)) == nil)
  }

  @Test
  func `answers only the first waiter`() async {
    let channel = LockResponseChannel()
    let first = Task { await channel.firstResponse() }
    try? await Task.sleep(for: .milliseconds(10))
    let second = await channel.firstResponse(timeout: .milliseconds(20))

    channel.respond(with: Data("one".utf8))

    #expect(second == nil)
    #expect(await first.value == Data("one".utf8))
  }
}
