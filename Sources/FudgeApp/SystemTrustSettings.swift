import Foundation
import FudgeCore
import Security

/// The Mac's trust settings, read for `NodeTrust` when the extension host starts: each certificate the system, admin
/// and user domains hold settings for, with those settings. It only reads; nothing is ever added to a Keychain.
enum SystemTrustSettings {
    static func certificates() -> [NodeTrust.Certificate] {
        var found: [Data: NodeTrust.Certificate] = [:]
        var order: [Data] = []
        let domains: [(NodeTrust.Domain, SecTrustSettingsDomain)] = [
            (.user, .user), (.admin, .admin), (.system, .system),
        ]
        for (domain, secDomain) in domains {
            var list: CFArray?
            guard SecTrustSettingsCopyCertificates(secDomain, &list) == errSecSuccess,
                let certificates = list as? [SecCertificate]
            else { continue }
            for certificate in certificates {
                let der = SecCertificateCopyData(certificate) as Data
                var raw: CFArray?
                let status = SecTrustSettingsCopyTrustSettings(certificate, secDomain, &raw)
                // A system root with no settings of its own is trusted, as the system's anchors are.
                let settings: [NodeTrust.Setting]?
                if status == errSecSuccess {
                    settings = ((raw as? [[String: Any]]) ?? []).map(setting)
                } else {
                    settings = domain == .system ? [] : nil
                }
                if found[der] == nil {
                    found[der] = NodeTrust.Certificate(der: der, settings: [:])
                    order.append(der)
                }
                if let settings { found[der]?.settings[domain] = settings }
            }
        }
        return order.compactMap { found[$0] }
    }

    /// One trust settings dictionary, as Apple documents its keys.
    private static func setting(_ entry: [String: Any]) -> NodeTrust.Setting {
        let result: NodeTrust.Setting.Result
        switch (entry[kSecTrustSettingsResult as String] as? NSNumber)?.uint32Value {
        case nil, SecTrustSettingsResult.trustRoot.rawValue: result = .trustRoot
        case SecTrustSettingsResult.trustAsRoot.rawValue: result = .trustAsRoot
        case SecTrustSettingsResult.deny.rawValue: result = .deny
        default: result = .unspecified
        }
        var policy: NodeTrust.Setting.Policy?
        if let value = entry[kSecTrustSettingsPolicy as String] {
            // Anything but a policy Fudge can read counts as "not SSL", which never exports anything.
            policy = .other
            let object = value as CFTypeRef
            if CFGetTypeID(object) == SecPolicyGetTypeID() {
                let properties = SecPolicyCopyProperties(unsafeDowncast(object, to: SecPolicy.self)) as? [String: Any]
                if properties?[kSecPolicyOid as String] as? String == (kSecPolicyAppleSSL as String) { policy = .ssl }
            }
        }
        let narrowing = [
            kSecTrustSettingsPolicyString, kSecTrustSettingsApplication, kSecTrustSettingsAllowedError,
            kSecTrustSettingsKeyUsage,
        ]
        let restricted = narrowing.contains { entry[$0 as String] != nil }
        return NodeTrust.Setting(result: result, policy: policy, restricted: restricted)
    }
}
