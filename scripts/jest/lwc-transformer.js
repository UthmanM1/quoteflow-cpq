/*
 * Jest transformer for LWC: @lwc/jest-transformer plus a coverage-aware cache key.
 *
 * Why this exists: @lwc/jest-transformer (19.4.0) builds its cache key from the source, path, config, NODE_ENV and
 * compiler version, but not from Jest's `instrument` flag. When a plain `jest` run populates the transform cache first,
 * a later `jest --coverage` run reuses the uninstrumented output and reports 0% for every file, and the coverage
 * threshold in jest.config.js never fails because there is nothing to measure. Adding the flag to the key keeps
 * instrumented and plain transforms apart. Everything else is delegated to the official transformer unchanged.
 */
const lwcTransformer = require('@lwc/jest-transformer');

module.exports = {
    ...lwcTransformer,
    getCacheKey(sourceText, sourcePath, transformOptions) {
        const key = lwcTransformer.getCacheKey(sourceText, sourcePath, transformOptions);
        return transformOptions && transformOptions.instrument ? `${key}-instrumented` : key;
    }
};
