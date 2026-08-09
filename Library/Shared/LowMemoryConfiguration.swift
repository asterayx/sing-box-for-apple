import Foundation

public enum LowMemoryConfiguration {
    /// Produces the runtime-only iOS configuration. The stored user profile is
    /// never rewritten, and explicit user values always win except for the TUN
    /// stack required by includeAllNetworks.
    public static func prepare(_ content: String, includeAllNetworks: Bool, production: Bool) throws -> String {
        // sing-box accepts extended JSON that Foundation cannot round-trip
        // safely. In that case keep the profile untouched; the Go runtime
        // memory limit, GC tuning, log cap, and OOM protection still apply.
        guard var root = decodeRoot(content) else {
            return content
        }

        var changed = false

        if production {
            var log = root["log"] as? [String: Any] ?? [:]
            if log["level"] == nil {
                log["level"] = "warn"
                root["log"] = log
                changed = true
            }
        }

        if var dns = root["dns"] as? [String: Any], dns["cache_capacity"] == nil {
            dns["cache_capacity"] = 1024
            root["dns"] = dns
            changed = true
        }

        if var inbounds = root["inbounds"] as? [[String: Any]] {
            for index in inbounds.indices where inbounds[index]["type"] as? String == "tun" {
                if inbounds[index]["udp_timeout"] == nil {
                    inbounds[index]["udp_timeout"] = "1m"
                    changed = true
                }
                if inbounds[index]["udp_nat_max"] == nil {
                    inbounds[index]["udp_nat_max"] = 512
                    changed = true
                }
                let requiredStack = includeAllNetworks ? "gvisor" : "system"
                if includeAllNetworks || inbounds[index]["stack"] == nil {
                    if inbounds[index]["stack"] as? String != requiredStack {
                        inbounds[index]["stack"] = requiredStack
                        changed = true
                    }
                }
                if includeAllNetworks, inbounds[index]["endpoint_independent_nat"] == nil {
                    inbounds[index]["endpoint_independent_nat"] = false
                    changed = true
                }
            }
            root["inbounds"] = inbounds
        }

        if var outbounds = root["outbounds"] as? [[String: Any]] {
            let quicTypes: Set<String> = ["hysteria", "hysteria2", "tuic"]
            for index in outbounds.indices {
                if let type = outbounds[index]["type"] as? String, quicTypes.contains(type) {
                    if outbounds[index]["idle_timeout"] == nil {
                        outbounds[index]["idle_timeout"] = "30s"
                        changed = true
                    }
                    if outbounds[index]["stream_receive_window"] == nil {
                        outbounds[index]["stream_receive_window"] = 1 * 1024 * 1024
                        changed = true
                    }
                    if outbounds[index]["connection_receive_window"] == nil {
                        outbounds[index]["connection_receive_window"] = 4 * 1024 * 1024
                        changed = true
                    }
                    if outbounds[index]["max_concurrent_streams"] == nil {
                        outbounds[index]["max_concurrent_streams"] = 32
                        changed = true
                    }
                }

                if var multiplex = outbounds[index]["multiplex"] as? [String: Any],
                   multiplex["enabled"] as? Bool == true,
                   multiplex["max_connections"] == nil,
                   multiplex["max_streams"] == nil
                {
                    multiplex["max_connections"] = 2
                    if multiplex["min_streams"] == nil {
                        multiplex["min_streams"] = 4
                    }
                    outbounds[index]["multiplex"] = multiplex
                    changed = true
                }
            }
            root["outbounds"] = outbounds
        }

        guard changed else {
            return content
        }
        let runtimeData = try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
        guard let runtimeContent = String(data: runtimeData, encoding: .utf8) else {
            throw NSError(domain: "LowMemoryConfiguration", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Unable to encode runtime configuration",
            ])
        }
        return runtimeContent
    }

    /// Apple's JSONSerialization intentionally accepts only strict JSON. Never
    /// attempt to rewrite extended JSON (comments, trailing commas, or other
    /// sing-box syntax), because a lossy conversion could change semantics.
    private static func decodeRoot(_ content: String) -> [String: Any]? {
        guard let data = content.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
