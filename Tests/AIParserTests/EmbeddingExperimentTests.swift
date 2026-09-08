import XCTest
import NaturalLanguage

/// M4 技术验证：NLEmbedding 对中文任务标题的相似度判断能力。
/// 用途：重复任务检测的召回阶段选型。
/// 注意：本文件是实验性测试，不作为 CI 门槛（数值依赖 macOS 版本的内置模型）。
final class EmbeddingExperimentTests: XCTestCase {

    struct Pair {
        let left: String
        let right: String
        let note: String
    }

    // a) 中文近义重复对（同一事项的不同表述）
    let paraphrasePairs: [Pair] = [
        Pair(left: "跟进 PRG 的 API key", right: "催一下 PRG API key 的事", note: "同义改写"),
        Pair(left: "给张三发周报", right: "发周报给张三", note: "语序调换"),
        Pair(left: "写季度总结", right: "完成季度总结文档", note: "同义扩写"),
        Pair(left: "修一下登录页面的崩溃", right: "解决登录页闪退的问题", note: "同义改写"),
        Pair(left: "约下周和客户的会议", right: "安排与客户下周的会", note: "同义改写"),
        Pair(left: "更新简历", right: "把简历改一版", note: "口语化"),
        Pair(left: "还信用卡账单", right: "缴一下信用卡的钱", note: "近义动词"),
        Pair(left: "确认发布日期", right: "跟 PM 对一下上线时间", note: "语义近似但不完全同义"),
    ]

    // b) 中文完全不同任务对
    let unrelatedPairs: [Pair] = [
        Pair(left: "买牛奶", right: "修复登录崩溃", note: "完全无关"),
        Pair(left: "给妈妈打电话", right: "部署生产环境", note: "完全无关"),
        Pair(left: "订周五的机票", right: "写数据库迁移脚本", note: "完全无关"),
        Pair(left: "洗车", right: "准备述职 PPT", note: "完全无关"),
        Pair(left: "去健身房", right: "回复供应商邮件", note: "完全无关"),
        Pair(left: "换手机电池", right: "整理会议纪要", note: "完全无关"),
    ]

    // c) 中英混输对（同一件事）
    let codeSwitchPairs: [Pair] = [
        Pair(left: "review Peter 的 PR", right: "审一下 Peter 的 pull request", note: "中英混输"),
        Pair(left: "check 一下 CI 挂了没有", right: "看下 CI 是不是失败了", note: "中英混输"),
        Pair(left: "merge 这个分支到 main", right: "把这个分支合到主干", note: "中英混输"),
        Pair(left: "debug 支付回调的问题", right: "排查支付回调的 bug", note: "中英混输"),
        Pair(left: "deploy 新版本到 staging", right: "把新版本发到预发环境", note: "中英混输"),
        Pair(left: "update 依赖版本", right: "升级一下依赖", note: "中英混输"),
    ]

    // d) 字面高度重叠但语义不同的对（理想情况下应该低分，是误报重灾区）
    let lexicalOverlapPairs: [Pair] = [
        Pair(left: "给老板汇报进度", right: "给老板汇报预算", note: "差一字，语义不同"),
        Pair(left: "修改登录页按钮颜色", right: "修改登录页按钮文案", note: "差一词，语义不同"),
        Pair(left: "备份数据库到 S3", right: "备份数据库到本地", note: "目标不同"),
        Pair(left: "买火车票去上海", right: "退火车票不去上海了", note: "动作相反"),
        Pair(left: "周一提交报销单", right: "周三提交报销单", note: "时间不同"),
        Pair(left: "发给张三的合同", right: "发给李四的合同", note: "对象不同"),
    ]

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    private func report(_ title: String, _ pairs: [Pair], similarity: (Pair) -> Double?) {
        print("\n===== \(title) =====")
        var values: [Double] = []
        for p in pairs {
            if let s = similarity(p) {
                values.append(s)
                print(String(format: "  %+.4f  「%@」 vs 「%@」   -- %@", s, p.left, p.right, p.note))
            } else {
                print("   N/A   「%@」 vs 「%@」   -- %@", p.left, p.right, p.note)
            }
        }
        if !values.isEmpty {
            let mean = values.reduce(0, +) / Double(values.count)
            print(String(format: "  --> min=%.4f  max=%.4f  mean=%.4f",
                         values.min()!, values.max()!, mean))
        }
    }

