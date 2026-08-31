interface GitHubAsset {
  name: string;
  browser_download_url: string;
}

const DOWNLOAD_TARGETS = ['mac-dmg', 'mac-zip', 'win-setup', 'win-zip'] as const;
type DownloadTarget = (typeof DOWNLOAD_TARGETS)[number];

export function parseDownloadTarget(value: string | null): DownloadTarget | null {
  if (value === null) return 'mac-dmg';
  return DOWNLOAD_TARGETS.find((target) => target === value) ?? null;
}

export function findDownloadUrl(
  target: DownloadTarget,
  assets: GitHubAsset[],
): string | null {
  const asset = assets.find(({ name }) => {
    if (target === 'mac-dmg') return name.endsWith('.dmg');
    if (target === 'mac-zip') return name.includes('macOS') && name.endsWith('.zip');
    if (target === 'win-setup') return name.endsWith('.exe');
    return name.includes('Windows') && name.endsWith('.zip');
  });
  return asset?.browser_download_url ?? null;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function githubAssets(value: unknown): GitHubAsset[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((asset) => {
    if (!isObject(asset)) return [];
    const { name, browser_download_url: downloadUrl } = asset;
    return typeof name === 'string' && typeof downloadUrl === 'string'
      ? [{ name, browser_download_url: downloadUrl }]
      : [];
  });
}

export const onRequest: PagesFunction<Env> = async (context) => {
  const url = new URL(context.request.url);
  const target = parseDownloadTarget(url.searchParams.get('target'));
  if (!target) {
    return Response.json(
      { error: 'Unknown download target' },
      { status: 400, headers: { 'Cache-Control': 'no-store' } },
    );
  }

  // 1. Asynchronously record the download in Cloudflare KV
  try {
    if (context.env.POLYGLANCE_STATS) {
      const kv = context.env.POLYGLANCE_STATS;
      
      const currentTotalStr = await kv.get('downloads_total');
      const currentTotal = parseInt(currentTotalStr || '0', 10);
      await kv.put('downloads_total', String(currentTotal + 1));

      const isMac = target.startsWith('mac');
      const groupKey = isMac ? 'downloads_macos' : 'downloads_windows';
      const groupStr = await kv.get(groupKey);
      const groupCount = parseInt(groupStr || '0', 10);
      await kv.put(groupKey, String(groupCount + 1));

      const targetKey = `downloads_target_${target}`;
      const targetStr = await kv.get(targetKey);
      const targetCount = parseInt(targetStr || '0', 10);
      await kv.put(targetKey, String(targetCount + 1));
    }
  } catch (e) {
    console.error('Failed to increment download counter:', e);
  }

  // 2. Resolve latest download link from GitHub
  let targetDownloadUrl = '';

  try {
    const ghRes = await fetch('https://api.github.com/repos/ldjx7/Polyglance/releases/latest', {
      headers: {
        'User-Agent': 'Polyglance-Cloudflare-Redirector',
        Accept: 'application/vnd.github+json',
      },
    });

    if (ghRes.ok) {
      const release: unknown = await ghRes.json();
      if (!isObject(release)) throw new Error('GitHub returned an invalid release object');
      const assets = githubAssets(release.assets);
      targetDownloadUrl = findDownloadUrl(target, assets) ?? '';
    }
  } catch (e) {
    console.error('Failed to fetch GitHub latest release:', e);
  }

  if (!targetDownloadUrl) {
    // Do not guess a versioned filename. A platform build can fail while the
    // release itself succeeds; an invented asset URL would send users to a
    // 404 (and a hard-coded fallback silently serves an old build).
    targetDownloadUrl = 'https://github.com/ldjx7/Polyglance/releases/latest';
  }

  return Response.redirect(targetDownloadUrl, 302);
};
