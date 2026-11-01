# llm-provider.zig

A Zig library for communicating with LLM providers through a neutral message
model. It includes adapters for OpenAI-compatible chat completions, OpenAI's
Responses API, and Anthropic's Messages API, plus SSE parsing, retries, and a
streaming HTTP client.
