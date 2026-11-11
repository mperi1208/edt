import Foundation

// ---- Configuration ----
enum Conf {
    static let host = "https://edt.uvsq.fr"
    static let federationId = "MYAMS1_26"
    static let resType = "103"
    static let rangeStart = "2026-09-01"
    static let rangeEnd   = "2027-08-31"

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("EDTUVSQ", isDirectory: true)
    }
    static var cacheFile: URL { supportDir.appendingPathComponent("data.json") }
    // Dialogue entre l'app et la barre de menus : seule cette dernière détient la
    // session Celcat, c'est donc elle qui va chercher les données.
    static let notifDemande = "perso.marcandria.edt.refreshRequest"
    static let notifTermine = "perso.marcandria.edt.refreshDone"
    // Objet de notifDemande quand la demande n'est pas un geste explicite (retour sur l'app).
    static let demandeAuto = "auto"
    // Ajouts et retouches de l'utilisateur : fichier séparé, jamais écrasé par Celcat.
    static var overridesFile: URL { supportDir.appendingPathComponent("overrides.json") }
}

// ---- Payload brut de Celcat ----
struct RawEvent: Decodable {
    let id: String?
    let start: String?
    let end: String?
    let allDay: Bool?
    let description: String?
    let eventCategory: String?
    let sites: [String]?
    let modules: [String]?
    let backgroundColor: String?
}

// ---- Séance nettoyée, transmise à l'interface ----
struct Session: Codable, Equatable {
    var id: String
    var start: String
    var end: String
    var category: String
    var module: String?
    var moduleName: String?
    var title: String
    var room: String?
    var teacher: String?
    var site: String?
    var groups: String?
}

struct Payload: Codable {
    var fetchedAt: String          // moment du dernier CHANGEMENT de l'emploi du temps
    var checkedAt: String?         // moment de la dernière vérification
    var rangeStart: String
    var rangeEnd: String
    var sessions: [Session]
}

enum EDTKit {

    // Celcat met du HTML dans `description` : on le déplie en lignes propres.
    static func decodeLines(_ raw: String) -> [String] {
        var s = raw
        s = s.replacingOccurrences(of: "<br />", with: "\n")
        s = s.replacingOccurrences(of: "<br/>", with: "\n")
        s = s.replacingOccurrences(of: "<br>", with: "\n")
        while let r = s.range(of: "&#[0-9]+;", options: .regularExpression) {
            let digits = s[r].dropFirst(2).dropLast()
            let repl = Int(digits).flatMap { UnicodeScalar($0).map { String(Character($0)) } } ?? ""
            s.replaceSubrange(r, with: repl)
        }
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        // Attention : en Swift "\r\n" est UN SEUL Character, il faut normaliser avant de découper.
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        return s.split(separator: "\n", omittingEmptySubsequences: true)
               .map { $0.trimmingCharacters(in: .whitespaces) }
               .filter { !$0.isEmpty }
    }

