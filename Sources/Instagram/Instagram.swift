import Foundation
import Combine
import SwiftUI
import AuthenticationServices
import AutomatedFetcher
import KeychainAccess


public final class Instagram : NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    public struct InstagramFetchError:Codable,Error {
        public let message:String
        public let type:String
        public let code:Int
        public let fbtraceId:String
    }
    public struct Config : Codable,Equatable {
        public let serverURL:String
        public let callbackScheme:String
        public let clientId:String
        public let keychainServiceName:String
        public let keychainCredentialsKey:String
        public init(serverURL:String, callbackScheme:String, clientId:String, keychainServiceName:String, keychainCredentialsKey:String) {
            self.serverURL = serverURL
            self.callbackScheme = callbackScheme
            self.clientId = clientId
            self.keychainServiceName = keychainServiceName
            self.keychainCredentialsKey = keychainCredentialsKey
        }
    }
    struct TempCredentials : Codable {
        let accessToken:String
        let tokenType:String
        let expiresIn:Int
    }
    struct Credentials: Codable {
        let accessToken:String
        let expires:Date
        
        func save(in keychain:Keychain, with key:String) {
            let encoder = JSONEncoder()
            do {
                keychain[data: key] = try encoder.encode(self)
            } catch {
                debugPrint(error)
            }
        }
        static func delete(from keychain:Keychain, with key:String) {
            keychain[data: key] = nil
        }
        static func load(from keychain:Keychain, with key:String) -> Credentials? {
            guard let data = keychain[data: key] else {
                return nil
            }
            let decoder = JSONDecoder()
            do {
                let credentials = try decoder.decode(Credentials.self, from: data)
                if credentials.expires < Date() {
                    delete(from: keychain, with: key)
                    return nil
                }
                return credentials
            } catch {
                debugPrint(error)
            }
            return nil
        }
    }
    public struct Media: Codable, Equatable,Identifiable {
        public enum MediaType: String, Codable, Equatable {
            case image = "IMAGE"
            case video = "VIDEO"
            case album = "CAROUSEL_ALBUM"
        }
        public let id:String
        public var caption:String?
        public let mediaUrl:URL
        public let thumbnailUrl:URL?
        public let timestamp:Date
        public let mediaType:MediaType
        public var children:[Media]
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.caption = try? values.decode(String.self, forKey: .caption)
            self.mediaUrl = try values.decode(URL.self, forKey: .mediaUrl)
            self.thumbnailUrl = try? values.decode(URL.self, forKey: .thumbnailUrl)
            self.timestamp = try values.decode(Date.self, forKey: .timestamp)
            self.id = try values.decode(String.self, forKey: .id)
            self.mediaType = try values.decode(MediaType.self, forKey: .mediaType)
            self.children = (try? values.decode([Media].self, forKey: .children))  ?? []
        }
        init(mediaUrl:URL,mediaType:MediaType) {
            self.id = UUID().uuidString
            self.mediaUrl = mediaUrl
            self.mediaType = mediaType
            self.children = []
            self.timestamp = Date()
            self.caption = "Preview image comment"
            self.thumbnailUrl = nil
        }
    }
    public struct MediaListResult: Codable, Equatable {
        public struct Paging: Codable, Equatable {
            public struct Cursors: Codable, Equatable {
                public let after:String
                public let before:String
            }
            let cursors:Cursors
            let previous:URL?
            let next:URL?
            public init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                cursors = try values.decode(Cursors.self, forKey: .cursors)
                previous = try? values.decode(URL.self, forKey: .previous)
                next = try? values.decode(URL.self, forKey: .next)
            }
        }
        public var data:[Media]
        public var paging:Paging?
    }
    public enum InstagramError : Error {
        case missingCode
        case missingCredentials
        case missingConfig
        case noShortLivedAccessToken
        case noLongLivedAccessToken
        case missingCallbackScheme
        case missingInstagramServerURL
        case invalidInstagramServerURL
        case unableToProcessURL
        case invalidAuthorizationURL
        case contextDied
        public var localizedDescription: String {
            switch self {
            case .missingCode: return "Kunde inte hitta hämta autentiseringskod-kod vid anrop mot instagram"
            case .missingCredentials: return "Saknar inloggningsuppgifter"
            case .missingConfig: return "Missing configuration"
            case .noShortLivedAccessToken: return "Kunde inte hämta access-nyckel vid anrop mot instagram"
            case .noLongLivedAccessToken: return  "Kunde inte hämta långlivad access-nyckel vid anrop mot instagram"
            case .missingCallbackScheme: return  "Saknar giltig konfiguration (callback scheme) för instagram"
            case .missingInstagramServerURL: return  "Saknar giltig konfiguration (server url) för instagram"
            case .invalidInstagramServerURL: return  "Ej giltig konfiguration (server url) för instagram"
            case .unableToProcessURL: return "Kunde inte processa url."
            case .invalidAuthorizationURL: return  "Ej giltig konfiguration (atuhorization url) för instagram"
            case .contextDied: return "Context died before completion"
            }
        }
    }
    public var config:Config? {
        didSet {
            if config == oldValue {
                return
            }
            setupKeychainAndLoadCredentials()
            if oldValue != nil {
                // remove images when configuration changes
                dataSubject.send([])
            } else {
                fetch()
            }
        }
    }
    private var keychain:Keychain?
    private var session:ASWebAuthenticationSession?
    private var publishers = Set<AnyCancellable>()
    private var state = UUID().uuidString
    internal var dataSubject = CurrentValueSubject<[Media],Never>([])
    
    private let decoder = JSONDecoder()
    private var authorizeUrl:URL? {
        state = UUID().uuidString
        guard let config = config else {
            return nil
        }
        return URL(string: "https://api.instagram.com/oauth/authorize?client_id=\(config.clientId)&redirect_uri=\(config.serverURL)/authenticated&scope=user_profile,user_media&response_type=code&state=\(state)")!
    }
    private var credentials:Credentials? {
        didSet {
            if let credentials = credentials {
                isAuthenticated = true
                if let keychain = keychain, let key = config?.keychainCredentialsKey {
                    credentials.save(in: keychain, with: key)
                }
                automatedFetcher.isOn = fetchAutomatically
                if fetchAutomatically {
                    fetch()
                }
            } else {
                publishers.removeAll()
                automatedFetcher.isOn = false
                isAuthenticated = false
                if let keychain = keychain, let key = config?.keychainCredentialsKey {
                    Credentials.delete(from: keychain, with: key)
                }
                dataSubject.send([])
            }
        }
    }
    public let latest:AnyPublisher<[Media],Never>
    @Published public private(set) var previewData:Bool = false
    @Published public internal(set) var isAuthenticated = false
    @Published public var fetchAutomatically = true {
        didSet { automatedFetcher.isOn = fetchAutomatically }
    }
    
    private let automatedFetcher:AutomatedFetcher<[Media]>
    public init(config:Config?, fetchAutomatically:Bool = true, previewData:Bool = false) {
        self.previewData = previewData
        self.config = config
        self.fetchAutomatically = fetchAutomatically
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        decoder.dateDecodingStrategy = .formatted(formatter)
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.latest = dataSubject.eraseToAnyPublisher()
        self.automatedFetcher = AutomatedFetcher<[Media]>.init(dataSubject, isOn: fetchAutomatically)
        super.init()
        self.automatedFetcher.triggered.sink { [weak self] in
            self?.fetch()
        }.store(in: &publishers)
        if fetchAutomatically {
            fetch()
        }
        self.setupKeychainAndLoadCredentials()
        self.isAuthenticated = previewData || credentials != nil
    }
    private func setupKeychainAndLoadCredentials() {
        if let config = config {
            keychain = Keychain(service: config.keychainServiceName).accessibility(.whenUnlockedThisDeviceOnly)
            if let keychain = keychain {
                credentials = Credentials.load(from: keychain, with: config.keychainCredentialsKey)
            } else {
                credentials = nil
            }
        } else {
            keychain = nil
            credentials = nil
        }
    }
    public func fetch(force:Bool = false) {
        if !isAuthenticated { return }
        if previewData {
            dataSubject.send(Self.previewData)
            return
        }
        if config == nil { return }
        if force == false && automatedFetcher.shouldFetch == false && dataSubject.value.isEmpty == false {
            return
        }
        automatedFetcher.started()
        var p:AnyCancellable?
        p = mediaPublisher().sink(receiveCompletion: { [weak self] completion in
            if case .failure(let error) = completion {
                debugPrint(error)
            }
            self?.automatedFetcher.failed()
        }, receiveValue: { [weak self] media in
            guard let this = self else {
                return
            }
            this.dataSubject.send(media)
            if let p = p {
                this.publishers.remove(p)
            }
            self?.automatedFetcher.completed()
        })
        if let p = p {
            self.publishers.insert(p)
        }
    }
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return ASPresentationAnchor()
    }
    public func logout() {
        credentials = nil
    }
    public func authorize() -> AnyPublisher<Void,Error> {
        guard let config = config else {
            return Fail(error: InstagramError.missingConfig).eraseToAnyPublisher()
        }
        guard let authorizeUrl = authorizeUrl else {
            return Fail(error: InstagramError.invalidAuthorizationURL).eraseToAnyPublisher()
        }
        let sub = PassthroughSubject<Void,Error>()
        self.session = ASWebAuthenticationSession(url: authorizeUrl, callbackURLScheme: config.callbackScheme) { [weak self ](url, err) in
            guard let this = self else {
                sub.send(completion: .failure(InstagramError.contextDied))
                return
            }
            if let err = err {
                sub.send(completion: .failure(err))
                return
            }
            guard let url = url,let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                sub.send(completion: .failure(InstagramError.unableToProcessURL))
                return
            }
            guard let code = components.queryItems?.first(where: { item in item.name == "code"})?.value else {
                sub.send(completion: .failure(InstagramError.missingCode))
                return
            }
            this.getAccessToken(code: code).sink { err in
                sub.send(completion: err)
            } receiveValue: { c in
                this.credentials = c
                sub.send()
            }.store(in: &this.publishers)
        }
        session?.presentationContextProvider = self
        session?.start()
        return sub.eraseToAnyPublisher()
    }
    private func getAccessToken(code:String) -> AnyPublisher<Credentials,Error> {
        guard let config = config else {
            return Fail(error: InstagramError.missingConfig).eraseToAnyPublisher()
        }
        guard let url = URL(string: "\(config.serverURL)/auth/\(code)") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        return URLSession.shared.dataTaskPublisher(for:URLRequest(url: url))
            .tryMap() { $0.data }
            .decode(type: TempCredentials.self, decoder: decoder)
            .map { Credentials(accessToken: $0.accessToken, expires: Date().addingTimeInterval(TimeInterval($0.expiresIn))) }
            .eraseToAnyPublisher()
    }
    private func mediaPublisher() -> AnyPublisher<[Media],Error> {
        func mediaPublisher(media:Media) -> AnyPublisher<Media,Error> {
            guard media.mediaType == .album else {
                return Result.success(media).publisher.eraseToAnyPublisher()
            }
            var media = media
            guard let credentials = credentials else {
                return Fail(error: InstagramError.missingCredentials).eraseToAnyPublisher()
            }
            guard let url = URL(string: "https://graph.instagram.com/\(media.id)/children?fields=media_url,thumbnail_url,timestamp,media_type&access_token=\(credentials.accessToken)") else {
                return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
            }
            return URLSession.shared.dataTaskPublisher(for: URLRequest(url: url))
                .tryMap() { element -> Data in
                    guard let httpResponse = element.response as? HTTPURLResponse, httpResponse.statusCode < 400 else {
                        throw (try? JSONDecoder().decode(InstagramFetchError.self, from: element.data)) ?? URLError(.badServerResponse)
                    }
                    return element.data
                }
                .decode(type: MediaListResult.self, decoder: decoder)
                .map { $0.data}
                .map {
                    media.children = $0
                    for (i,_) in media.children.enumerated() {
                        media.children[i].caption = media.caption
                    }
                    return media
                }
                .eraseToAnyPublisher()
        }
        guard let credentials = credentials else {
            return Fail(error: InstagramError.missingCredentials).eraseToAnyPublisher()
        }
        guard let url = URL(string: "https://graph.instagram.com/me/media?fields=media_url,thumbnail_url,timestamp,media_type,caption&access_token=\(credentials.accessToken)") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        return URLSession.shared.dataTaskPublisher(for: URLRequest(url: url))
            .tryMap() { element -> Data in
                guard let httpResponse = element.response as? HTTPURLResponse, httpResponse.statusCode < 400 else {
                    throw (try? JSONDecoder().decode(InstagramFetchError.self, from: element.data)) ?? URLError(.badServerResponse)
                }
                return element.data
            }
            .decode(type: MediaListResult.self, decoder: decoder)
            .map { $0.data}
            .flatMap { Publishers.MergeMany($0.map { mediaPublisher(media: $0) }).collect() }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    static public let previewInstance:Instagram = Instagram(config: Config(serverURL: "", callbackScheme: "", clientId: "", keychainServiceName: "myapp", keychainCredentialsKey: "mycredentials"), fetchAutomatically: true, previewData: true)
    static public let previewData:[Media] = [
        .init(mediaUrl: URL(string: "https://images.unsplash.com/photo-1624374984719-0d146ea066e1?ixid=MnwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHx8&ixlib=rb-1.2.1&auto=format&fit=crop&w=750&q=80")!, mediaType: .image),
        .init(mediaUrl: URL(string: "https://images.unsplash.com/photo-1628547274104-fca69938d030?ixid=MnwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHx8&ixlib=rb-1.2.1&auto=format&fit=crop&w=400&q=80")!, mediaType: .image)
    ]
}
