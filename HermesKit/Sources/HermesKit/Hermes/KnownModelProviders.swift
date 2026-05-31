import Foundation

/// A provider Hermes knows how to authenticate. Used purely to surface
/// *unauthenticated* providers in the Models picker as disabled rows —
/// `GET /api/model/options` only returns authenticated providers, so without
/// this catalog the user would never see that, say, Anthropic is an option
/// they could enable with `hermes model`.
public struct KnownModelProvider: Sendable, Equatable, Identifiable {
    public let slug: String
    public let label: String

    public var id: String { slug }

    public init(slug: String, label: String) {
        self.slug = slug
        self.label = label
    }
}

public enum KnownModelProviders {
    /// Mirror of Hermes' `CANONICAL_PROVIDERS` (`hermes_cli/models.py`). The
    /// dashboard adds providers dynamically from plugins, so this list may not
    /// be exhaustive on a given host — it's a best-effort "what could I enable"
    /// catalog, not a gate. Any provider already authenticated is matched by
    /// slug against the live `/api/model/options` response and shown enabled
    /// instead.
    public static let all: [KnownModelProvider] = [
        KnownModelProvider(slug: "nous", label: "Nous Portal"),
        KnownModelProvider(slug: "openrouter", label: "OpenRouter"),
        KnownModelProvider(slug: "novita", label: "NovitaAI"),
        KnownModelProvider(slug: "lmstudio", label: "LM Studio"),
        KnownModelProvider(slug: "anthropic", label: "Anthropic"),
        KnownModelProvider(slug: "openai-codex", label: "OpenAI Codex"),
        KnownModelProvider(slug: "alibaba", label: "Qwen Cloud"),
        KnownModelProvider(slug: "xai-oauth", label: "xAI Grok OAuth"),
        KnownModelProvider(slug: "xiaomi", label: "Xiaomi MiMo"),
        KnownModelProvider(slug: "tencent-tokenhub", label: "Tencent TokenHub"),
        KnownModelProvider(slug: "nvidia", label: "NVIDIA NIM"),
        KnownModelProvider(slug: "copilot", label: "GitHub Copilot"),
        KnownModelProvider(slug: "copilot-acp", label: "GitHub Copilot ACP"),
        KnownModelProvider(slug: "huggingface", label: "Hugging Face"),
        KnownModelProvider(slug: "gemini", label: "Google AI Studio"),
        KnownModelProvider(slug: "google-gemini-cli", label: "Google Gemini (OAuth)"),
        KnownModelProvider(slug: "deepseek", label: "DeepSeek"),
        KnownModelProvider(slug: "xai", label: "xAI"),
        KnownModelProvider(slug: "zai", label: "Z.AI / GLM"),
        KnownModelProvider(slug: "kimi-coding", label: "Kimi / Kimi Coding Plan"),
        KnownModelProvider(slug: "kimi-coding-cn", label: "Kimi / Moonshot (China)"),
        KnownModelProvider(slug: "stepfun", label: "StepFun Step Plan"),
        KnownModelProvider(slug: "minimax", label: "MiniMax"),
        KnownModelProvider(slug: "minimax-oauth", label: "MiniMax (OAuth)"),
        KnownModelProvider(slug: "minimax-cn", label: "MiniMax (China)"),
        KnownModelProvider(slug: "ollama-cloud", label: "Ollama Cloud"),
        KnownModelProvider(slug: "arcee", label: "Arcee AI"),
        KnownModelProvider(slug: "gmi", label: "GMI Cloud"),
        KnownModelProvider(slug: "kilocode", label: "Kilo Code"),
        KnownModelProvider(slug: "opencode-zen", label: "OpenCode Zen"),
        KnownModelProvider(slug: "opencode-go", label: "OpenCode Go"),
        KnownModelProvider(slug: "bedrock", label: "AWS Bedrock"),
        KnownModelProvider(slug: "azure-foundry", label: "Azure Foundry"),
        KnownModelProvider(slug: "ai-gateway", label: "Vercel AI Gateway"),
        KnownModelProvider(slug: "qwen-oauth", label: "Qwen OAuth (Portal)"),
    ]

    /// The known providers not present (by slug) in the authenticated set.
    public static func unauthenticated(authenticatedSlugs: Set<String>) -> [KnownModelProvider] {
        all.filter { !authenticatedSlugs.contains($0.slug) }
    }
}
