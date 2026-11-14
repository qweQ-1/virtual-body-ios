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
