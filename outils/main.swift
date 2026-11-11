import Foundation

// Sans argument : va chercher les données chez Celcat (ne marche que si l'accès est public).
// Avec --from-file <chemin> : utilise des données déjà récupérées (depuis la session du navigateur).
var brut: Data? = nil
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--from-file"), i + 1 < args.count {
    let chemin = args[i + 1]
    guard let d = FileManager.default.contents(atPath: chemin) else {
        FileHandle.standardError.write("[edt-refresh] fichier illisible : \(chemin)\n".data(using: .utf8)!)
        exit(1)
    }
    brut = d
}

do {
    let p = try EDTKit.refreshCache(fromRaw: brut)
    let origine = brut == nil ? "Celcat" : "données fournies"
    FileHandle.standardError.write("[edt-refresh] OK — \(p.sessions.count) séances (\(origine))\n".data(using: .utf8)!)
    exit(0)
} catch {
    FileHandle.standardError.write("[edt-refresh] ÉCHEC — \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
