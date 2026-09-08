import XCTest
@testable import MindBusCore

/// 扫描进度：三段各按字节接成一条 0…1；剩余时间 = 剩余字节 ÷ 速率；零变化不卡在 0。
final class ScanProgressTests: XCTestCase {

    func testFractionByPhase() {
        typealias P = ScanProgress
        XCTAssertEqual(P.fraction(phase: .idle, plannedBytes: 0, doneBytes: 0), 0)
        XCTAssertEqual(P.fraction(phase: .planning, plannedBytes: 0, doneBytes: 0), 0)
        XCTAssertEqual(P.fraction(phase: .indexing, plannedBytes: 1000, doneBytes: 500), 0.3, accuracy: 1e-9)
        XCTAssertEqual(P.fraction(phase: .indexing, plannedBytes: 1000, doneBytes: 5000), 0.6, accuracy: 1e-9, "超量不越界")
        XCTAssertEqual(P.fraction(phase: .indexing, plannedBytes: 0, doneBytes: 0), 0.6, "零变化：索引段直接记满")
        XCTAssertEqual(P.fraction(phase: .archiving, plannedBytes: 0, doneBytes: 0,
                                  archivePlannedBytes: 100, archiveDoneBytes: 50), 0.7, accuracy: 1e-9)
        XCTAssertEqual(P.fraction(phase: .archiving, plannedBytes: 0, doneBytes: 0), 0.8, "没东西要归档：段满")
        XCTAssertEqual(P.fraction(phase: .profiling, plannedBytes: 0, doneBytes: 0,
                                  profilePlannedBytes: 200, profileDoneBytes: 100), 0.875, accuracy: 1e-9)
        XCTAssertEqual(P.fraction(phase: .finishing, plannedBytes: 0, doneBytes: 0), 0.95)
        XCTAssertEqual(P.fraction(phase: .done, plannedBytes: 0, doneBytes: 0), 1)
    }

    func testRateStartsAtReferenceThenFollowsMeasurement() {
        typealias P = ScanProgress
        let ref = P.referenceRates[.indexing]!
        // 起点：没有实测 → 通用参考速率
        XCTAssertEqual(P.effectiveRate(phase: .indexing, plannedBytes: 1000, doneBytes: 0, measuredRate: nil)!, ref)
        // 跑了 5%：有实测也不理会（头几秒碰上哪种文件纯属偶然）
        XCTAssertEqual(P.effectiveRate(phase: .indexing, plannedBytes: 1000, doneBytes: 50, measuredRate: 2_000_000)!, ref)
        // 20%：几何中点
        XCTAssertEqual(P.effectiveRate(phase: .indexing, plannedBytes: 1000, doneBytes: 200, measuredRate: 2_000_000)!,
                       (ref * 2_000_000).squareRoot(), accuracy: 1e-6)
        // 30% 起：全按实测。剩 10MB、2MB/s → 5 秒
        XCTAssertEqual(P.remaining(phase: .indexing, plannedBytes: 20_000_000, doneBytes: 10_000_000,
                                   measuredRate: 2_000_000)!, 5, accuracy: 1e-9)
        // 实测荒唐地低时按 50KB/s 下限算
        XCTAssertEqual(P.remaining(phase: .archiving, plannedBytes: 500_000, doneBytes: 400_000,
                                   measuredRate: 1)!, 2, accuracy: 1e-9)
        // 收尾段不可估
        XCTAssertNil(P.remaining(phase: .finishing, plannedBytes: 0, doneBytes: 0, measuredRate: 1_000_000))
        XCTAssertEqual(P.remaining(phase: .profiling, plannedBytes: 100, doneBytes: 500, measuredRate: 1_000_000)!, 0, "超量剩余为 0")
    }

