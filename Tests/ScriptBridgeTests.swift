import XCTest
@testable import VirtualBody

/// 网页 → 原生 的桥：这条链断了，前端的一切触觉/朗读都会静默失效，
/// 所以指令解析必须严格覆盖（含"未知指令不能崩"）。
final class ScriptBridgeTests: XCTestCase {

    // MARK: 正常指令

    func testHapticUsesGivenStyle() {
        guard case .haptic(let style)? = ScriptBridge.parse(body: ["cmd": "haptic", "style": "heavy"]) else {
            return XCTFail("没解析出 haptic")
        }
        XCTAssertEqual(style, "heavy")
    }

    func testHapticDefaultsToLight() {
        guard case .haptic(let style)? = ScriptBridge.parse(body: ["cmd": "haptic"]) else {
            return XCTFail("没解析出 haptic")
        }
        XCTAssertEqual(style, "light")
    }

    func testSpeakCarriesTextAndLang() {
        guard case .speak(let text, let lang)? = ScriptBridge.parse(
            body: ["cmd": "speak", "text": "你好呀", "lang": "zh-TW"]
        ) else { return XCTFail("没解析出 speak") }
        XCTAssertEqual(text, "你好呀")
        XCTAssertEqual(lang, "zh-TW")
    }

    func testSpeakDefaultsToMandarin() {
        guard case .speak(_, let lang)? = ScriptBridge.parse(body: ["cmd": "speak", "text": "hi"]) else {
            return XCTFail("没解析出 speak")
        }
        XCTAssertEqual(lang, "zh-CN")
    }

    func testSpeakAcceptsNumericText() {
        guard case .speak(let text, _)? = ScriptBridge.parse(
            body: ["cmd": "speak", "text": NSNumber(value: 42)]
        ) else { return XCTFail("数字形式的 text 应当被宽容接受") }
        XCTAssertEqual(text, "42")
    }

    func testStopSpeakAliases() {
        for alias in ["stop_speak", "stopspeak", "stop"] {
            guard case .stopSpeak? = ScriptBridge.parse(body: ["cmd": alias]) else {
                return XCTFail("别名 \(alias) 没被识别成 stopSpeak")
            }
        }
    }

    func testUnbind() {
        guard case .unbind? = ScriptBridge.parse(body: ["cmd": "unbind"]) else {
            return XCTFail("没解析出 unbind")
        }
    }

    func testOpenSettingsAliases() {
        for alias in ["open_settings", "opensettings", "settings"] {
            guard case .openSettings? = ScriptBridge.parse(body: ["cmd": alias]) else {
                return XCTFail("别名 \(alias) 没被识别成 openSettings")
            }
        }
    }

    func testLogAndStatus() {
        guard case .log(let message)? = ScriptBridge.parse(body: ["cmd": "log", "message": "hi"]) else {
            return XCTFail("没解析出 log")
        }
        XCTAssertEqual(message, "hi")

        guard case .status(let text, let level)? = ScriptBridge.parse(
            body: ["cmd": "status", "text": "已连接", "level": "ok"]
        ) else { return XCTFail("没解析出 status") }
        XCTAssertEqual(text, "已连接")
        XCTAssertEqual(level, "ok")
    }

    func testStatusLevelDefaultsToOK() {
        guard case .status(_, let level)? = ScriptBridge.parse(body: ["cmd": "status", "text": "x"]) else {
            return XCTFail("没解析出 status")
        }
        XCTAssertEqual(level, "ok")
    }

    // MARK: 健壮性：这些都必须被安静忽略、绝不崩

    func testCmdIsCaseAndWhitespaceInsensitive() {
        guard case .haptic? = ScriptBridge.parse(body: ["cmd": "  HAPTIC  "]) else {
            return XCTFail("cmd 应当大小写不敏感且去空白")
        }
    }

    func testMissingCmdIsIgnored() {
        XCTAssertNil(ScriptBridge.parse(body: ["style": "heavy"]))
    }

    func testEmptyCmdIsIgnored() {
        XCTAssertNil(ScriptBridge.parse(body: ["cmd": "   "]))
    }

    func testSpeakWithoutTextIsIgnored() {
        XCTAssertNil(ScriptBridge.parse(body: ["cmd": "speak"]))
        XCTAssertNil(ScriptBridge.parse(body: ["cmd": "speak", "text": ""]))
    }

    func testStatusWithoutTextIsIgnored() {
        XCTAssertNil(ScriptBridge.parse(body: ["cmd": "status"]))
    }

    func testUnknownCommandFallsThroughWithoutCrashing() {
        guard case .unknown(let cmd)? = ScriptBridge.parse(body: ["cmd": "teleport"]) else {
            return XCTFail("未知指令应当变成 .unknown")
        }
        XCTAssertEqual(cmd, "teleport")
    }

    // MARK: 注入脚本

    func testConfigScriptIsValidJSONAssignment() throws {
        let server = "https://a.example/pet"
        let token = "0123456789abcdef0123456789abcdef"
        let script = ScriptBridge.configScript(server: server, token: token)

        XCTAssertTrue(script.hasPrefix("window.VB_CONFIG = "))
        XCTAssertTrue(script.hasSuffix(";"))

        let json = String(script.dropFirst("window.VB_CONFIG = ".count).dropLast())
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["server"] as? String, server)
        XCTAssertEqual(object["token"] as? String, token)
        XCTAssertEqual(object["platform"] as? String, "ios")
        XCTAssertEqual(object["native"] as? Bool, true)
    }

    /// 地址里带尖括号、U+2028 这类字符时不能逃出脚本（会导致整个页面 JS 报错）。
    func testConfigScriptEscapesDangerousCharacters() {
        let script = ScriptBridge.configScript(server: "https://a.example/</script>", token: "t")
        XCTAssertFalse(script.contains("</script>"))
        XCTAssertTrue(script.contains("\\u003C"))
    }
}