    // "MYANM009 - Analyse hilbertienne et distribution [MYANM009]" -> "Analyse hilbertienne et distribution"
    static func prettyModuleName(_ line: String, code: String) -> String {
        var s = line
        if let r = s.range(of: "[\(code)]") { s.removeSubrange(r) }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix(code) {
            s = String(s.dropFirst(code.count)).trimmingCharacters(in: .whitespaces)
            for sep in ["-", "_", "–"] where s.hasPrefix(sep) {
                s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // "AMPHI I - FERMAT (58 / 29) [Amphithéâtre]" -> "AMPHI I - FERMAT"
    static func shortRoom(_ s: String?) -> String? {
        guard var r = s else { return nil }
        if let i = r.firstIndex(of: "[") { r = String(r[r.startIndex..<i]) }
        if let i = r.firstIndex(of: "(") { r = String(r[r.startIndex..<i]) }
        r = r.trimmingCharacters(in: .whitespaces)
        return r.isEmpty ? nil : r
    }

    static func isBracketTitle(_ s: String) -> Bool {
        s.hasPrefix("[") && s.hasSuffix("]")
    }

    static func parse(_ raw: RawEvent) -> Session? {
        guard let start = raw.start, let end = raw.end else { return nil }
        let lines = decodeLines(raw.description ?? "")
        let category = raw.eventCategory?.trimmingCharacters(in: .whitespaces) ?? ""
        let code = raw.modules?.first

        var rest = lines
        if let first = rest.first, first == category { rest.removeFirst() }

        // Il peut y avoir PLUSIEURS lignes de groupe : toutes doivent sortir, sinon
        // la deuxième finit par "]" et se fait prendre pour une salle.
        func isGroupLine(_ l: String) -> Bool {
            l.contains("Saclay") || l.hasPrefix("M1 ") || l.hasPrefix("M2 ")
                || l.contains("[MYAMS1_26]") || l.contains("[MYMAS1_26]")
        }
        let groupLines = rest.filter(isGroupLine)
        let moduleLine = code.flatMap { c in rest.first { $0.contains(c) && !isGroupLine($0) } }

        var remaining = rest.filter { !isGroupLine($0) && $0 != moduleLine }

        // Les lignes entre crochets sont soit l'enseignant ("[ Enseignant : Pascal Moyal ]"),
        // soit un libellé ("[ Projet de groupe ]") — jamais une salle.
        var labels: [String] = []
        var teacher: String? = nil
        remaining = remaining.filter { line in
            guard isBracketTitle(line) else { return true }
            let inner = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.lowercased().hasPrefix("enseignant") {
                if let c = inner.firstIndex(of: ":") {
                    teacher = String(inner[inner.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    teacher = inner
                }
            } else {
                labels.append(inner)
            }
            return false
        }
        let bracketTitle = labels.first

        // "[MYANM012]" en fin de ligne = code module, pas une salle.
        // (Une salle finit par "[Salle de TD]", "[Amphithéâtre]"… : minuscules ou espaces.)
        func isModuleCodeLine(_ l: String) -> Bool {
            l.range(of: "\\[[A-Z][A-Z0-9_]{2,}\\]$", options: .regularExpression) != nil
        }
        remaining = remaining.filter { !isModuleCodeLine($0) }

        // Les salles n'ont pas de forme constante ("G107 - GERMAIN", "AMPHI D - DESCARTES (200 / 100)",
        // "G205 M- GERMAIN [CARTABLE NUMERIQUE ]"). En revanche le JSON donne `sites` : on s'en sert
        // pour reconnaître la ligne de salle, avec le suffixe "]" comme repli.
        var room: String? = nil
        if let site = raw.sites?.first, !site.isEmpty {
            room = remaining.first { $0.uppercased().contains(site.uppercased()) }
        }
        if room == nil { room = remaining.first { $0.hasSuffix("]") } }
        let others = remaining.filter { $0 != room }

        var title: String
        var moduleName: String? = nil
        if let c = code, let ml = moduleLine {
            moduleName = prettyModuleName(ml, code: c)
            title = moduleName ?? c
        } else if let bt = bracketTitle {
            title = bt
        } else if let o = others.first {
            title = o
        } else if !category.isEmpty {
            title = category
        } else {
            title = room ?? "Sans titre"
        }
        if title.isEmpty { title = category }

        // "MYCHP104 _ POO pour le CS (M1 CHPHS - Bâtiment Rabelais - Guyancourt)"
        var finalRoom = shortRoom((room == title) ? nil : room)
        if finalRoom == nil, let o = title.firstIndex(of: "("), title.hasSuffix(")") {
            let inside = title[title.index(after: o)..<title.index(before: title.endIndex)]
            finalRoom = inside.trimmingCharacters(in: .whitespaces)
            title = String(title[title.startIndex..<o]).trimmingCharacters(in: .whitespaces)
            while title.hasSuffix("_") || title.hasSuffix("-") { title = String(title.dropLast()).trimmingCharacters(in: .whitespaces) }
        }

        return Session(
            id: raw.id ?? UUID().uuidString,
            start: start,
            end: end,
            category: category,
            module: code,
            moduleName: moduleName,
            title: title,
            room: finalRoom,
            teacher: teacher,
            site: raw.sites?.first,
            groups: groupLines.isEmpty ? nil : groupLines.joined(separator: ", ")
        )
    }

    static func fetch() throws -> [Session] {
        var comps = URLComponents()
        comps.queryItems = [
            .init(name: "start", value: Conf.rangeStart),
            .init(name: "end", value: Conf.rangeEnd),
            .init(name: "resType", value: Conf.resType),
            .init(name: "calView", value: "month"),
            .init(name: "federationIds[]", value: Conf.federationId),
            .init(name: "colourScheme", value: "3")
        ]
        let bodyString = comps.percentEncodedQuery ?? ""

        var req = URLRequest(url: URL(string: Conf.host + "/Home/GetCalendarData")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.httpBody = bodyString.data(using: .utf8)
        req.timeoutInterval = 25

        var out: Data?
        var err: Error?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, resp, e in
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                err = NSError(domain: "EDT", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            out = d; if err == nil { err = e }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 30)

        if let e = err { throw e }
        guard let data = out else {
            throw NSError(domain: "EDT", code: -1, userInfo: [NSLocalizedDescriptionKey: "Réponse vide"])
        }
        return try sessions(fromRaw: data)
    }

    // Même conversion, mais à partir de données déjà obtenues (session navigateur).
    static func sessions(fromRaw data: Data) throws -> [Session] {
        let rawList = try JSONDecoder().decode([RawEvent].self, from: data)
        return rawList.compactMap(parse).sorted { $0.start < $1.start }
    }

    @discardableResult
    static func refreshCache(fromRaw raw: Data? = nil) throws -> Payload {
        let seances = try raw.map { try sessions(fromRaw: $0) } ?? fetch()
        let fmt = ISO8601DateFormatter()
        let maintenant = fmt.string(from: Date())

        // Si rien n'a bougé, on CONSERVE l'horodatage précédent : il désigne le dernier
        // changement réel. Sans ça, le Mac afficherait une heure qui avance toutes les
        // 30 min alors que la page iPhone, republiée seulement en cas de changement,
        // resterait sur l'ancienne — d'où deux heures qui ne concordent jamais.
        let ancien = loadPayload()
        let inchange = ancien.map { $0.sessions == seances } ?? false
        let horodatage = inchange ? (ancien?.fetchedAt ?? maintenant) : maintenant

        let payload = Payload(fetchedAt: horodatage,
                              checkedAt: maintenant,
                              rangeStart: Conf.rangeStart,
                              rangeEnd: Conf.rangeEnd,
                              sessions: seances)
        try FileManager.default.createDirectory(at: Conf.supportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(payload)
        try data.write(to: Conf.cacheFile, options: .atomic)
        return payload
    }

    // Seules les OPTIONS non choisies sont grisées (maquette M1 AMS, BCC 3). Tout le
    // reste — obligatoires, futurs cours du S2, forum, projet de groupe — reste normal.
    // Calcul formel, POO, Théorie de l'information, Optimisation et RO.
    // Analyse d'algorithmes (MYMAA006) est choisie : pas grisée.
    static let MUTED_MODULES: Set<String> = ["MYMAA002", "MYCHP104", "MYMAA008", "MYCHP200"]

    static func isMuted(_ s: Session) -> Bool {
        if let m = s.module, MUTED_MODULES.contains(m) { return true }
        let t = s.title.uppercased()
        // La POO n'a pas de code module dans Celcat, seulement dans l'intitulé.
        return t.contains("MYCHP104") || t.contains("PROGRAMMATION ORIENT")
            || t.contains("MYCHP200") || t.contains("RECHERCHE OPÉRATIONNELLE") || t.contains("RECHERCHE OPERATIONNELLE")
            || t.contains("MYMAA008") || t.contains("THÉORIE DE L'INFORMATION") || t.contains("THÉORIE DE L’INFORMATION")
            || t.contains("THEORIE DE L'INFORMATION") || t.contains("THEORIE DE L’INFORMATION")
            || t.contains("TRAJET")
    }

    static func dayKey(_ d: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    // Celcat renvoie des heures locales sans fuseau : "2026-09-14T09:40:00"
    static func parseLocal(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.date(from: s)
    }

    static func loadPayload() -> Payload? {
        guard let d = try? Data(contentsOf: Conf.cacheFile) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: d)
    }

    // Retouches de l'utilisateur, stockées à part (voir overridesFile).
    struct EditPatch: Decodable {
        var title: String?; var room: String?; var category: String?
        var start: String?; var end: String?
    }
    struct Overrides: Decodable {
        var custom: [Session]?; var edits: [String: EditPatch]?; var hidden: [String]?
    }

    static func loadOverrides() -> Overrides {
        guard let d = try? Data(contentsOf: Conf.overridesFile),
              let o = try? JSONDecoder().decode(Overrides.self, from: d)
        else { return Overrides(custom: [], edits: [:], hidden: []) }
        return o
    }

    static func mergedSessions() -> [Session] {
        guard let p = loadPayload() else { return [] }
        let o = loadOverrides()
        let hidden = Set(o.hidden ?? [])
        var out = p.sessions.filter { !hidden.contains($0.id) }.map { s -> Session in
            guard let e = o.edits?[s.id] else { return s }
            var m = s
            if let v = e.title { m.title = v }
            if let v = e.room { m.room = v }
            if let v = e.category { m.category = v }
            if let v = e.start { m.start = v }
            if let v = e.end { m.end = v }
            return m
        }
        out.append(contentsOf: o.custom ?? [])
        return out.sorted { $0.start < $1.start }
    }

    static func sessions(on day: Date) -> [Session] {
        let k = dayKey(day)
        return mergedSessions().filter { $0.start.hasPrefix(k) }
    }

    static func readCache() -> String? {
        try? String(contentsOf: Conf.cacheFile, encoding: .utf8)
    }

    static func readOverrides() -> String {
        (try? String(contentsOf: Conf.overridesFile, encoding: .utf8))
            ?? #"{"custom":[],"edits":{},"hidden":[]}"#
    }

    static func writeOverrides(_ object: Any) throws {
        try FileManager.default.createDirectory(at: Conf.supportDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: Conf.overridesFile, options: .atomic)
    }
}
