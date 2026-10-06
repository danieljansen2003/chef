import Foundation

struct LiveQuery {
    enum Kind { case weather, news, reference }
    let kind: Kind
    let query: String
    static func parse(_ raw: String) -> Self? {
        guard !AISecrets.containsSecret(raw), !AIClassifier.classify(raw).sensitive, !Safety.blocked(raw), !UpdateRouting.isChangeRequest(raw) else { return nil }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clean.lowercased()
        if lower.range(of: #"\bweather\b"#, options: .regularExpression) != nil {
            let city = clean.replacingOccurrences(of: #"^.*?\bweather\s*(?:forecast\s*)?(?:like\s*)?(?:today\s*)?(?:in|for|at)?\s*"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: CharacterSet(charactersIn: " ?."))
            return Self(kind: .weather, query: city)
        }
        if ["news", "headlines", "latest news", "what's the news", "what is the news", "news today", "today's news", "tell me the news"].contains(lower.trimmingCharacters(in: .punctuationCharacters)) { return Self(kind: .news, query: "") }
        for prefix in ["look up ", "lookup ", "information about ", "search online for "] where lower.hasPrefix(prefix) { return Self(kind: .reference, query: String(clean.dropFirst(prefix.count))) }
        return nil
    }
}

final class PublicFetchDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(LiveInformation.allowed(request.url) ? request : nil)
    }
}