    /// 显示值像倒计时且只降不升：估算变小按比例追（至少 2 秒/秒）；估算变大原地停；没估算不显示。
    func testCountdownSmoothingNeverRises() {
        typealias P = ScanProgress
        XCTAssertNil(P.smoothedRemaining(shown: 20, raw: nil, dt: 1))
        XCTAssertEqual(P.smoothedRemaining(shown: nil, raw: 42, dt: 1)!, 42, accuracy: 1e-9, "第一次直接采用")
        XCTAssertEqual(P.smoothedRemaining(shown: 20, raw: 19, dt: 1)!, 19, accuracy: 1e-9, "正常倒数")
        XCTAssertEqual(P.smoothedRemaining(shown: 20, raw: 19.5, dt: 1)!, 19.5, accuracy: 1e-9, "减过头就停在估算值上")
        XCTAssertEqual(P.smoothedRemaining(shown: 20, raw: 10, dt: 1)!, 16.45, accuracy: 0.01, "估算变小：一秒收 28%（差 9 → 收 2.55），不是一闪到 10")
        let big = P.smoothedRemaining(shown: 300, raw: 30, dt: 1)!
        XCTAssertLessThan(big, 225, "大差距按比例追：5 分钟 → 30 秒，一秒就收掉 76 秒")
        XCTAssertEqual(P.smoothedRemaining(shown: 20, raw: 20, dt: 1)!, 20, accuracy: 1e-9, "估算没变小：原地停")
        XCTAssertEqual(P.smoothedRemaining(shown: 20, raw: 40, dt: 1)!, 20, accuracy: 1e-9, "估算变大：绝不涨")
        XCTAssertEqual(P.smoothedRemaining(shown: 0.5, raw: 0, dt: 1)!, 0, "不为负")
    }

    /// 索引段：各来源清点完之前不报时间——先到的那份只是一部分，按它报出来下一秒就得涨。
    func testNoEstimateUntilEverySourcePlanned() {
        let p = ScanProgress()
        p.begin(expectedSources: 2)
        p.addPlanned(source: .codex, bytes: 100, files: 1)
        XCTAssertEqual(p.phase, .indexing)
        XCTAssertNil(p.remainingSeconds, "还有来源没清点完")
        p.addPlanned(source: .claudeCode, bytes: 300, files: 2)
        XCTAssertNotNil(p.remainingSeconds, "都清点完了才报")
        let q = ScanProgress()
        q.begin(expectedSources: 2)
        q.sourceStarted(.claudeAgent); q.sourceFinished(.claudeAgent)   // 没东西可读的来源直接结束
        q.addPlanned(source: .codex, bytes: 100, files: 1)
        XCTAssertNotNil(q.remainingSeconds, "结束的来源也算清点完")
    }

    /// 逐文件事件按 250ms 合并发布：跑一下主 runloop 再读。
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(ScanProgress.publishInterval + 0.1))
    }

    /// 主线程上的事件序列：begin 清零 → 索引 → 归档 → 画像 → 收尾 → done。
    func testEventSequenceOnMainThread() {
        let p = ScanProgress()
        p.begin()
        XCTAssertEqual(p.phase, .planning)
        XCTAssertNil(p.remainingSeconds)
        p.addPlanned(bytes: 100, files: 2)
        p.addPlanned(bytes: 300, files: 1)
        XCTAssertEqual(p.phase, .indexing)
        XCTAssertEqual(p.plannedBytes, 400)
        XCTAssertEqual(p.plannedFiles, 3)
        XCTAssertNotNil(p.remainingSeconds, "进入索引段立刻有预估（通用参考速率）")
        p.fileDone(bytes: 100)
        settle()
        XCTAssertEqual(p.fraction, 0.15, accuracy: 1e-9)
        p.beginArchiving(totalBytes: 1000, files: 4)
        XCTAssertEqual(p.phase, .archiving)
        p.archiveFileDone(bytes: 500); p.archiveFileDone(bytes: 500)
        settle()
        XCTAssertEqual(p.fraction, 0.8, accuracy: 1e-9)
        XCTAssertEqual(p.archiveDone, 2)
        p.beginProfiling(totalBytes: 2000)
        p.profileFileDone(bytes: 1000)
        settle()
        XCTAssertEqual(p.fraction, 0.875, accuracy: 1e-9)
        p.beginFinishing()
        XCTAssertEqual(p.fraction, 0.95)
        XCTAssertNil(p.remainingSeconds)
        p.finish()
        XCTAssertEqual(p.fraction, 1)
        p.begin()
        XCTAssertEqual(p.doneBytes, 0, "新一轮从零开始")
        XCTAssertEqual(p.archiveDoneBytes, 0)
        XCTAssertEqual(p.phase, .planning)
    }
}
