//
//  Gaia.swift
//  Blockstack
//
//  Created by Yukan Liao on 2018-04-15.
//

import Foundation

class Gaia {

    // TODO: Utilize promise pattern/other way of preventing simultaneous requests
    static func getOrSetLocalHubConnection(callback: @escaping (GaiaHubSession?, GaiaError?) -> Void) {
        if let session = self.session {
            callback(session, nil)
        } else if let config = Gaia.retrieveConfig() {
            self.session = GaiaHubSession(with: config)
            callback(self.session, nil)
        } else {
            self.setLocalGaiaHubConnection(callback: callback)
        }
    }
    
    static func setLocalGaiaHubConnection(callback: @escaping (GaiaHubSession?, GaiaError?) -> Void) {
        let userData = ProfileHelper.retrieveProfile()
        let hubURL = userData?.hubURL ?? BlockstackConstants.DefaultGaiaHubURL
        guard let appPrivateKey = userData?.privateKey else {
            callback(nil, GaiaError.configurationError)
            return
        }
        // If signed in from previous version, no gaiaAssociationToken in UserData.
        let gaiaAssociationToken = userData?.gaiaAssociationToken
        self.connectToHub(hubURL: hubURL, challengeSignerHex: appPrivateKey, gaiaAssociationToken: gaiaAssociationToken) { session, error in
            self.session = session
            callback(session, error)
        }
    }
    
    static func clearSession() {
        self.session = nil
    }
    
    // MARK: - Private

    // TODO: Add support for multiple sessions
    private static var session: GaiaHubSession? {
        didSet {
            guard let session = self.session else {
                self.resetConfig()
                return
            }
            self.saveConfig(session.config)
        }
    }
    
    private static func connectToHub(hubURL: String, challengeSignerHex: String, gaiaAssociationToken: String?, completion: @escaping (GaiaHubSession?, GaiaError?) -> Void) {
        self.getHubInfo(for: hubURL) { hubInfo, error in
            guard error == nil, let hubInfo = hubInfo else {
                completion(nil, GaiaError.connectionError)
                return
            }
            guard let gaiaChallenge = hubInfo.challengeText,
                  let latestAuthVersion = hubInfo.latestAuthVersion,
                  let readURLPrefix = hubInfo.readURLPrefix,
                  let iss = Keys.getPublicKeyFromPrivate(challengeSignerHex, compressed: true),
                  let salt = Keys.getEntropy(numberOfBytes:16) else {
                completion(nil, GaiaError.configurationError)
                return
            }

            let lavIndex = latestAuthVersion.index(latestAuthVersion.startIndex, offsetBy: 1)
            let lavNum = Int(latestAuthVersion[lavIndex...]) ?? 0
            if (lavNum < 1) {
                completion(nil, GaiaError.configurationError)
                return
            }

            var payload: [String: Any] = [
                "gaiaChallenge": gaiaChallenge,
                "hubUrl": hubURL,
                "iss": iss,
                "salt": salt,
            ]
            if let gaiaAssociationToken = gaiaAssociationToken {
                payload["gaiaAssociationToken"] = gaiaAssociationToken
            }
            guard let address = Keys.getAddressFromPublicKey(iss),
                  let signedPayload = JSONTokensJS().signToken(payload: payload, privateKey: challengeSignerHex) else {
                completion(nil, GaiaError.configurationError)
                return
            }
            let token = "v1:\(signedPayload)"

            let config = GaiaConfig(URLPrefix: readURLPrefix, address: address, token: token, server: hubURL)
            completion(GaiaHubSession(with: config), nil)
        }
    }

    private static func getHubInfo(for hubURL: String, completion: @escaping (GaiaHubInfo?, Error?) -> Void) {
        guard let hubInfoURL = URL(string: "\(hubURL)/hub_info") else {
            completion(nil, nil)
            return
        }
        let task = URLSession.shared.dataTask(with: hubInfoURL) { data, response, error in
            guard let data = data, error == nil else {
                print("Error connecting to Gaia hub")
                completion(nil, error)
                return
            }
            do {
                let jsonDecoder = JSONDecoder()
                let hubInfo = try jsonDecoder.decode(GaiaHubInfo.self, from: data)
                completion(hubInfo, nil)
            } catch {
                completion(nil, error)
            }
        }
        task.resume()
    }

    private static func saveConfig(_ config: GaiaConfig) {
        self.resetConfig()
        if let config = try? PropertyListEncoder().encode(config) {
            UserDefaults.standard.set(config, forKey: BlockstackConstants.GaiaHubConfigUserDefaultLabel)
        }
    }
    
    static func resetConfig() {
        UserDefaults.standard.removeObject(forKey: BlockstackConstants.GaiaHubConfigUserDefaultLabel)
    }
    
    private static func retrieveConfig() -> GaiaConfig? {
        guard let data = UserDefaults.standard.value(forKey:
            BlockstackConstants.GaiaHubConfigUserDefaultLabel) as? Data,
            let config = try? PropertyListDecoder().decode(GaiaConfig.self, from: data) else {
                return nil
        }
        return config
    }
}

public struct GaiaConfig: Codable {
    public let URLPrefix: String?
    public let address: String?
    public let token: String?
    public let server: String?
    
    public init(URLPrefix: String?, address: String?, token: String?, server: String?) {
        self.URLPrefix = URLPrefix
        self.address = address
        self.token = token
        self.server = server
    }
}

public struct GaiaHubInfo: Codable {
    let challengeText: String?
    let readURLPrefix: String?
    let latestAuthVersion: String?
    
    enum CodingKeys: String, CodingKey {
        case challengeText = "challenge_text"
        case readURLPrefix = "read_url_prefix"
        case latestAuthVersion = "latest_auth_version"
    }
}
