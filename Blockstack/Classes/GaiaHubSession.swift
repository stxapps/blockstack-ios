//
//  GaiaSession.swift
//  Blockstack
//
//  Created by Yukan Liao on 2018-04-19.
//

import Foundation
import CryptoSwift
import Promises
import Regex

fileprivate let signatureFileSuffix = ".sig"

public let FILE_PREFIX = "file://"

class GaiaHubSession {
    let config: GaiaConfig

    init(with config: GaiaConfig) {
        self.config = config
    }

    /**
     Loop over the list of files in a Gaia hub, and run a callback on each entry. Not meant to be called by external clients.
     - parameter page: The page ID.
     - parameter callCount: The loop count.
     - parameter fileCount: The number of files listed so far.
     - parameter callback: The callback to invoke on each file. If it returns a falsey value, then the loop stops. If it returns a truthy value, the loop continues.
     - parameter completion: Final callback that contains the number of files listed, or any error encountered.
     */
    func listFilesLoop(page: String?, callCount: Int, fileCount: Int, callback: @escaping (_ filename: String) -> (Bool), completion: @escaping (_ fileCount: Int, _ gaiaError: GaiaError?) -> Void) {
        if callCount > 65536 {
            // This is ridiculously huge, and probably indicates a faulty Gaia hub anyway (e.g. on that serves endless data).
            completion(-1, GaiaError.invalidResponse)
            return
        }

        guard let server = self.config.server,
            let address = self.config.address,
            let token = self.config.token,
            let url = URL(string: "\(server)/list-files/\(address)") else {
                completion(-1, GaiaError.configurationError)
                return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("bearer \(token)", forHTTPHeaderField: "Authorization")

        let pageRequest: [String: Any] = ["page": page ?? NSNull()]
        let body = try? JSONSerialization.data(withJSONObject: pageRequest, options: [])
        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil, let httpResponse = response as? HTTPURLResponse, let data = data else {
                completion(-1, GaiaError.requestError)
                return
            }
            
            let code = httpResponse.statusCode
            if code == 401 {
                completion(-1, GaiaError.accessVerificationError)
                return
            } else if code >= 500 {
                completion(-1, GaiaError.serverError)
                return
            }

            guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
                  let result = jsonObject as? [String: Any],
                  let entries = result["entries"] as? [String],
                  result.keys.contains("page") else {
                completion(-1, GaiaError.invalidResponse)
                return
            }
            
            var fileCount = fileCount
            for entry in entries {
                fileCount += 1
                // Run callback on each entry; negative response means we're done.
                if !callback(entry) {
                    completion(fileCount, nil)
                    return
                }
            }

            let nextPage = result["page"] as? String
            if nextPage != nil {
                self.listFilesLoop(page: nextPage, callCount: callCount + 1, fileCount: fileCount, callback: callback, completion: completion)
            } else {
                completion(fileCount, nil)
            }
        }
        task.resume()
    }
    
