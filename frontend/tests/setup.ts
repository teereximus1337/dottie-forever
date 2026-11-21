import {afterEach} from 'vitest';
// jsdom does not implement WebKit's dialog top layer. Stub only its two
// imperative state transitions; use real DOM focus and cancel events in tests.
if (typeof HTMLDialogElement.prototype.showModal !== 'function') {
  HTMLDialogElement.prototype.showModal = function () { this.open = true; };
  HTMLDialogElement.prototype.close = function () { this.open = false; };
}

import {cleanup} from '@testing-library/react';

afterEach(() => {
  cleanup();
  delete window.webkit;
  localStorage.clear();
  history.replaceState(null, '', '/');
});
