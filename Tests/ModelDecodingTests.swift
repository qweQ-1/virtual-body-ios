import XCTest
@testable import VirtualBody

/// 服务端信封 → 模型 的解码。这几个模型是 App 与插件唯一的数据契约，
/// 字段名拼错会导致「绑定成功但界面是空的」这种最难查的问题。
final class ModelDecodingTests: XCTestCase {

    private func envelope(_ json: String) throws -> Data {
        try XCTUnwrap(json.data(using: .utf8))
    }

    func testHelloUsesSnakeCaseServerTime() throws {
        let data = try envelope(#"""
        {"ok":true,"data":{"service":"virtual-body","version":"1.0.0","bound":true,"server_time":1763100000}}
        """#)
        let env = try JSONDecoder().decode(VBEnvelope<VBHello>.self, from: data)
        XCTAssertTrue(env.ok)
        XCTAssertEqual(env.data?.service, "virtual-body")
        XCTAssertEqual(env.data?.bound, true)
        XCTAssertEqual(env.data?.serverTime, 1763100000)
    }

    func testBindDecodesTokenAndCharacter() throws {
        let data = try envelope(#"""
        {"ok":true,"data":{"token":"abc123","qq":"10001","nickname":"阿蓝",
         "character":{"id":"vb1","name":"小虚","level":3,"exp":120,"exp_next":300,
          "emotion":"happy","action":"idle","outfit":"default","room":"day",
          "owner_qq":"10001","bubble":"你回来啦～",
          "stats":{"affection":62,"mood":80,"energy":70,"satiety":55,"clean":90,"trust":45}}}}
        """#)
        let env = try JSONDecoder().decode(VBEnvelope<VBBind>.self, from: data)
        let bind = try XCTUnwrap(env.data)
        XCTAssertEqual(bind.token, "abc123")
        XCTAssertEqual(bind.qq, "10001")
        XCTAssertEqual(bind.nickname, "阿蓝")
        XCTAssertEqual(bind.character?.name, "小虚")
        XCTAssertEqual(bind.character?.level, 3)
        XCTAssertEqual(bind.character?.expNext, 300)
        XCTAssertEqual(bind.character?.ownerQQ, "10001")
        XCTAssertEqual(bind.character?.stats?.affection, 62)
        XCTAssertEqual(bind.character?.stats?.trust, 45)
    }

    func testErrorEnvelopeDecodesWithoutData() throws {
        let data = try envelope(#"""
        {"ok":false,"error":"bad_code","message":"绑定码错误或已过期"}
        """#)
        let env = try JSONDecoder().decode(VBEnvelope<VBBind>.self, from: data)
        XCTAssertFalse(env.ok)
        XCTAssertNil(env.data)
        XCTAssertEqual(env.error, "bad_code")
        XCTAssertEqual(env.message, "绑定码错误或已过期")
    }

    /// 服务端加字段不能把 App 弄崩（模型里只声明用到的字段即可）。
    func testUnknownFieldsAreIgnored() throws {
        let data = try envelope(#"""
        {"ok":true,"data":{"character":{"name":"小虚","future_field":{"a":[1,2,3]}},"last_id":41,"events":[]}}
        """#)
        let env = try JSONDecoder().decode(VBEnvelope<VBState>.self, from: data)
        XCTAssertEqual(env.data?.character?.name, "小虚")
    }

    /// 新版服务端如果暂时没给某些字段，界面应该还能渲染（全部可选）。
    func testSparseCharacterStillDecodes() throws {
        let data = try envelope(#"{"ok":true,"data":{"character":{"name":"小虚"}}}"#)
        let env = try JSONDecoder().decode(VBEnvelope<VBState>.self, from: data)
        let character = try XCTUnwrap(env.data?.character)
        XCTAssertEqual(character.name, "小虚")
        XCTAssertNil(character.level)
        XCTAssertNil(character.stats)
    }
}

/// 线上真实响应回归测试。
/// 这两条对应 2026-11-14 真机报「服务器返回的数据看不懂」的两次事故：
///   1. stats 是浮点（30.8），模型写成 Int? → 整个 bind 响应解码失败
///   2. character 里没有 owner_qq，模型声明了却当成必填语义 → 同样会炸
final class RealResponseRegressionTests: XCTestCase {

    /// 照线上 /api/bind 的真实返回 1:1 抄下来（只截短了 bubble 文本）
    private let realBindJSON = #"""
    {"ok":true,"data":{
      "token":"0123456789abcdef0123456789abcdef",
      "qq":"3613991290",
      "nickname":"",
      "character":{
        "id":"vb1","name":"小虚","level":1,"exp":29,"exp_next":120,
        "stats":{"affection":30.8,"mood":82.2,"energy":76.1,"satiety":82.1,"clean":85.0,"trust":11.2},
        "emotion":"happy","action":"nod",
        "pose":{"x":0.5,"y":0.62,"facing":1,"scale":1.0},
        "outfit":"default","room":"day","bubble":"晚上好呀。",
        "counters":{"pets":3,"pokes":1,"feeds":2,"chats":5,"touches":9},
        "last_active":1794670393.3454916,
        "created_at":1794657928.8093565,
        "updated_at":1794670393.3454924
      }}}
    """#

    func testRealBindResponseDecodes() throws {
        let data = try XCTUnwrap(realBindJSON.data(using: .utf8))
        let env = try JSONDecoder().decode(VBEnvelope<VBBind>.self, from: data)
        XCTAssertTrue(env.ok)

        let bind = try XCTUnwrap(env.data, "线上真实响应必须能解出 data")
        XCTAssertEqual(bind.qq, "3613991290")
        XCTAssertEqual(bind.character?.name, "小虚")

        // 关键：浮点数值不能丢精度，也不能让解码失败
        let stats = try XCTUnwrap(bind.character?.stats)
        XCTAssertEqual(stats.affection!, 30.8, accuracy: 0.001)
        XCTAssertEqual(stats.trust!, 11.2, accuracy: 0.001)
    }

    func testStatsRoundToPercentForDisplay() throws {
        let stats = VBStats(affection: 30.8, mood: 82.2, energy: 76.1,
                            satiety: 82.1, clean: 85.0, trust: 11.2)
        XCTAssertEqual(stats.percent(stats.affection), 31)
        XCTAssertEqual(stats.percent(stats.mood), 82)
        XCTAssertEqual(stats.percent(nil), 0)
        // 越界值也要被夹住，避免进度条宽度算出负数
        XCTAssertEqual(stats.percent(120.4), 100)
        XCTAssertEqual(stats.percent(-3.0), 0)
    }

    func testCharacterWithoutOwnerFieldStillDecodes() throws {
        let json = #"{"ok":true,"data":{"character":{"name":"小虚","level":2}}}"#
        let env = try JSONDecoder().decode(VBEnvelope<VBState>.self,
                                           from: XCTUnwrap(json.data(using: .utf8)))
        let character = try XCTUnwrap(env.data?.character)
        XCTAssertEqual(character.name, "小虚")
        XCTAssertNil(character.ownerQQ, "服务端没有 owner 字段时应当为 nil，而不是解码失败")
    }
}
