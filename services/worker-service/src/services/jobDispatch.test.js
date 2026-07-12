const test = require('node:test');
const assert = require('node:assert/strict');
const { canWorkerTransition } = require('./jobLifecycle');

test('allows only sequential worker progress', () => {
  for (const [current, next] of [
    ['accepted', 'arrived'],
    ['arrived', 'started'],
    ['started', 'completed'],
  ]) {
    assert.equal(canWorkerTransition(current, next), true);
  }
});

test('rejects skipped and reversed worker transitions', () => {
  for (const [current, next] of [
    ['accepted', 'completed'],
    ['accepted', 'started'],
    ['arrived', 'completed'],
    ['completed', 'started'],
    ['cancelled', 'arrived'],
    ['offered', 'started'],
  ]) {
    assert.equal(canWorkerTransition(current, next), false);
  }
});

test('terminal jobs cannot be revived', () => {
  for (const terminal of ['completed', 'cancelled', 'expired']) {
    for (const next of ['accepted', 'arrived', 'started', 'completed']) {
      assert.equal(canWorkerTransition(terminal, next), false);
    }
  }
});
