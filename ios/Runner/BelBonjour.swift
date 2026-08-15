// SPDX-License-Identifier: GPL-3.0-or-later

import Flutter
import Foundation
import dnssd

/// Finding Bel hosts on iOS and iPadOS, through the system's DNS-SD responder.
///
/// **This exists because iOS refuses the Dart implementation on real
/// hardware.** `lib/src/remote/mdns/mdns_service.dart` speaks multicast DNS
/// over a socket Bel owns, which is what every other platform uses; on an iPad
/// the bind succeeds, the group join succeeds, and then every send to
/// 224.0.0.251 is refused with `EHOSTUNREACH` while nothing at all is delivered
/// inbound — unless the app carries `com.apple.developer.networking.multicast`,
/// a restricted entitlement Apple grants per team, by request. A project that
/// people build for themselves cannot depend on one of those.
///
/// Bonjour through `mDNSResponder` needs no entitlement. The requirement is
/// `NSLocalNetworkUsageDescription` and `NSBonjourServices` in `Info.plist`, and
/// both were already there for the socket that could never use them.
///
/// The iOS **simulator** has no such restriction, which is why this was not
/// caught: the raw socket browses perfectly on a simulator and finds nothing,
/// ever, on the device the feature exists for.
///
/// Browsing only. A tablet is a display and never advertises, so the sending
/// end stays the one Dart implementation.
final class BelBonjour: NSObject, FlutterPlugin, FlutterStreamHandler {
  /// Must match `bonjourChannel` in `lib/src/remote/mdns/bonjour_discovery.dart`.
  private static let channelName = "dev.belmeter.bel/bonjour"

  /// Must match `belServiceName` in `lib/src/remote/mdns/mdns_service.dart` and
  /// the `NSBonjourServices` entry in `Info.plist`. All three are the same fact
  /// written three times and there is no way to make them one.
  private static let serviceType = "_bel._tcp"

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = BelBonjour()
    let channel = FlutterEventChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    channel.setStreamHandler(instance)
    // Holds the only strong reference: the channel keeps the handler, the
    // registrar keeps the channel, and without this the browse is deallocated
    // as soon as `register` returns.
    registrar.publish(instance)
  }

  private var events: FlutterEventSink?
  private var browseRef: DNSServiceRef?

  /// One resolve per service, kept running rather than torn down once it has
  /// answered: the TXT record carries the format the host is measuring and that
  /// changes while it runs. Keyed by instance name, which DNS-SD guarantees is
  /// unique on the network.
  private var resolvers: [String: DNSServiceRef] = [:]
  private var contexts: [String: ResolveContext] = [:]
  private var found: [String: [String: Any]] = [:]

  /// The instance a resolve callback belongs to. The C API hands back an
  /// escaped full name (`Bel\032Probe._bel._tcp.local.`) and unescaping that is
  /// more work — and more ways to be wrong — than carrying the name along.
  final class ResolveContext {
    let owner: BelBonjour
    let name: String
    init(owner: BelBonjour, name: String) {
      self.owner = owner
      self.name = name
    }
  }

  // MARK: - FlutterStreamHandler

  func onListen(
    withArguments arguments: Any?,
    eventSink: @escaping FlutterEventSink
  ) -> FlutterError? {
    events = eventSink

    var ref: DNSServiceRef?
    let error = DNSServiceBrowse(
      &ref,
      0,
      UInt32(kDNSServiceInterfaceIndexAny),
      BelBonjour.serviceType,
      "local.",
      browseReply,
      Unmanaged.passUnretained(self).toOpaque()
    )
    guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
      events = nil
      return FlutterError(
        code: "browse-failed",
        message: describe(error),
        details: nil
      )
    }

    browseRef = ref
    DNSServiceSetDispatchQueue(ref, DispatchQueue.main)
    // An empty list rather than silence: the panel distinguishes "searching and
    // nothing yet" from "cannot search", and it can only do that if the search
    // says it started.
    eventSink([])
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    for (_, ref) in resolvers {
      DNSServiceRefDeallocate(ref)
    }
    resolvers.removeAll()
    contexts.removeAll()
    found.removeAll()

    if let browseRef {
      DNSServiceRefDeallocate(browseRef)
    }
    browseRef = nil
    events = nil
    return nil
  }

  // MARK: - Browse

  fileprivate func add(name: String, type: String, domain: String, interface: UInt32) {
    guard resolvers[name] == nil else { return }

    let context = ResolveContext(owner: self, name: name)
    var ref: DNSServiceRef?
    let error = DNSServiceResolve(
      &ref,
      0,
      interface,
      name,
      type,
      domain,
      resolveReply,
      Unmanaged.passUnretained(context).toOpaque()
    )
    guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else { return }

    contexts[name] = context
    resolvers[name] = ref
    DNSServiceSetDispatchQueue(ref, DispatchQueue.main)
  }

  fileprivate func remove(name: String) {
    if let ref = resolvers.removeValue(forKey: name) {
      DNSServiceRefDeallocate(ref)
    }
    contexts.removeValue(forKey: name)
    guard found.removeValue(forKey: name) != nil else { return }
    publish()
  }

  fileprivate func resolved(
    name: String,
    host: String,
    port: UInt16,
    txt: [String: String]
  ) {
    // The SRV target, not an address: `studio-mac.local` is what the responder
    // published and the system resolver is better placed than Bel is to decide
    // which of a docked laptop's two interfaces answers to it.
    var hostName = host
    if hostName.hasSuffix(".") {
      hostName.removeLast()
    }

    found[name] = [
      "name": name,
      "host": hostName,
      "port": Int(port),
      "txt": txt,
    ]
    publish()
  }

  private func publish() {
    guard let events else { return }
    events(Array(found.values))
  }

  /// `kDNSServiceErr_PolicyDenied`, written out because it is younger than some
  /// of the SDKs this has to build against and a missing constant is a build
  /// that fails rather than a message that is vaguer.
  private static let policyDenied: DNSServiceErrorType = -65570

  private func describe(_ error: DNSServiceErrorType) -> String {
    switch error {
    case DNSServiceErrorType(kDNSServiceErr_NoAuth), BelBonjour.policyDenied:
      return "iPadOS is not letting Bel search the local network. Allow it "
        + "under Settings › Privacy & Security › Local Network, or enter an "
        + "address below."
    default:
      return "The system could not search for hosts (DNS-SD error \(error))."
    }
  }
}

