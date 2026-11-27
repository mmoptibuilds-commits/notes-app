# On-demand external skills

Use only the relevant upstream skill when its guidance helps an assigned task. Read its `SKILL.md` first. If local installation is needed, review its license, scripts, permissions and network use, and pin the reviewed revision. Keep external bundles outside this repository. Notes rules, approval boundaries and the zero-cost workflow still apply.

| Source | When to consult it |
|---|---|
| [Flutter team agent plugins](https://github.com/flutter/agent-plugins) | Flutter widget, layout and test guidance. Use the platform-specific advice only when it fits the native targets. |
| [Dart team skills](https://github.com/dart-lang/skills) | Dart tests, language idioms and package work. |
| [Superpowers](https://github.com/obra/superpowers/tree/main/skills) | Read `systematic-debugging` for stubborn regressions. Notes already defines worktree and handover procedures. |
| [Matt Pocock's skills](https://github.com/mattpocock/skills) | Use its debugging or TDD guidance for a complex fix, or `grill-with-docs` when the owner requests help resolving requirements. |
| [Ponytail](https://github.com/DietrichGebert/ponytail) | Review the size of an implementation. Preserve Notes data and release safeguards when simplifying. |
| [Karpathy-derived community guidelines](https://github.com/multica-ai/andrej-karpathy-skills) | Use the small-diff and verifiable-goal guidance. This is a community interpretation of Karpathy's observations. |
| [Anthropic skills](https://github.com/anthropics/skills) | Consult `skill-creator` when authoring or evaluating a reusable skill. |
| [Cloudflare skills](https://github.com/cloudflare/skills) | Consult Workers and Durable Objects guidance when changing the test Worker or its code. Keep deployment and credentials under the existing approval rules. |
| [Neon agent skills](https://github.com/neondatabase/agent-skills) | Consult SQL-over-HTTP, schema migration and connection guidance for the isolated test database. |
| [Android skills](https://github.com/android/skills) | Consult relevant native guidance for Android insets, SDK and Gradle work. Use a disposable emulator. |
| [Playwright CLI skill](https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/tools/skills/playwright-cli/SKILL.md) | Use for a browser-based test surface when one is in scope. Native Flutter QA uses Flutter tests and the emulator or Linux test app. |