    func getFile(at path: String, decrypt: Bool, verify: Bool, multiplayerOptions: MultiplayerOptions? = nil, dir: String = "", completion: @escaping (Any?, GaiaError?) -> Void) {

        var path = path
        var fileUrl: URL? = nil
        if let range = path.range(of: FILE_PREFIX) {
            fileUrl = URL(fileURLWithPath: path.replacingCharacters(in: range, with: dir + "/"))
            if let fileUrl = fileUrl, FileManager.default.fileExists(atPath: fileUrl.path) {
                if decrypt {
                    completion(DecryptedValue(text: ""), nil)
                } else {
                    completion("", nil)
                }
                return
            }

            path = path.replacingCharacters(in: range, with: "")
        }

        // In the case of signature verification, but no decryption, we need to fetch two files.
        // First, fetch the unencrypted file. Then fetch the signature file and validate it.
        if verify && !decrypt {
            all(
                self.getFileContents(at: path, multiplayerOptions: multiplayerOptions),
                self.getFileContents(at: "\(path)\(signatureFileSuffix)", multiplayerOptions: multiplayerOptions),
                self.getGaiaAddress(multiplayerOptions: multiplayerOptions)
                ).then({ fileContents, sigContents, gaiaAddress in
                    guard let signatureObject =
                        try? JSONDecoder().decode(SignatureObject.self, from: sigContents.0),
                        let signerAddress = Keys.getAddressFromPublicKey(signatureObject.publicKey),
                        signerAddress == gaiaAddress,
                        let isSignatureValid = EllipticJS().verifyECDSA(
                            content: fileContents.0.bytes,
                            publicKey: signatureObject.publicKey,
                            signature: signatureObject.signature),
                        isSignatureValid else {
                            completion(nil, GaiaError.signatureVerificationError)
                            return
                    }
                    let content: Any? =
                        fileContents.1 == "application/octet-stream" ?
                            fileContents.0.bytes :
                            String(data: fileContents.0, encoding: .utf8)
                    completion(content, nil)
                }).catch { error in
                    completion(nil, error as? GaiaError ?? GaiaError.signatureVerificationError)
            }
            return
        }
        
        self.getFileContents(at: path, multiplayerOptions: multiplayerOptions).then({ (data, contentType) in
            if !verify && !decrypt {
                // Simply fetch data if there is no verify or decrypt
                let content: Any? =
                    contentType == "application/octet-stream" ?
                        data.bytes :
                        String(data: data, encoding: .utf8)
                completion(content, nil)
                return
            } else if decrypt {
                // Handle decrypt scenarios
                guard let privateKey = ProfileHelper.retrieveProfile()?.privateKey else {
                    completion(nil, nil)
                    return
                }
                let verifyAndGetCipherText = Promise<String>() { resolve, reject in
                    if !verify {
                        // Decrypt, but not verify
                        guard let encryptedText = String(data: data, encoding: .utf8) else {
                            reject(GaiaError.invalidResponse)
                            return
                        }
                        resolve(encryptedText)
                    } else {
                        // Decrypt && verify
                        guard let signatureObject = try? JSONDecoder().decode(SignatureObject.self, from: data),
                            let encryptedText = signatureObject.cipherText else {
                                reject(GaiaError.invalidResponse)
                                return
                        }
                        let getUserAddress = Promise<String> { resolveAddress, rejectAddress in
                            if multiplayerOptions == nil {
                                guard let userPublicKey = Keys.getPublicKeyFromPrivate(privateKey, compressed: true),
                                    let address = Keys.getAddressFromPublicKey(userPublicKey) else {
                                        reject(GaiaError.signatureVerificationError)
                                        return
                                }
                                resolveAddress(address)
                            } else {
                                self.getGaiaAddress(multiplayerOptions: multiplayerOptions!).then({
                                    resolve($0)
                                }).catch(rejectAddress)
                            }
                        }
                        getUserAddress.then({ userAddress in
                            let signerAddress = Keys.getAddressFromPublicKey(signatureObject.publicKey)
                            guard signerAddress == userAddress,
                                let isSignatureValid = EllipticJS().verifyECDSA(
                                    content: encryptedText.bytes,
                                    publicKey: signatureObject.publicKey,
                                    signature: signatureObject.signature),
                                isSignatureValid else {
                                    completion(nil, GaiaError.signatureVerificationError)
                                    return
                            }
                            resolve(encryptedText)
                        }).catch(reject)
                    }
                }
                verifyAndGetCipherText.then({ cipherText in
                    let decryptedValue = Encryption.decryptECIES(cipherObjectJSONString: cipherText, privateKey: privateKey)
                    
                    if let fileUrl = fileUrl, let content = decryptedValue?.bytes {
                        let dirUrl = fileUrl.deletingLastPathComponent()
                        if (dirUrl.hasDirectoryPath && !FileManager.default.fileExists(atPath: dirUrl.path)) {
                            try FileManager.default.createDirectory(at: dirUrl, withIntermediateDirectories: true)
                        }

                        try Data(bytes: content).write(to: fileUrl)

                        completion(DecryptedValue(text: ""), nil)
                        return
                    }
                    
                    completion(decryptedValue, nil)
                }).catch { error in
                    completion(nil, error as? GaiaError ?? GaiaError.signatureVerificationError)
                }
                return
            } else {
                // We should not be here.
                completion(nil, GaiaError.requestError)
                return
            }
        }).catch { error in
            completion(nil, error as? GaiaError ?? GaiaError.requestError)
        }
    }

    func putFile(to path: String, content: Bytes, encrypt: Bool, encryptionKey: String?, sign: Bool, signingKey: String?, completion: @escaping (String?, GaiaError?) -> ()) {
        guard let data = encrypt ?
            self.encrypt(content: .bytes(content), with: encryptionKey) :
            Data(bytes: content) else {
                // TODO: Throw error
                completion(nil, nil)
                return
        }
        self.signAndPutData(to: path, content: data, originalContentType: "application/octet-stream", encrypted: encrypt, sign: sign, signingKey: signingKey, completion: completion)
    }
    
