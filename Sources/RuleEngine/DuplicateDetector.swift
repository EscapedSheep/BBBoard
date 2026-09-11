import Foundation
import NaturalLanguage

/// 召回阶段产出的一对疑似重复任务
public struct DuplicateCandidate: Sendable, Equatable, Identifiable {
    public var firstID: Int64
    public var secondID: Int64
    public var firstTitle: String
    public var secondTitle: String
    /// 召回相似度（两路取高）
    public var similarity: Double
    public var id: String { "\(min(firstID, secondID))-\(max(firstID, secondID))" }

    public init(firstID: Int64, secondID: Int64, firstTitle: String, secondTitle: String, similarity: Double) {
        self.firstID = firstID
        self.secondID = secondID
        self.firstTitle = firstTitle
        self.secondTitle = secondTitle
        self.similarity = similarity
    }
}

/// 判定后输出给用户的一对重复任务（含理由）
public struct DuplicatePair: Sendable, Equatable, Identifiable {
    public var candidate: DuplicateCandidate
    /// 中文理由（规则路径的固定文案）
    public var reason: String
    public var id: String { candidate.id }

    public init(candidate: DuplicateCandidate, reason: String) {
        self.candidate = candidate
        self.reason = reason
    }
}

/// Smart Cleanup：重复任务检测，纯规则。
/// 召回双路（词向量平均池化 cosine + 分词集合 Jaccard），再经保守规则过滤
/// （Jaccard ≥ 0.8 或归一化标题相等），误报宁少勿多。
/// 注意：NLEmbedding.sentenceEmbedding 中文不可用（实验已否决），这里只用 wordEmbedding。
public enum DuplicateDetector {
    /// 词向量平均池化 cosine 召回阈值（实验选型结论）
    static let cosineThreshold = 0.25
    /// 分词集合 Jaccard 召回阈值（实验选型结论）
    static let jaccardThreshold = 0.5
    /// 出提案的保守 Jaccard 阈值（误报宁少勿多）
    static let pairJaccardThreshold = 0.8

    /// 纯召回（可单测）：双路召回合并去重，按 similarity 降序。
    /// 只比较非 done 任务；同一对只出现一次（id 小者在前）。
    public static func recallCandidates(tasks: [TaskSnapshot], maxPairs: Int = 20) -> [DuplicateCandidate] {
        guard maxPairs > 0 else { return [] }
        let active = tasks.filter { $0.status != .done }
        let zh = NLEmbedding.wordEmbedding(for: .simplifiedChinese)
        let en = NLEmbedding.wordEmbedding(for: .english)
        let features = active.map { TitleFeatures(title: $0.title, zh: zh, en: en) }

        var candidates: [DuplicateCandidate] = []
        for i in 0..<active.count {
            for j in (i + 1)..<active.count {
                guard let similarity = recallScore(features[i], features[j]) else { continue }
                let (first, second) = active[i].id <= active[j].id
                    ? (active[i], active[j])
                    : (active[j], active[i])
                candidates.append(DuplicateCandidate(
                    firstID: first.id,
                    secondID: second.id,
                    firstTitle: first.title,
                    secondTitle: second.title,
                    similarity: similarity
                ))
            }
        }
        return Array(candidates.sorted {
            $0.similarity != $1.similarity ? $0.similarity > $1.similarity : $0.id < $1.id
        }.prefix(maxPairs))
    }

    /// 完整管线：召回 → 保守规则过滤（只保留 Jaccard ≥ 0.8 或归一化标题相等的对）。
    public static func findDuplicates(tasks: [TaskSnapshot]) -> [DuplicatePair] {
        recallCandidates(tasks: tasks)
            .filter(conservativePass)
            .map { DuplicatePair(candidate: $0, reason: "标题高度相似") }
            .sorted {
                $0.candidate.similarity != $1.candidate.similarity
                    ? $0.candidate.similarity > $1.candidate.similarity
                    : $0.id < $1.id
            }
    }

    /// 保守规则：只保留 Jaccard ≥ 0.8 或归一化标题相等的对。
    private static func conservativePass(_ candidate: DuplicateCandidate) -> Bool {
        let a = normalize(candidate.firstTitle)
        let b = normalize(candidate.secondTitle)
        if !a.isEmpty, a == b { return true }
        return jaccard(tokenSet(candidate.firstTitle), tokenSet(candidate.secondTitle))
            >= pairJaccardThreshold
    }

    // MARK: - 召回打分

    private struct TitleFeatures {
        let normalized: String
        let tokens: Set<String>
        /// L2 归一化后的池化向量；任一路词向量不可用或全部 OOV 时为 nil
        let vector: [Double]?

        init(title: String, zh: NLEmbedding?, en: NLEmbedding?) {
            normalized = DuplicateDetector.normalize(title)
            tokens = DuplicateDetector.tokenSet(title)
            vector = DuplicateDetector.pooledVector(title, zh: zh, en: en)
        }
    }

    /// 两路各自过阈值即为候选；两路都触发取高分。
    private static func recallScore(_ a: TitleFeatures, _ b: TitleFeatures) -> Double? {
        if !a.normalized.isEmpty, a.normalized == b.normalized { return 1.0 }
        var best: Double?
        if let va = a.vector, let vb = b.vector {
            let cosine = dot(va, vb) // 向量已 L2 归一化，点积即 cosine
            if cosine >= cosineThreshold { best = cosine }
        }
        let jaccard = jaccard(a.tokens, b.tokens)
        if jaccard >= jaccardThreshold {
            best = max(best ?? 0, jaccard)
        }
        return best
    }

    // MARK: - 文本特征

    /// 归一化标题：小写、去空白与标点，用于完全相等判定。
    static func normalize(_ title: String) -> String {
        title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    /// Jaccard 用分词集合：zh-Hans 分词、小写、去纯标点/空白 token、去单字停用词。
    static func tokenSet(_ title: String) -> Set<String> {
        let stopwords: Set<String> = ["的", "了", "一下"]
        return Set(tokenize(title).map { $0.lowercased() }.filter {
            $0.rangeOfCharacter(from: .alphanumerics) != nil && !stopwords.contains($0)
        })
    }

    /// 词向量平均池化：zh-Hans 词向量，英文/数字 token 回退 en 词向量；结果 L2 归一化。
    static func pooledVector(_ title: String, zh: NLEmbedding?, en: NLEmbedding?) -> [Double]? {
        guard let zh else { return nil }
        var sum: [Double]?
        var count = 0
        for token in tokenize(title) {
            let vec = zh.vector(for: token)
                ?? zh.vector(for: token.lowercased())
                ?? en?.vector(for: token.lowercased()) // 中英混输时回退英文词向量
            if let vec {
                if sum == nil {
                    sum = vec
                } else {
                    for i in 0..<vec.count { sum![i] += vec[i] }
                }
                count += 1
            }
        }
        guard let sum, count > 0 else { return nil }
        let mean = sum.map { $0 / Double(count) }
        let norm = mean.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return nil }
        return mean.map { $0 / norm }
    }

    private static func tokenize(_ title: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.string = title
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: title.startIndex..<title.endIndex) { range, _ in
            tokens.append(String(title[range]))
            return true
        }
        return tokens
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var result = 0.0
        for i in 0..<min(a.count, b.count) { result += a[i] * b[i] }
        return result
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b)
        guard !union.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(union.count)
    }
}