// MARK: - C callbacks
//
// These are `@convention(c)` function pointers, so they capture nothing and
// everything they need arrives through the context pointer.

private let browseReply: DNSServiceBrowseReply = {
  _, flags, interfaceIndex, errorCode, serviceName, regtype, replyDomain, context in

  guard errorCode == DNSServiceErrorType(kDNSServiceErr_NoError),
    let context,
    let serviceName,
    let regtype,
    let replyDomain
  else { return }

  let plugin = Unmanaged<BelBonjour>.fromOpaque(context).takeUnretainedValue()
  let name = String(cString: serviceName)

  if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
    plugin.add(
      name: name,
      type: String(cString: regtype),
      domain: String(cString: replyDomain),
      interface: interfaceIndex
    )
  } else {
    plugin.remove(name: name)
  }
}

private let resolveReply: DNSServiceResolveReply = {
  _, _, _, errorCode, _, hosttarget, port, txtLen, txtRecord, context in

  guard errorCode == DNSServiceErrorType(kDNSServiceErr_NoError),
    let context,
    let hosttarget
  else { return }

  let resolveContext = Unmanaged<BelBonjour.ResolveContext>
    .fromOpaque(context)
    .takeUnretainedValue()

  var txt: [String: String] = [:]
  let count = TXTRecordGetCount(txtLen, txtRecord)
  for index in 0..<count {
    var key = [CChar](repeating: 0, count: 256)
    var valueLength: UInt8 = 0
    var value: UnsafeRawPointer?
    guard
      TXTRecordGetItemAtIndex(
        txtLen, txtRecord, index, UInt16(key.count), &key, &valueLength, &value
      ) == DNSServiceErrorType(kDNSServiceErr_NoError)
    else { continue }

    let name = String(cString: key)
    if let value, valueLength > 0 {
      let bytes = Data(bytes: value, count: Int(valueLength))
      txt[name] = String(decoding: bytes, as: UTF8.self)
    } else {
      txt[name] = ""
    }
  }

  resolveContext.owner.resolved(
    name: resolveContext.name,
    // The port arrives in network byte order, which on every device Bel runs
    // on is the other one.
    host: String(cString: hosttarget),
    port: UInt16(bigEndian: port),
    txt: txt
  )
}