    func putFile(to path: String, content: String, encrypt: Bool, encryptionKey: String?, sign: Bool, signingKey: String?, dir: String = "", completion: @escaping (String?, GaiaError?) -> ()) {
        
        if let range = path.range(of: FILE_PREFIX) {
            let fileUrl = URL(fileURLWithPath: path.replacingCharacters(in: range, with: dir + "/"))
            guard let _content = try? Data(contentsOf: fileUrl) else {
                completion("file-does-not-exist/do-nothing-just-return", nil)
                return
            }

            let path = path.replacingCharacters(in: range, with: "")
            let content = Array(_content)
            putFile(to: path, content: content, encrypt: encrypt, encryptionKey: encryptionKey, sign: sign, signingKey: signingKey, completion: completion)
            return
        }

        guard let data = encrypt ?
            self.encrypt(content: .text(content), with: encryptionKey) :
            content.data(using: .utf8) else {
                // TODO: Throw error
                completion(nil, nil)
                return
        }
        self.signAndPutData(to: path, content: data, originalContentType: "text/plain", encrypted: encrypt, sign: sign, signingKey: signingKey, completion: completion)
    }
    
    func deleteFile(at path: String, wasSigned: Bool, completion: @escaping ((Error?) -> Void)) {
        var promises = [Promise<Void>]()
        promises.append(self.deleteItem(at: path))
        if wasSigned {
            promises.append(self.deleteItem(at: "\(path)\(signatureFileSuffix)"))
        }
        all(promises).then({ _ in
            completion(nil)
        }).catch { error in
            completion(error)
        }
    }
    
    func processPfData(pfData: [String: Any], dir: String, publicKey: String) throws -> [String: Any] {
        var ppfData = pfData
        if let values = pfData["values"] as? [[String: Any]], let _ = pfData["isSequential"] as? Bool {
            var pValues = [[String: Any]]()
            for value in values {
                let pValue = try processPfData(pfData: value, dir: dir, publicKey: publicKey)
                pValues.append(pValue)
            }
            ppfData["values"] = pValues
        } else if let _ = pfData["id"] as? String,
                  let type = pfData["type"] as? String,
                  let path = pfData["path"] as? String {
            if type == "putFile" {
                var content: Bytes, isString: Bool
                if let range = path.range(of: FILE_PREFIX) {
                    let fileUrl = URL(fileURLWithPath: path.replacingCharacters(in: range, with: dir + "/"))
                    if let _content = try? Data(contentsOf: fileUrl) {
                        content = Array(_content)
                    } else {
                        content = Array("".utf8)
                    }
                    isString = false

                    ppfData["path"] = path.replacingCharacters(in: range, with: "")
                } else {
                    guard let _content = pfData["content"] as? String else {
                        throw NSError.create(description: "In processPfData, invalid content: \(pfData)")
                    }
                    content = Array(_content.utf8)
                    isString = true;
                }

                let ect = try Encryption.encryptECIESAsDict(
                    content: content, recipientPublicKey: publicKey, isString: isString
                )
                ppfData["content"] = ect
            }
        } else {
            print("In processPfData, invalid data: \(pfData)")
        }
        return ppfData
    }
    
    func performFiles(pfData: String, dir: String, completion: @escaping (String?, Error?) -> Void) {
        guard let privateKey = ProfileHelper.retrieveProfile()?.privateKey,
              let publicKey = Keys.getPublicKeyFromPrivate(privateKey),
              let server = self.config.server,
              let address = self.config.address,
              let token = self.config.token,
              let url = URL(string: "\(server)/perform-files/\(address)") else {
            print("In performFiles, invalid privateKey or config")
            completion(nil, GaiaError.configurationError)
            return
        }

        guard let dpfData = pfData.data(using: .utf8),
              let jpfData = try? JSONSerialization.jsonObject(with: dpfData, options: .allowFragments),
              let ipfData = jpfData as? [String: Any],
              let ppfData = try? self.processPfData(pfData: ipfData, dir: dir, publicKey: publicKey),
              let fpfData = try? JSONSerialization.data(withJSONObject: ppfData) else {
            print("In performFiles, invalid pfData")
            completion(nil, GaiaError.configurationError)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = fpfData
        //request.timeoutInterval = default (60 seconds)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        //config.timeoutIntervalForResource = default (7 days)
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: request) { data, response, error in
            guard error == nil, let httpResponse = response as? HTTPURLResponse, let data = data else {
                completion(nil, GaiaError.requestError)
                return
            }

            let code = httpResponse.statusCode
            if code == 401 {
                completion(nil, GaiaError.accessVerificationError)
                return
            } else if code == 413 {
                completion(nil, GaiaError.payloadTooLargeError)
                return
            } else if code == 404 {
                completion(nil, GaiaError.itemNotFoundError)
                return
            } else if code >= 500 {
                completion(nil, GaiaError.serverError)
                return
            } else if code >= 200 && code <= 299, let responseText = String(data: data, encoding: .utf8) {
                completion(responseText, nil)
                return
            }

            completion(nil, GaiaError.invalidResponse)
            return
        }
        task.resume()
    }
    