    /// 检查 sentenceEmbedding 是否支持简体中文，可用则跑全部语料
    func testSentenceEmbeddingChinese() throws {
        let zh = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese)
        print("\nsentenceEmbedding(.simplifiedChinese) = \(zh == nil ? "nil（不支持）" : "可用")")
        guard let embedding = zh else {
            print("结论：句向量不支持简体中文，需退回分词重叠度或词向量平均池化方案。")
            return
        }

        func sentenceVector(_ text: String) -> [Double]? {
            embedding.vector(for: text)
        }

        let all: [(String, [Pair])] = [
            ("a) 中文近义重复对（期望高分）", paraphrasePairs),
            ("b) 中文完全不同任务对（期望低分）", unrelatedPairs),
            ("c) 中英混输对（期望高分）", codeSwitchPairs),
            ("d) 字面重叠语义不同对（期望低分）", lexicalOverlapPairs),
        ]
        for (title, pairs) in all {
            report(title, pairs) { p in
                guard let va = sentenceVector(p.left), let vb = sentenceVector(p.right) else { return nil }
                return cosine(va, vb)
            }
        }
    }

    /// 对照：wordEmbedding 平均池化（句向量不可用时的备选）
    func testWordEmbeddingMeanPoolingChinese() throws {
        let zh = NLEmbedding.wordEmbedding(for: .simplifiedChinese)
        let en = NLEmbedding.wordEmbedding(for: .english)
        print("\nwordEmbedding(.simplifiedChinese) = \(zh == nil ? "nil" : "可用"), .english = \(en == nil ? "nil" : "可用")")
        guard let embedding = zh else { return }

        func pooled(_ text: String) -> [Double]? {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            tokenizer.setLanguage(.simplifiedChinese)
            var sum: [Double]?
            var count = 0
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let token = String(text[range])
                let vec = embedding.vector(for: token)
                    ?? embedding.vector(for: token.lowercased())
                    ?? en?.vector(for: token.lowercased()) // 中英混输时回退英文词向量
                if let vec {
                    if sum == nil { sum = vec } else {
                        for i in 0..<vec.count { sum![i] += vec[i] }
                    }
                    count += 1
                }
                return true
            }
            guard let sum, count > 0 else { return nil }
            return sum.map { $0 / Double(count) }
        }

        let all: [(String, [Pair])] = [
            ("a) 中文近义重复对（期望高分）", paraphrasePairs),
            ("b) 中文完全不同任务对（期望低分）", unrelatedPairs),
            ("c) 中英混输对（期望高分）", codeSwitchPairs),
            ("d) 字面重叠语义不同对（期望低分）", lexicalOverlapPairs),
        ]
        for (title, pairs) in all {
            report(title + " [word mean-pooling]", pairs) { p in
                guard let va = pooled(p.left), let vb = pooled(p.right) else { return nil }
                return cosine(va, vb)
            }
        }
    }

    /// 列出当前 macOS 上 NLEmbedding 实际支持的语言
    func testAvailableEmbeddingLanguages() {
        print("\n===== 可用语言清单 =====")
        let languages: [NLLanguage] = [
            .simplifiedChinese, .traditionalChinese, .english, .japanese, .korean,
            .french, .german, .italian, .spanish, .portuguese, .russian,
            .dutch, .swedish, .thai, .turkish, .vietnamese, .arabic, .hindi,
            .polish, .czech, .greek, .hebrew, .indonesian, .ukrainian,
            .romanian, .slovak, .danish, .finnish, .norwegian, .croatian,
            .malay, .bulgarian, .catalan, .hungarian, .undetermined,
        ]
        for lang in languages {
            let s = NLEmbedding.sentenceEmbedding(for: lang) != nil ? "✓" : "·"
            let w = NLEmbedding.wordEmbedding(for: lang) != nil ? "✓" : "·"
            print("  \(lang.rawValue.padding(toLength: 24, withPad: " ", startingAt: 0)) sentence:\(s)  word:\(w)")
        }
    }
}
