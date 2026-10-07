const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

module.exports = {
    ...jestConfig,
    // Same LWC transform as the base config, with a cache key that separates instrumented (coverage) output.
    // See scripts/jest/lwc-transformer.js.
    transform: { '^.+\\.(js|ts|html|css)$': '<rootDir>/scripts/jest/lwc-transformer.js' },
    modulePathIgnorePatterns: ['<rootDir>/.localdevserver'],
    coverageThreshold: {
        global: { branches: 70, functions: 80, lines: 80, statements: 80 }
    }
};
