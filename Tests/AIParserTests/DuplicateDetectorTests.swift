import XCTest
@testable import AIParser
import RuleEngine

/// DuplicateDetector 召回阶段测试（LLM 判定不可测，不在此覆盖）。
/// 语料模式与 EmbeddingExperimentTests 一致；NLEmbedding 在测试环境可用（实验已验证）。
final class DuplicateDetectorTests: XCTestCase {

    private func task(_ id: Int64, _ title: String, _ status: TaskStatus = .today) -> TaskSnapshot {
        TaskSnapshot(id: id, title: title, status: status, updatedAt: Date())
    }

    private func recalled(_ candidates: [DuplicateCandidate], _ a: Int64, _ b: Int64) -> DuplicateCandidate? {
        candidates.first { $0.id == "\(min(a, b))-\(max(a, b))" }
    }

    /// 中文近义对：同一事项的不同表述，应被召回
    func testParaphrasePairsRecalled() {
        let pairs: [(String, String)] = [
            ("跟进 PRG 的 API key", "催一下 PRG API key 的事"),
            ("给张三发周报", "发周报给张三"),
            ("写季度总结", "完成季度总结文档"),
            ("修一下登录页面的崩溃", "解决登录页闪退的问题"),
            ("约下周和客户的会议", "安排与客户下周的会"),
            ("更新简历", "把简历改一版"),
            ("还信用卡账单", "缴一下信用卡的钱"),
            ("确认发布日期", "跟 PM 对一下上线时间"),
        ]
        var hit = 0
        for (index, pair) in pairs.enumerated() {
            let a = Int64(index * 2 + 1), b = Int64(index * 2 + 2)
            let candidates = DuplicateDetector.recallCandidates(tasks: [
                task(a, pair.0), task(b, pair.1),
            ])
            if let c = recalled(candidates, a, b) {
                hit += 1
                print(String(format: "  HIT %.4f 「%@」 vs 「%@」", c.similarity, pair.0, pair.1))
            } else {
                print("  MISS     「\(pair.0)」 vs 「\(pair.1)」")
            }
            XCTAssertNotNil(recalled(candidates, a, b), "近义对未召回：\(pair.0) / \(pair.1)")
        }
        print("近义对命中率：\(hit)/\(pairs.count)")
    }

    /// 中英混输对：同一件事，应被召回
    func testCodeSwitchPairsRecalled() {
        let pairs: [(String, String)] = [
            ("review Peter 的 PR", "审一下 Peter 的 pull request"),
            ("check 一下 CI 挂了没有", "看下 CI 是不是失败了"),
            ("merge 这个分支到 main", "把这个分支合到主干"),
            ("debug 支付回调的问题", "排查支付回调的 bug"),
            ("deploy 新版本到 staging", "把新版本发到预发环境"),
            ("update 依赖版本", "升级一下依赖"),
        ]
        var hit = 0
        for (index, pair) in pairs.enumerated() {
            let a = Int64(index * 2 + 1), b = Int64(index * 2 + 2)
            let candidates = DuplicateDetector.recallCandidates(tasks: [
                task(a, pair.0), task(b, pair.1),
            ])
            if let c = recalled(candidates, a, b) {
                hit += 1
                print(String(format: "  HIT %.4f 「%@」 vs 「%@」", c.similarity, pair.0, pair.1))
            } else {
                print("  MISS     「\(pair.0)」 vs 「\(pair.1)」")
            }
            XCTAssertNotNil(recalled(candidates, a, b), "中英混输对未召回：\(pair.0) / \(pair.1)")
        }
        print("中英混输对命中率：\(hit)/\(pairs.count)")
    }

    /// 完全无关对：不应被召回
    func testUnrelatedPairsNotRecalled() {
        let pairs: [(String, String)] = [
            ("买牛奶", "修复登录崩溃"),
            ("给妈妈打电话", "部署生产环境"),
            ("订周五的机票", "写数据库迁移脚本"),
            ("洗车", "准备述职 PPT"),
            ("去健身房", "回复供应商邮件"),
            ("换手机电池", "整理会议纪要"),
        ]
        for (index, pair) in pairs.enumerated() {
            let a = Int64(index * 2 + 1), b = Int64(index * 2 + 2)
            let candidates = DuplicateDetector.recallCandidates(tasks: [
                task(a, pair.0), task(b, pair.1),
            ])
            XCTAssertNil(recalled(candidates, a, b), "无关对被误召回：\(pair.0) / \(pair.1)")
        }
    }

    /// 归一化标题完全相等（仅空白/标点差异）的对 similarity 记 1.0 直接进候选
    func testNormalizedEqualTitlesScoreOne() {
        let candidates = DuplicateDetector.recallCandidates(tasks: [
            task(1, "写季度总结"), task(2, " 写 季度总结！"),
        ])
        let c = recalled(candidates, 1, 2)
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.similarity, 1.0)
    }

    /// done 任务不参与比较
    func testDoneTasksExcluded() {
        let candidates = DuplicateDetector.recallCandidates(tasks: [
            task(1, "写季度总结"),
            task(2, "写季度总结", .done),
            task(3, "写季度总结"),
        ])
        XCTAssertNil(recalled(candidates, 1, 2), "done 任务不应参与比较")
        XCTAssertNil(recalled(candidates, 2, 3), "done 任务不应参与比较")
        XCTAssertNotNil(recalled(candidates, 1, 3))
        XCTAssertEqual(candidates.count, 1)
    }

    /// maxPairs 封顶生效
    func testMaxPairsCap() {
        // 6 条同标题任务 → 15 对全等候选，封顶 3
        let tasks = (1...6).map { task(Int64($0), "写季度总结") }
        let candidates = DuplicateDetector.recallCandidates(tasks: tasks, maxPairs: 3)
        XCTAssertEqual(candidates.count, 3)
    }

    /// 同一对只出现一次，id 小者在前（标题与 id 对应）
    func testIDNormalization() {
        let candidates = DuplicateDetector.recallCandidates(tasks: [
            task(9, "给张三发周报"), task(3, "发周报给张三"),
        ])
        XCTAssertEqual(candidates.count, 1)
        let c = candidates[0]
        XCTAssertEqual(c.firstID, 3)
        XCTAssertEqual(c.secondID, 9)
        XCTAssertEqual(c.firstTitle, "发周报给张三")
        XCTAssertEqual(c.secondTitle, "给张三发周报")
        XCTAssertEqual(c.id, "3-9")
    }

    /// 候选按 similarity 降序
    func testCandidatesSortedBySimilarityDescending() {
        let candidates = DuplicateDetector.recallCandidates(tasks: [
            task(1, "写季度总结"),
            task(2, "写季度总结"),       // 与 1 全等 → 1.0
            task(3, "完成季度总结文档"),   // 与 1/2 近义 → < 1.0
            task(4, "买牛奶"),           // 无关
        ])
        XCTAssertGreaterThanOrEqual(candidates.count, 3)
        for (a, b) in zip(candidates, candidates.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.similarity, b.similarity)
        }
        XCTAssertEqual(candidates.first?.similarity, 1.0)
    }
}
