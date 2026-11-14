// VirtualBodyTests —— 纯逻辑测试（不需要模拟器 UI，速度快）
//
// 覆盖三块最容易悄悄坏掉的东西：
//   1. 服务器地址规整（用户手打的地址什么形态都可能有）
//   2. 网页 ↔ 原生的桥接指令解析（断了所有触觉/朗读会静默失效）
//   3. 服务端 JSON → 模型（字段名拼错会表现为「绑定成功但界面空白」）
import XCTest

final class VirtualBodyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }
}
