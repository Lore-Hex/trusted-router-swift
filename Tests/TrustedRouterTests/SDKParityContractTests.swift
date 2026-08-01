import XCTest
@testable import TrustedRouter

final class SDKParityContractTests: XCTestCase {
    func testStableRoutingAndOrchestrationAliases() {
        XCTAssertEqual(TrustedRouterConstants.zdrModel, "trustedrouter/zdr")
        XCTAssertEqual(TrustedRouterConstants.e2eModel, "trustedrouter/e2e")
        XCTAssertEqual(TrustedRouterConstants.confidentialModel, "trustedrouter/confidential")
        XCTAssertEqual(TrustedRouterConstants.usModel, "trustedrouter/us")
        XCTAssertEqual(TrustedRouterConstants.synthModel, "trustedrouter/synth")
        XCTAssertEqual(TrustedRouterConstants.selectorModel, "trustedrouter/selector")
        XCTAssertEqual(TrustedRouterConstants.mapReduceModel, "trustedrouter/mapreduce")
        XCTAssertEqual(TrustedRouterConstants.subagentModel, "trustedrouter/subagent")
    }

    func testAllAtomicOrchestrationBuildersUseGatewaySchema() {
        let fusion = TrustedRouter.fusionTool(enabled: false)
        let fusionParameters = fusion["parameters"] as? [String: Any]
        XCTAssertEqual(fusionParameters?["enabled"] as? Bool, false)

        let advisor = TrustedRouter.advisorTool(
            enabled: true,
            workerTimeoutMilliseconds: 45_000,
            autoInitialAdvice: true
        )
        let advisorParameters = advisor["parameters"] as? [String: Any]
        XCTAssertEqual(advisorParameters?["enabled"] as? Bool, true)
        XCTAssertEqual(advisorParameters?["worker_timeout_ms"] as? Int, 45_000)
        XCTAssertEqual(advisorParameters?["auto_initial_advice"] as? Bool, true)

        let selector = TrustedRouter.selectorTool(
            enabled: true,
            analysisModels: ["panel/a", "panel/b"],
            selectorModels: ["selector/a"],
            selectorPrompt: "pick verbatim",
            maxCompletionTokens: 128
        )
        XCTAssertEqual(selector["type"] as? String, "trustedrouter:selector")
        let selectorParameters = selector["parameters"] as? [String: Any]
        XCTAssertEqual(selectorParameters?["enabled"] as? Bool, true)
        XCTAssertEqual(selectorParameters?["analysis_models"] as? [String], ["panel/a", "panel/b"])
        XCTAssertEqual(selectorParameters?["selector_models"] as? [String], ["selector/a"])
        XCTAssertEqual(selectorParameters?["selector_prompt"] as? String, "pick verbatim")
        XCTAssertEqual(selectorParameters?["max_completion_tokens"] as? Int, 128)

        let mapReduce = TrustedRouter.mapReduceTool(
            enabled: true,
            mapperModels: ["mapper/a"],
            parallelModels: ["worker/a"],
            reducerModels: ["reducer/a"],
            maxParts: 8,
            mapperPrompt: "split",
            parallelPrompt: "solve",
            reducerPrompt: "merge",
            maxCompletionTokens: 256
        )
        XCTAssertEqual(mapReduce["type"] as? String, "trustedrouter:mapreduce")
        let mapReduceParameters = mapReduce["parameters"] as? [String: Any]
        XCTAssertEqual(mapReduceParameters?["enabled"] as? Bool, true)
        XCTAssertEqual(mapReduceParameters?["max_parts"] as? Int, 8)
        XCTAssertEqual(mapReduceParameters?["parallel_prompt"] as? String, "solve")

        let subagent = TrustedRouter.subagentTool(
            enabled: true,
            controllerModel: "controller/a",
            model: "worker/a",
            instructions: "delegate",
            depth: 2,
            maxSubagentCalls: 3,
            maxCompletionTokens: 512,
            temperature: 0.2,
            reasoning: ["effort": "high"],
            tools: [["type": "function"]]
        )
        XCTAssertEqual(subagent["type"] as? String, "trustedrouter:subagent")
        let subagentParameters = subagent["parameters"] as? [String: Any]
        XCTAssertEqual(subagentParameters?["enabled"] as? Bool, true)
        XCTAssertEqual(subagentParameters?["controller_model"] as? String, "controller/a")
        XCTAssertEqual(subagentParameters?["max_subagent_calls"] as? Int, 3)
        XCTAssertEqual(
            subagentParameters?["reasoning"] as? [String: String],
            ["effort": "high"]
        )
    }

    func testProviderPreferencesAreExactAndComposable() {
        XCTAssertEqual(
            ProviderPreferences.zeroDataRetention.value as NSDictionary,
            ["min_privacy": "zdr", "data_collection": "deny"] as NSDictionary
        )
        XCTAssertEqual(
            ProviderPreferences.confidential.value as NSDictionary,
            ["min_privacy": "confidential", "data_collection": "deny"] as NSDictionary
        )
        XCTAssertEqual(
            ProviderPreferences.unitedStates.value as NSDictionary,
            ["jurisdiction": "us"] as NSDictionary
        )
        let advanced = ProviderPreferences(
            usage: "credits",
            quantizations: ["fp8"],
            maxPrice: ["prompt": 1.25, "completion": 4.5]
        )
        XCTAssertEqual(advanced.value["usage"] as? String, "credits")
        XCTAssertEqual(advanced.value["quantizations"] as? [String], ["fp8"])
        XCTAssertEqual(
            advanced.value["max_price"] as? [String: Double],
            ["prompt": 1.25, "completion": 4.5]
        )
    }

    func testErrorAttributionRetainsPayload() {
        let payload: [String: Any] = ["error": [
            "message": "upstream unavailable",
            "layer": "provider",
            "source": "upstream",
            "provider": "example",
            "request_id": "req_123",
            "future_field": true,
        ]]
        let error = TrustedRouterError.generic(
            statusCode: 502,
            message: "upstream unavailable",
            payload: payload
        )
        XCTAssertEqual(error.layer, "provider")
        XCTAssertEqual(error.source, "upstream")
        XCTAssertEqual(error.provider, "example")
        XCTAssertEqual(error.requestID, "req_123")
    }
}
