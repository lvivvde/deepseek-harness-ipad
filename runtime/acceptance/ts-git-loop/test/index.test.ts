import { test } from "node:test";
import assert from "node:assert/strict";
import { slugify, wordCount } from "../src/index.ts";

test("slugify joins lower-case words with hyphens", () => {
  assert.equal(slugify("  Hello, World! "), "hello-world");
  assert.equal(slugify("Crème brûlée 2"), "creme-brulee-2");
  assert.equal(slugify("---"), "");
});

test("wordCount counts whitespace-separated words", () => {
  assert.equal(wordCount("one  two\nthree"), 3);
  assert.equal(wordCount("   "), 0);
});