    // MARK: - Private
    
    private enum Content {
        case text(String)
        case bytes(Bytes)
    }
    
    private func encrypt(content: Content, with key: String? = nil) -> Data? {
        var publicKey = key
        if publicKey == nil {
            // Encrypt to Gaia using the app public key
            guard let privateKey = ProfileHelper.retrieveProfile()?.privateKey else {
                    return nil
            }
            publicKey = Keys.getPublicKeyFromPrivate(privateKey)
        }
        
        guard let recipientPublicKey = publicKey else {
            return nil
        }

        // Encrypt and serialize to JSON
        var cipherObjectJSON: String?
        switch content {
        case let .bytes(bytes):
            cipherObjectJSON = Encryption.encryptECIES(content: bytes, recipientPublicKey: recipientPublicKey, isString: false)
        case let .text(text):
            cipherObjectJSON = Encryption.encryptECIES(content: text, recipientPublicKey: recipientPublicKey)
        }
        
        guard let cipher = cipherObjectJSON else {
            return nil
        }
        return cipher.data(using: .utf8)
    }
    
    private func getFileContents(at path: String, multiplayerOptions: MultiplayerOptions?) -> Promise<(Data, String)> {
        let getReadURL = Promise<URL> { resolve, reject in
            guard let escapedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                reject(GaiaError.configurationError)
                return
            }
            if let options = multiplayerOptions {
                Blockstack.shared.getUserAppFileURL(at: escapedPath, username: options.username, appOrigin: options.app, zoneFileLookupURL: options.zoneFileLookupURL) {
                    guard let fetchURL = $0?.appendingPathComponent(escapedPath) else {
                        reject(GaiaError.requestError)
                        return
                    }
                    resolve(fetchURL)
                }
            } else {
                guard let urlPrefix = self.config.URLPrefix,
                      let address = self.config.address,
                      let url = URL(string: "\(urlPrefix)\(address)/\(escapedPath)") else {
                    reject(GaiaError.configurationError)
                    return
                }
                resolve(url)
            }
        }
        return Promise<(Data, String)>() { resolve, reject in
            getReadURL.then({ url in
                let task = URLSession.shared.dataTask(with: url) { data, response, error in
                    guard error == nil, let httpResponse = response as? HTTPURLResponse, let data = data else {
                        reject(GaiaError.requestError)
                        return
                    }

                    let code = httpResponse.statusCode
                    if code == 401 {
                        reject(GaiaError.accessVerificationError)
                        return
                    } else if code == 404 {
                        reject(GaiaError.itemNotFoundError)
                        return
                    } else if code >= 500 {
                        reject(GaiaError.serverError)
                        return
                    } else if code >= 200 && code <= 299 {
                        let contentType = httpResponse.allHeaderFields["Content-Type"] as? String ?? "application/json"
                        resolve((data, contentType))
                        return
                    }

                    reject(GaiaError.invalidResponse)
                }
                task.resume()
            }).catch { error in
                reject(error)
            }
        }
    }

    private func getGaiaAddress(multiplayerOptions: MultiplayerOptions? = nil) -> Promise<String> {
        let parseUrl: (String) -> (String?) = { urlString in
            let pattern = Regex("([13][a-km-zA-HJ-NP-Z0-9]{26,35})")
            let matches = pattern.allMatches(in: urlString)
            return matches.last?.matchedString
        }
        return Promise<String>() { resolve, reject in
            guard let options = multiplayerOptions else {
                guard let prefix = self.config.URLPrefix,
                    let hubAddress = self.config.address,
                    let gaiaAddress = parseUrl("\(prefix)\(hubAddress)/") else {
                        reject(GaiaError.requestError)
                        return
                }
                resolve(gaiaAddress)
                return
            }
            Blockstack.shared.getUserAppFileURL(at: "/", username: options.username, appOrigin: options.app, zoneFileLookupURL: options.zoneFileLookupURL) {
                guard let readUrl = $0, let gaiaAddress = parseUrl(readUrl.absoluteString) else {
                    reject(GaiaError.requestError)
                    return
                }
                resolve(gaiaAddress)
            }
        }
    }
    
    private func deleteItem(at path: String) -> Promise<Void> {
        return Promise<Void>() { resolve, reject in
            
            guard let server = self.config.server,
                  let address = self.config.address,
                  let token = self.config.token,
                  let escapedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string:"\(server)/delete/\(address)/\(escapedPath)") else {
                reject(GaiaError.configurationError)
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.addValue("bearer \(token)", forHTTPHeaderField: "Authorization")
            let task = URLSession.shared.dataTask(with: request) { _, response, error in
                guard error == nil, let httpResponse = response as? HTTPURLResponse else {
                    reject(GaiaError.requestError)
                    return
                }

                let code = httpResponse.statusCode
                if code == 401 {
                    reject(GaiaError.accessVerificationError)
                    return
                } else if code == 404 {
                    reject(GaiaError.itemNotFoundError)
                    return
                } else if code >= 500 {
                    reject(GaiaError.serverError)
                    return
                } else if code >= 200 && code <= 299 {
                    resolve(())
                    return
                }

                reject(GaiaError.invalidResponse)
            }
            task.resume()
        }
    }
    
    private func signAndPutData(to path: String, content: Data, originalContentType: String, encrypted: Bool, sign: Bool, signingKey: String?, completion: @escaping (String?, GaiaError?) -> ()) {
        if encrypted && !sign {
            self.upload(path: path, contentType: "application/json", data: content, completion: completion)
        } else if encrypted && sign {
            guard let privateKey = signingKey ?? Blockstack.shared.loadUserData()?.privateKey,
                let signatureObject = EllipticJS().signECDSA(privateKey: privateKey, content: content.bytes) else {
                    // Handle error
                    completion(nil, nil)
                    return
            }
            let signedCipherObject = SignatureObject(
                signature: signatureObject.signature,
                publicKey: signatureObject.publicKey,
                cipherText: String(data: content, encoding: .utf8))
            guard let jsonData = try?  JSONEncoder().encode(signedCipherObject) else {
                // Handle error
                completion(nil, nil)
                return
            }
            self.upload(path: path, contentType: "application/json", data: jsonData, completion: completion)
        }  else if !encrypted && sign {
            // If signing but not encryption, 2 uploads are needed
            guard let privateKey = signingKey ?? Blockstack.shared.loadUserData()?.privateKey,
                let signatureObject = EllipticJS().signECDSA(privateKey: privateKey, content: content.bytes),
                let jsonData = try?  JSONEncoder().encode(signatureObject) else {
                    // Handle error
                    completion(nil, nil)
                    return
            }
            self.upload(path: path, contentType: originalContentType, data: content) { fileURL, error in
                guard let url = fileURL, error == nil else {
                    completion(nil, error)
                    return
                }
                self.upload(path: "\(path)\(signatureFileSuffix)", contentType: "application/json", data: jsonData) { _, error in
                    guard error == nil else {
                        completion(nil, error)
                        return
                    }
                    completion(url, nil)
                }
            }
        } else {
            // Not encrypting or signing
            self.upload(path: path, contentType: originalContentType, data: content, completion: completion)
        }
    }
    
    private func upload(path: String, contentType: String, data: Data, completion: @escaping (String?, GaiaError?) -> ()) {
        guard let server = self.config.server,
              let address = self.config.address,
              let token = self.config.token,
              let escapedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let putURL = URL(string:"\(server)/store/\(address)/\(escapedPath)") else {
            completion(nil, GaiaError.configurationError)
            return
        }

        var request = URLRequest(url: putURL)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil, let httpResponse = response as? HTTPURLResponse, let data = data else {
                completion(nil, GaiaError.requestError)
                return
            }

            let code = httpResponse.statusCode
            if code == 401 {
                completion(nil, GaiaError.accessVerificationError)
                return
            } else if code == 413 {
                completion(nil, GaiaError.payloadTooLargeError)
                return
            } else if code >= 500 {
                completion(nil, GaiaError.serverError)
                return
            }
            
            do {
                let jsonDecoder = JSONDecoder()
                let putfileResponse = try jsonDecoder.decode(PutFileResponse.self, from: data)
                if let url = putfileResponse.publicURL {
                    completion(url, nil)
                } else {
                    completion(nil, GaiaError.invalidResponse)
                }
            } catch {
                completion(nil, GaiaError.invalidResponse)
            }
        }
        task.resume()
    }
}

public struct MultiplayerOptions {
    let username: String
    let app: String
    let zoneFileLookupURL: URL
}

public struct PutFileResponse: Codable {
    let publicURL: String?
}

public struct PutFileOptions {
    let encrypt: Bool?
}
