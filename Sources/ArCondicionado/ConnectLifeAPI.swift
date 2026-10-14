import Foundation
import CryptoKit
import Security

// Cliente da nuvem ConnectLife (Hisense).
// Protocolo verificado com REA contra o app oficial 2.17.2 — ver REA-FINDINGS.md.
// Fluxo: Gigya (CDC) login -> getJWT -> OAuth hijuconn -> gateway assinado (SHA256 + RSA PKCS#1).

enum ConnectLifeError: LocalizedError {
    case auth(String)
    case gateway(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .auth(let m): return String(localized: "Login: \(m)")
        case .gateway(let m): return m
        case .http(let s): return "HTTP \(s)"
        }
    }
}

struct Appliance: Identifiable, Equatable {
    let id: String          // deviceId
    let puid: String
    let name: String
    let room: String
    let typeCode: String
    let featureCode: String
    let offline: Bool
    var status: [String: Int]
}

actor ConnectLifeAPI {
    // Confirmados no libapp.so pelo REA
    private let gigyaKey = "4_yhTWQmHFpZkQZDSV1uV-_A"
    private let loginURL = URL(string: "https://accounts.eu1.gigya.com/accounts.login")!
    private let jwtURL = URL(string: "https://accounts.eu1.gigya.com/accounts.getJWT")!
    private let gateway = "https://clife-eu-gateway.hijuconn.com"
    private let signSuffix = "D9519A4B756946F081B7BB5B5E8D1197"

    // Credenciais de cliente: o app oficial ofusca as suas (appId 47110563037231),
    // então usamos o par publicado por oyvindwe/connectlife, aceito pelo gateway.
    private let authorizeURL = URL(string: "https://oauth.hijuconn.com/oauth/authorize")!
    private let tokenURL = URL(string: "https://oauth.hijuconn.com/oauth/token")!
    private let clientId = "5065059336212"
    private let clientSecret = "07swfKgvJhC3ydOUS9YV_SwVz0i4LKqlOLGNUukYHVMsJRF1b-iWeUGcNlXyYCeK"
    private let redirectURI = "https://api.connectlife.io/swagger/oauth2-redirect.html"
    private let appId = "47110565134383"
    private let appSecret = "yOzhz6junYno-nmULM3Wr7PU_dpSZN22ZdluvVWZ4uW5ZwwG8fIGCHTbrhcnU-iv"
    private let publicKeyB64 =
        "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAyyWrNG6q475HIHu7sMVu" +
        "vHof6vlgPeixmxa4EL/UsvVvHPz33NnWoQetQqit9TBNzUjMXw0KlY9PXM4iqHUU" +
        "U+dSyNDq1jZWIiJ2C2FccppswJtIKL3NRMFvT9PFh6NlP/4FUcQKojgKFbF7Kacc" +
        "JPKYHlwaO7qgoIjLxAHlSOXGpucJcOkPzT2EqsSVnW8sn8kenvNmghXDayhgxsh6" +
        "AyxK4kehJplEnmX/iYCfNoFXknGcLqFWYccgBz3fybvx30C/0IgU1980L8QsUAv5" +
        "esZmN8ugnbRgLRxKRlkQQLxQAiZMZdKTAx665YflT3YMHJvEFE8c2XFgoxHzSMc4" +
        "BwIDAQAB"

    private let email: String
    private let password: String
    private var accessToken: String?
    private var refreshToken: String?
    private var expires = Date.distantPast
    private var cachedKey: SecKey?

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    init(email: String, password: String) {
        self.email = email
        self.password = password
    }

    // MARK: - API pública

    func login() async throws {
        accessToken = nil
        refreshToken = nil
        try await ensureToken()
    }

    func appliances() async throws -> [Appliance] {
        let resp = try await gatewayRequest(path: "/clife-svc/pu/get_device_status_list", payload: [:], method: "GET")
        guard let list = resp["deviceList"] as? [[String: Any]] else {
            throw ConnectLifeError.gateway("Resposta sem deviceList")
        }
        return list.compactMap { d in
            guard let id = d["deviceId"] as? String, let puid = d["puid"] as? String else { return nil }
            var status: [String: Int] = [:]
            for (k, v) in (d["statusList"] as? [String: Any]) ?? [:] {
                if let i = v as? Int { status[k] = i }
                else if let s = v as? String, let f = Double(s) { status[k] = Int(f) }
            }
            return Appliance(
                id: id, puid: puid,
                name: d["deviceNickName"] as? String ?? "Ar-condicionado",
                room: Self.roomName(d["roomName"] as? String),
                typeCode: d["deviceTypeCode"] as? String ?? "",
                featureCode: d["deviceFeatureCode"] as? String ?? "",
                offline: "\(d["offlineState"] ?? 1)" != "1",
                status: status)
        }
    }

    /// "default_room" (e.g. "xxx_room") é uma chave interna que o app oficial traduz; tratamos como sem cômodo.
    private static func roomName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty, raw.lowercased() != "default_room",
              raw.range(of: #"^[a-z]+(_[a-z]+)+$"#, options: .regularExpression) == nil else { return "" }
        return raw
    }

    func set(puid: String, properties: [String: Int]) async throws {
        _ = try await gatewayRequest(path: "/device/pu/property/set",
                                     payload: ["puid": puid, "properties": properties.mapValues { String($0) }],
                                     method: "POST")
    }

    // MARK: - Auth

    private func ensureToken() async throws {
        if accessToken != nil, expires > Date() { return }
        if let rt = refreshToken {
            do {
                try await tokenRequest(["grant_type": "refresh_token", "refresh_token": rt])
                return
            } catch { refreshToken = nil }
        }
        // 1. Gigya
        let login = try await formPost(loginURL, ["loginID": email, "password": password, "APIKey": gigyaKey])
        if let code = login["errorCode"] as? Int, code != 0 {
            let msg = login["errorDetails"] as? String ?? login["errorMessage"] as? String ?? "erro \(code)"
            throw ConnectLifeError.auth(code == 206001 ? String(localized: "aceite os novos termos no app ConnectLife") : msg)
        }
        guard let uid = login["UID"] as? String,
              let cookie = (login["sessionInfo"] as? [String: Any])?["cookieValue"] as? String else {
            throw ConnectLifeError.auth(String(localized: "resposta inesperada do Gigya"))
        }
        // 2. JWT
        let jwt = try await formPost(jwtURL, ["APIKey": gigyaKey, "login_token": cookie])
        guard let idToken = jwt["id_token"] as? String else { throw ConnectLifeError.auth("sem id_token") }
        // 3. Authorize
        var req = URLRequest(url: authorizeURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientId, "redirect_uri": redirectURI, "idToken": idToken,
            "response_type": "code", "thirdType": "CDC", "thirdClientId": uid,
        ])
        let auth = try await send(req)
        guard let code = auth["code"] as? String else { throw ConnectLifeError.auth("sem code OAuth") }
        // 4. Token
        try await tokenRequest(["grant_type": "authorization_code", "code": code])
    }

    private func tokenRequest(_ extra: [String: String]) async throws {
        var params = ["client_id": clientId, "client_secret": clientSecret, "redirect_uri": redirectURI]
        params.merge(extra) { $1 }
        let body = try await formPost(tokenURL, params)
        guard let at = body["access_token"] as? String else { throw ConnectLifeError.auth("sem access_token") }
        let expiresIn = (body["expires_in"] as? Int) ?? Int("\(body["expires_in"] ?? "3600")") ?? 3600
        accessToken = at
        refreshToken = body["refresh_token"] as? String ?? refreshToken
        expires = Date().addingTimeInterval(TimeInterval(expiresIn - 90))
    }

    // MARK: - Gateway

    private func gatewayRequest(path: String, payload: [String: Any], method: String, retried: Bool = false) async throws -> [String: Any] {
        try await ensureToken()
        var data: [String: Any] = [
            "accessToken": accessToken!,
            "appId": appId,
            "appSecret": appSecret,
            "languageId": "12",
            "randStr": randomHex(16),
            "timeStamp": String(Int(Date().timeIntervalSince1970 * 1000)),
            "timezone": "1.0",
            "version": "5.0",
        ]
        data.merge(payload) { $1 }
        data["sign"] = try sign(data)

        var req: URLRequest
        if method == "GET" {
            var comps = URLComponents(string: gateway + path)!
            comps.queryItems = data.keys.sorted().map { URLQueryItem(name: $0, value: "\(data[$0]!)") }
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            req = URLRequest(url: comps.url!)
        } else {
            req = URLRequest(url: URL(string: gateway + path)!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        let body = try await send(req)
        guard let resp = body["response"] as? [String: Any] else {
            throw ConnectLifeError.gateway(String(localized: "Resposta inesperada do gateway"))
        }
        if "\(resp["resultCode"] ?? 0)" == "0" { return resp }
        let err = "\(resp["errorCode"] ?? "")"
        if !retried && err == "100026" { // token inválido
            accessToken = nil; refreshToken = nil
            return try await gatewayRequest(path: path, payload: payload, method: method, retried: true)
        }
        if !retried && err == "101005" { // randStr repetido
            return try await gatewayRequest(path: path, payload: payload, method: method, retried: true)
        }
        throw ConnectLifeError.gateway(resp["errorDesc"] as? String ?? "Erro \(err)")
    }

    /// sign = base64(RSA_PKCS1(pub, SHA256("k1=v1&k2=v2…" + sufixo))), chaves em ordem alfabética.
    private func sign(_ data: [String: Any]) throws -> String {
        let parts = data.keys.filter { $0 != "sign" }.sorted().map { key -> String in
            let v = data[key]!
            if v is [String: Any] || v is [Any] {
                let json = (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
                return "\(key)=\(String(decoding: json, as: UTF8.self))"
            }
            return "\(key)=\(v)"
        }
        let digest = Data(SHA256.hash(data: Data((parts.joined(separator: "&") + signSuffix).utf8)))
        var err: Unmanaged<CFError>?
        guard let enc = SecKeyCreateEncryptedData(try publicKey(), .rsaEncryptionPKCS1, digest as CFData, &err) else {
            throw ConnectLifeError.gateway(String(localized: "Falha ao assinar requisição"))
        }
        return (enc as Data).base64EncodedString()
    }

    private func publicKey() throws -> SecKey {
        if let k = cachedKey { return k }
        var der = Data(base64Encoded: publicKeyB64)!
        // SecKey quer PKCS#1: remove o cabeçalho SubjectPublicKeyInfo (24 bytes p/ RSA-2048)
        if der.count == 294 { der = der.dropFirst(24) }
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 2048,
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil) else {
            throw ConnectLifeError.gateway(String(localized: "Chave pública inválida"))
        }
        cachedKey = key
        return key
    }

    // MARK: - HTTP

    private func formPost(_ url: URL, _ params: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = params.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> [String: Any] {
        var req = req
        req.setValue("ArCondicionado-macOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw ConnectLifeError.http(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectLifeError.gateway(String(localized: "Resposta não-JSON"))
        }
        return json
    }

    private func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
