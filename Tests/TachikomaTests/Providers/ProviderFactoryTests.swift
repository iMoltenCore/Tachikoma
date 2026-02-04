import Testing
@testable import Tachikoma

@Suite("Provider Factory Tests")
struct ProviderFactoryTests {
    @Test("Wecode model uses Wecode provider")
    func wecodeProviderSelection() throws {
        let config = TestHelpers.createTestConfiguration(apiKeys: ["wecode": "test-key"], enableMockOverride: false)
        let provider = try ProviderFactory.createProvider(
            for: .wecode(.wecode),
            configuration: config
        )
        #expect(provider is WecodeProvider)
    }
}
