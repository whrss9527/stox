import Foundation

/// 外部链接只接受已知命令和证券代码，不转交任意URL或脚本。
public enum StoxLink: Equatable, Sendable {
    case show
    case add(Symbol)
    case quote(Symbol)

    public init?(_ url: URL) {
        guard url.absoluteString.utf8.count <= 4096,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "stox", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else { return nil }
        let query = parts.queryItems ?? []
        switch parts.host?.lowercased() {
        case "show":
            guard query.isEmpty else { return nil }
            self = .show
        case "add", "quote":
            guard query.count == 1, query[0].name == "code", let code = query[0].value,
                  !code.isEmpty, code.utf8.count <= 64,
                  !code.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let symbol = SymbolInput.parse(code) else { return nil }
            self = parts.host?.lowercased() == "add" ? .add(symbol) : .quote(symbol)
        default: return nil
        }
    }
}
