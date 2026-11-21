import Foundation
import Testing

@testable import FudgeCore

// SPEC-116 §3: the proxy set in System Settings, for the Extension Store's npm and git. Made-up dictionaries in the
// shape `CFNetworkCopySystemProxySettings` gives; nothing reads the Mac's own.

@Test func theProxiesInSystemSettingsBecomeURLsAndABypassList() {
    let settings: [String: Any] = [
        "HTTPSEnable": NSNumber(value: 1), "HTTPSProxy": "proxy.example.test", "HTTPSPort": NSNumber(value: 3128),
        "HTTPEnable": NSNumber(value: 1), "HTTPProxy": "10.0.0.5", "HTTPPort": NSNumber(value: 8080),
        "ExceptionsList": ["*.local", "169.254/16", "localhost", "*.corp.example.test", "bad host", ""],
        "ProxyAutoConfigEnable": NSNumber(value: 0),
    ]
    let proxy = SystemProxy(settings: settings)
    #expect(proxy.https == "http://proxy.example.test:3128")
    #expect(proxy.http == "http://10.0.0.5:8080")
    #expect(proxy.noProxy == ".local,localhost,.corp.example.test", "macOS's 169.254/16 can't be written for NO_PROXY")
    #expect(!proxy.autoConfig)
    #expect(proxy.environmentValue?.contains("\"https\":\"http:\\/\\/proxy.example.test:3128\"") == true)
}

@Test func onlyAnEnabledWellFormedProxyCounts() {
    #expect(SystemProxy(settings: [:]) == SystemProxy())
    #expect(SystemProxy().environmentValue == nil, "nothing to say, so the host gets nothing")
    // Turned off, no port, a port out of range, or a host that isn't one.
    for settings: [String: Any] in [
        ["HTTPSEnable": NSNumber(value: 0), "HTTPSProxy": "proxy.example.test", "HTTPSPort": NSNumber(value: 3128)],
        ["HTTPSEnable": NSNumber(value: 1), "HTTPSProxy": "proxy.example.test"],
        ["HTTPSEnable": NSNumber(value: 1), "HTTPSProxy": "proxy.example.test", "HTTPSPort": NSNumber(value: 70000)],
        [
            "HTTPSEnable": NSNumber(value: 1), "HTTPSProxy": "user:secret@proxy.example.test",
            "HTTPSPort": NSNumber(value: 1),
        ],
        ["HTTPSEnable": NSNumber(value: 1), "HTTPSProxy": "proxy.example.test/x", "HTTPSPort": NSNumber(value: 1)],
        ["HTTPSEnable": NSNumber(value: 1), "HTTPSProxy": "-oProxyCommand=x", "HTTPSPort": NSNumber(value: 1)],
    ] {
        #expect(SystemProxy(settings: settings).https == nil, "\(settings)")
    }
    let ipv6 = SystemProxy(settings: [
        "HTTPSEnable": NSNumber(value: 1), "HTTPSProxy": "fd00::1", "HTTPSPort": NSNumber(value: 3128),
    ])
    #expect(ipv6.https == "http://[fd00::1]:3128")
}

@Test func aProxyConfigurationFileIsOnlyNoted() {
    for key in ["ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"] {
        let proxy = SystemProxy(settings: [
            key: NSNumber(value: 1), "ProxyAutoConfigURLString": "http://wpad.example.test/proxy.pac",
        ])
        #expect(proxy.autoConfig && proxy.https == nil && proxy.http == nil)
        #expect(proxy.environmentValue == "{\"autoConfig\":true}", "the file's address isn't passed on")
    }
}

@Test func theHostGetsTheProxyOnlyWhenThereIsOne() {
    let paths = FudgePaths(supportDirectory: URL(fileURLWithPath: "/tmp/fudge-proxy-test"))
    #expect(ExtensionStore.hostEnvironment(cli: nil, paths: paths)[SystemProxy.environmentKey] == nil)
    let proxy = SystemProxy(https: "http://proxy.example.test:3128")
    let environment = ExtensionStore.hostEnvironment(cli: nil, paths: paths, proxy: proxy)
    #expect(environment[SystemProxy.environmentKey] == proxy.environmentValue)
}
