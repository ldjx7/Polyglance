import assert from 'node:assert/strict';
import test from 'node:test';

import { findDownloadUrl, parseDownloadTarget } from './download.ts';

test('accepts only the four published desktop package targets', () => {
  assert.equal(parseDownloadTarget(null), 'mac-dmg');
  assert.equal(parseDownloadTarget('mac-dmg'), 'mac-dmg');
  assert.equal(parseDownloadTarget('mac-zip'), 'mac-zip');
  assert.equal(parseDownloadTarget('win-setup'), 'win-setup');
  assert.equal(parseDownloadTarget('win-zip'), 'win-zip');
});

test('rejects arbitrary targets before they can become KV keys', () => {
  assert.equal(parseDownloadTarget('mac-dmg/../../other'), null);
  assert.equal(parseDownloadTarget('anything'), null);
  assert.equal(parseDownloadTarget(''), null);
});

test('selects only an asset that actually exists in the release', () => {
  const assets = [
    { name: 'Polyglance-0.0.4-beta.12-macOS.dmg', browser_download_url: 'https://download/mac' },
    { name: 'Polyglance-0.0.4-beta.12-Windows-x64-Portable.zip', browser_download_url: 'https://download/win' },
  ];

  assert.equal(findDownloadUrl('mac-dmg', assets), 'https://download/mac');
  assert.equal(findDownloadUrl('win-zip', assets), 'https://download/win');
  assert.equal(findDownloadUrl('win-setup', assets), null);
});
