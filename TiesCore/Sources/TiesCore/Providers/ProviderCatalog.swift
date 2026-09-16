import Foundation

/// The full static catalogue of AI providers, in the app's canonical display order:
/// on-device Apple Intelligence, the three free-cloud providers, the three CLI tools,
/// the six local runners, the paid cloud providers, then `custom` last.
public enum ProviderCatalog {
    public static let all: [ProviderSpec] = [
        ProviderSpec(
            id: "apple", name: "Apple Intelligence", logo: "apple",
            transport: .appleFoundation, tier: .onDevice,
            detect: .appleIntelligence, needsAPIKey: false
        ),
        ProviderSpec(
            id: "gemini", name: "Gemini", logo: "gemini",
            transport: .openAIChat, tier: .freeCloud,
            defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            defaultModel: "gemini-2.5-flash",
            apiKeyURL: "https://aistudio.google.com/apikey"
        ),
        ProviderSpec(
            id: "groq", name: "Groq", logo: "groq",
            transport: .openAIChat, tier: .freeCloud,
            defaultBaseURL: "https://api.groq.com/openai/v1",
            defaultModel: "openai/gpt-oss-120b",
            apiKeyURL: "https://console.groq.com/keys"
        ),
        ProviderSpec(
            id: "openrouter", name: "OpenRouter", logo: "openrouter",
            transport: .openAIChat, tier: .freeCloud,
            defaultBaseURL: "https://openrouter.ai/api/v1",
            defaultModel: "openai/gpt-oss-120b:free",
            apiKeyURL: "https://openrouter.ai/keys"
        ),
        ProviderSpec(
            id: "claude-cli", name: "Claude Code", logo: "claude-cli",
            transport: .claudeCLI, tier: .cli,
            detect: .executable("claude"), needsAPIKey: false
        ),
        ProviderSpec(
            id: "codex-cli", name: "Codex CLI", logo: "codex-cli",
            transport: .codexCLI, tier: .cli,
            detect: .executable("codex"), needsAPIKey: false
        ),
        ProviderSpec(
            id: "gemini-cli", name: "Gemini CLI", logo: "gemini-cli",
            transport: .geminiCLI, tier: .cli,
            detect: .executable("gemini"), needsAPIKey: false,
            supportsJSONSchema: false
        ),
        ProviderSpec(
            id: "ollama", name: "Ollama", logo: "ollama",
            transport: .openAIChat, tier: .local,
            defaultBaseURL: "http://127.0.0.1:11434/v1",
            defaultModel: "llama3.2",
            detect: .http("http://127.0.0.1:11434/api/tags"), needsAPIKey: false
        ),
        ProviderSpec(
            id: "lmstudio", name: "LM Studio", logo: "lmstudio",
            transport: .openAIChat, tier: .local,
            defaultBaseURL: "http://localhost:1234/v1",
            detect: .http("http://localhost:1234/v1/models"), needsAPIKey: false
        ),
        ProviderSpec(
            id: "llamacpp", name: "llama.cpp", logo: "llamacpp",
            transport: .openAIChat, tier: .local,
            defaultBaseURL: "http://127.0.0.1:8080/v1",
            detect: .http("http://127.0.0.1:8080/health"), needsAPIKey: false
        ),
        ProviderSpec(
            id: "mlx", name: "MLX", logo: "mlx",
            transport: .openAIChat, tier: .local,
            defaultBaseURL: "http://127.0.0.1:8080/v1",
            detect: .executable("mlx_lm.server"), needsAPIKey: false
        ),
        ProviderSpec(
            id: "jan", name: "Jan", logo: "jan",
            transport: .openAIChat, tier: .local,
            defaultBaseURL: "http://127.0.0.1:1337/v1",
            detect: .appBundle("Jan.app"), needsAPIKey: false
        ),
        ProviderSpec(
            id: "gpt4all", name: "GPT4All", logo: "gpt4all",
            transport: .openAIChat, tier: .local,
            defaultBaseURL: "http://localhost:4891/v1",
            detect: .appBundle("gpt4all.app"), needsAPIKey: false
        ),
        ProviderSpec(
            id: "openai", name: "OpenAI", logo: "openai",
            transport: .openAIChat, tier: .paidCloud,
            defaultBaseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4.1-mini",
            apiKeyURL: "https://platform.openai.com/api-keys"
        ),
        ProviderSpec(
            id: "anthropic", name: "Anthropic", logo: "anthropic",
            transport: .anthropic, tier: .paidCloud,
            defaultBaseURL: "https://api.anthropic.com",
            defaultModel: "claude-haiku-4-5-20251001",
            apiKeyURL: "https://console.anthropic.com/settings/keys"
        ),
        ProviderSpec(
            id: "perplexity", name: "Perplexity", logo: "perplexity",
            transport: .openAIChat, tier: .paidCloud,
            defaultBaseURL: "https://api.perplexity.ai",
            defaultModel: "sonar",
            apiKeyURL: "https://www.perplexity.ai/settings/api"
        ),
        ProviderSpec(
            id: "xai", name: "xAI", logo: "xai",
            transport: .openAIChat, tier: .paidCloud,
            defaultBaseURL: "https://api.x.ai/v1",
            defaultModel: "grok-3-mini",
            apiKeyURL: "https://console.x.ai"
        ),
        ProviderSpec(
            id: "mistral", name: "Mistral", logo: "mistral",
            transport: .openAIChat, tier: .paidCloud,
            defaultBaseURL: "https://api.mistral.ai/v1",
            defaultModel: "mistral-small-latest",
            apiKeyURL: "https://console.mistral.ai/api-keys"
        ),
        ProviderSpec(
            id: "deepseek", name: "DeepSeek", logo: "deepseek",
            transport: .openAIChat, tier: .paidCloud,
            defaultBaseURL: "https://api.deepseek.com/v1",
            defaultModel: "deepseek-chat",
            apiKeyURL: "https://platform.deepseek.com/api_keys"
        ),
        ProviderSpec(
            id: "cohere", name: "Cohere", logo: "cohere",
            transport: .openAIChat, tier: .paidCloud,
            defaultBaseURL: "https://api.cohere.ai/compatibility/v1",
            defaultModel: "command-r7b-12-2024",
            apiKeyURL: "https://dashboard.cohere.com/api-keys"
        ),
        ProviderSpec(
            id: "fireworks", name: "Fireworks AI", logo: "fireworks",
            transport: .openAIChat, tier: .paidCloud,
            defaultBaseURL: "https://api.fireworks.ai/inference/v1",
            defaultModel: "accounts/fireworks/models/llama-v3p1-8b-instruct",
            apiKeyURL: "https://fireworks.ai/account/api-keys"
        ),
        ProviderSpec(
            id: "together", name: "Together AI", logo: "together",
            transport: .openAIChat, tier: .paidCloud,
            defaultBaseURL: "https://api.together.xyz/v1",
            defaultModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            apiKeyURL: "https://api.together.xyz/settings/api-keys"
        ),
        ProviderSpec(
            id: "cloudflare", name: "Cloudflare Workers AI", logo: "cloudflare",
            transport: .openAIChat, tier: .paidCloud,
            defaultBaseURL: "https://api.cloudflare.com/client/v4/accounts/{account}/ai/v1",
            defaultModel: "@cf/meta/llama-3.1-8b-instruct",
            apiKeyURL: "https://dash.cloudflare.com/profile/api-tokens"
        ),
        ProviderSpec(
            id: "huggingface", name: "Hugging Face", logo: "huggingface",
            transport: .openAIChat, tier: .paidCloud,
            defaultBaseURL: "https://router.huggingface.co/v1",
            defaultModel: "meta-llama/Llama-3.1-8B-Instruct",
            apiKeyURL: "https://huggingface.co/settings/tokens"
        ),
        ProviderSpec(
            id: "sambanova", name: "SambaNova", logo: "sambanova",
            transport: .openAIChat, tier: .paidCloud,
            defaultBaseURL: "https://api.sambanova.ai/v1",
            defaultModel: "Meta-Llama-3.1-8B-Instruct",
            apiKeyURL: "https://cloud.sambanova.ai/apis"
        ),
        ProviderSpec(
            id: "custom", name: "Custom", logo: "custom",
            transport: .openAIChat, tier: .custom,
            needsAPIKey: false
        ),
    ]

    public static func spec(_ id: String) -> ProviderSpec? {
        all.first { $0.id == id }
    }
}
