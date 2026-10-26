import WhisperKit

/// Limits language detection to Italian and English while preserving the full vocabulary.
struct BilingualTokenizer: WhisperTokenizer {
    let base: any WhisperTokenizer
    var specialTokens: SpecialTokens { base.specialTokens }
    var allLanguageTokens: Set<Int> { Set(["it", "en"].compactMap { base.convertTokenToId("<|\($0)|>") }) }
    func encode(text: String) -> [Int] { base.encode(text: text) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) { base.splitToWordTokens(tokenIds: tokenIds) }
}
