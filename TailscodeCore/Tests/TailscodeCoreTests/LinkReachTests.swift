import Foundation
import Testing

@testable import TailscodeCore

@Suite("Link reach")
struct LinkReachTests {
  @Test("The public web gets a card")
  func publicHosts() {
    for text in [
      "https://datatracker.ietf.org/doc/html/rfc6749", "http://example.com/x",
      "https://docs.swift.org/", "https://8.8.8.8/", "https://sub.domain.co.uk/a?b=c",
    ] {
      let url = URL(string: text)!
      #expect(LinkReach.allows(url), "\(text)")
    }
  }

  @Test("Nothing private is ever fetched on a stranger's say-so")
  func privateHosts() {
    for text in [
      "http://localhost/", "http://127.0.0.1/", "http://10.0.0.5/admin", "http://192.168.1.1/reboot",
      "http://172.16.4.2/", "http://172.31.255.255/", "http://169.254.169.254/latest/meta-data",
      "http://100.64.0.1/", "http://100.127.0.9/", "http://printer.local/", "http://nas.lan/",
      "http://arch.tail1234.ts.net/", "http://router.home.arpa/", "http://intranet/",
      "http://[::1]/", "http://0.0.0.0/", "http://224.0.0.1/", "ftp://example.org/x",
      "http://svc.internal/", "http://3232235777/",
    ] {
      #expect(!LinkReach.allows(URL(string: text)!), "\(text)")
    }
  }

  @Test("The ranges end where the registries say")
  func rangeEdges() {
    #expect(LinkReach.allows(URL(string: "http://172.32.0.1/")!))
    #expect(LinkReach.allows(URL(string: "http://100.128.0.1/")!))
    #expect(LinkReach.allows(URL(string: "http://11.0.0.1/")!))
    #expect(LinkReach.allows(URL(string: "http://192.169.0.1/")!))
  }
}
