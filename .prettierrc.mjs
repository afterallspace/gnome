export default {
  semi: false,
  singleQuote: true,
  useTabs: false,
  tabWidth: 2,
  printWidth: 120,
  bracketSpacing: true,
  endOfLine: 'auto',
  overrides: [
    {
      files: ['*.json', '*.jsonc', '.prettierrc', '.eslintrc'],
      options: {
        parser: 'jsonc',
        trailingComma: 'none',
        singleQuote: false,
      },
    },
  ],
}
