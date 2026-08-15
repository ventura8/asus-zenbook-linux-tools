import js from "@eslint/js";
import stylistic from "@stylistic/eslint-plugin";

/** ESLint flat config for GNOME Shell extension JavaScript (ESM + gi:// imports). */
export default [
    {
        ignores: [
            ".cache/**",
            ".git/**",
            ".tools/**",
            ".venv*/**",
            "node_modules/**",
            "reports/**",
        ],
    },
    js.configs.recommended,
    {
        files: ["gnome/**/*.js"],
        plugins: {
            "@stylistic": stylistic,
        },
        languageOptions: {
            ecmaVersion: 2022,
            sourceType: "module",
            globals: {
                // GNOME Shell injects this into extension scripts.
                global: "readonly",
            },
        },
        rules: {
            "@stylistic/max-len": [
                "error",
                {
                    code: 140,
                    ignoreUrls: true,
                    ignoreStrings: true,
                    ignoreTemplateLiterals: true,
                },
            ],
        },
    },
];