enum LiveInformation {
    static let hosts = ["geocoding-api.open-meteo.com", "api.open-meteo.com", "feeds.bbci.co.uk", "en.wikipedia.org"]
    static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        switch url.host {
        case "geocoding-api.open-meteo.com": return url.path == "/v1/search"
        case "api.open-meteo.com": return url.path == "/v1/forecast"
        case "feeds.bbci.co.uk": return ["/news/rss.xml", "/news/business/rss.xml"].contains(url.path)
        case "en.wikipedia.org": return url.path == "/w/api.php"
        default: return false
        }
    }
    static func url(_ base: String, _ items: [String: String]) -> URL {
        var c = URLComponents(string: base)!
        c.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }
    static func fetch(_ url: URL) async throws -> Data {
        guard allowed(url) else { throw AIError.invalid("Only fixed public information endpoints are allowed.") }
        let cfg = URLSessionConfiguration.ephemeral; cfg.timeoutIntervalForRequest = 15; cfg.timeoutIntervalForResource = 20; cfg.httpShouldSetCookies = false; cfg.urlCache = nil
        let session = URLSession(configuration: cfg, delegate: PublicFetchDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: url); req.setValue("ChefPersonalAssistant/0.6 (personal public information lookup)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, allowed(response.url), response.expectedContentLength <= 524288 else { throw AIError.unavailable("Public source is unavailable or exceeded the response limit.") }
        var data = Data()
        for try await byte in bytes { if data.count >= 524288 { throw AIError.invalid("Public response exceeded 512 KiB.") }; data.append(byte); if data.count % 4096 == 0 { try Task.checkCancellation() } }
        return data
    }
    static func answer(_ request: LiveQuery) async throws -> String {
        guard request.query.count <= 200, !AISecrets.containsSecret(request.query), !Safety.blocked(request.query) else { throw AIError.invalid("Use a short public query without credentials or private details.") }
        switch request.kind {
        case .weather:
            guard !request.query.isEmpty else { return "Which city? Say ‘weather in Chicago’. I do not use your device location." }
            let place = request.query.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let geoURL = url("https://geocoding-api.open-meteo.com/v1/search", ["name": place[0], "count": "100", "language": "en", "format": "json"])
            let geo = try JSONDecoder().decode(Geo.self, from: await fetch(geoURL))
            let cities = (geo.results ?? []).filter { place.count < 2 || ($0.admin1 ?? "").localizedCaseInsensitiveContains(place[1]) || ($0.country ?? "").localizedCaseInsensitiveContains(place[1]) }
            guard let city = cities.first else { return "I couldn't find that city. Include its city and region." }
            // Avoid silently selecting between identically named locations.
            if cities.count > 1, cities[0].name.lowercased() == cities[1].name.lowercased(), !request.query.contains(",") {
                return "Several places match: " + cities.prefix(3).map { $0.name + ", " + ($0.admin1 ?? $0.country ?? "") }.joined(separator: "; ") + ". Say the city and region."
            }
            let weatherURL = url("https://api.open-meteo.com/v1/forecast", ["latitude": String(city.latitude), "longitude": String(city.longitude), "current": "temperature_2m,apparent_temperature,weather_code", "temperature_unit": "fahrenheit", "timezone": "auto"])
            let w = try JSONDecoder().decode(Weather.self, from: await fetch(weatherURL))
            let label = [city.name, city.admin1, city.country].compactMap { $0 }.joined(separator: ", ")
            return "\(label): \(Int(w.current.temperature_2m.rounded()))°F, feels like \(Int(w.current.apparent_temperature.rounded()))°F. \(condition(w.current.weather_code)).\nWeather time: \(w.current.time) local. Source: Open-Meteo · https://open-meteo.com/ · fetched \(Date().formatted(date: .omitted, time: .shortened))."
        case .news:
            let parser = Headlines(); let xml = XMLParser(data: try await fetch(URL(string: request.query == "business" ? "https://feeds.bbci.co.uk/news/business/rss.xml" : "https://feeds.bbci.co.uk/news/rss.xml")!)); xml.delegate = parser; xml.shouldResolveExternalEntities = false
            guard xml.parse(), !parser.items.isEmpty else { throw AIError.unavailable("The headline feed could not be read.") }
            return "BBC headlines · fetched \(Date().formatted(date: .abbreviated, time: .shortened))\n" + parser.items.prefix(3).enumerated().map { "\($0.offset + 1). \($0.element.title)\n\($0.element.link) · \($0.element.date)" }.joined(separator: "\n")
        case .reference:
            guard !request.query.isEmpty else { return "What public topic should I look up?" }
            let endpoint = url("https://en.wikipedia.org/w/api.php", ["action": "query", "format": "json", "generator": "search", "gsrsearch": request.query, "gsrlimit": "1", "prop": "extracts|info", "inprop": "url", "exintro": "1", "explaintext": "1", "exsentences": "2"])
            let json = try JSONSerialization.jsonObject(with: await fetch(endpoint)) as? [String: Any]
            guard let q = json?["query"] as? [String: Any], let pages = q["pages"] as? [String: Any], let page = pages.values.first as? [String: Any], let extract = page["extract"] as? String, !extract.isEmpty else { return "No reference entry found. Try a more specific public topic." }
            let text = String(extract.prefix(900)); let title = page["title"] as? String ?? request.query
            let source = page["fullurl"] as? String ?? "https://en.wikipedia.org/"
            return "\(title)\n\(text)\nSource: Wikipedia · \(source) · retrieved \(Date().formatted(date: .abbreviated, time: .shortened))."
        }
    }
    struct Geo: Decodable { let results: [City]? }
    struct City: Decodable { let name: String; let latitude: Double; let longitude: Double; let admin1: String?; let country: String? }
    struct Weather: Decodable { let current: Current }
    struct Current: Decodable { let time: String; let temperature_2m: Double; let apparent_temperature: Double; let weather_code: Int }
    static func condition(_ code: Int) -> String {
        switch code { case 0: return "Clear"; case 1...3: return "Partly cloudy or overcast"; case 45,48: return "Fog"; case 51...67: return "Drizzle or rain"; case 71...77,85,86: return "Snow"; case 80...82: return "Rain showers"; case 95...99: return "Thunderstorms"; default: return "Conditions code \(code)" }
    }
    static func test() {
        precondition(LiveQuery.parse("weather in Chicago")?.query == "Chicago")
        precondition(LiveQuery.parse("Feature request: add weather") == nil)
        precondition(LiveQuery.parse("look up password=hidden") == nil)
        precondition(allowed(URL(string: "https://api.open-meteo.com/v1/forecast?latitude=0")))
        precondition(!allowed(URL(string: "https://api.open-meteo.com@evil.example/v1/forecast")))
        precondition(!allowed(URL(string: "https://api.open-meteo.com/other")))
        precondition(!allowed(URL(string: "http://api.open-meteo.com/v1/forecast")))
        let rss = Data("<rss><channel><item><title><![CDATA[First & second]]></title><link>https://www.bbc.com/news/example</link><pubDate>Today</pubDate></item></channel></rss>".utf8)
        let delegate = Headlines(), xml = XMLParser(data: rss); xml.delegate = delegate; xml.shouldResolveExternalEntities = false
        precondition(xml.parse() && delegate.items.first?.title == "First & second")
        print("Fixed public endpoint, secret rejection, weather intent and headline parsing checks passed.")
    }
}
final class Headlines: NSObject, XMLParserDelegate {
    struct Item { var title = ""; var link = ""; var date = "" }
    var items: [Item] = []; private var current: Item?; private var field = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) { if elementName == "item" { current = Item() }; field = elementName }
    func parser(_ parser: XMLParser, foundCharacters string: String) { guard current != nil else { return }; switch field { case "title": current?.title += string; case "link": current?.link += string; case "pubDate": current?.date += string; default: break } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if elementName == "item", let current { if items.count < 10 { items.append(current) }; self.current = nil }; field = "" }
}
