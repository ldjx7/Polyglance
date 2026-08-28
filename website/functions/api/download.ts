interface Env {
  POLYGLANCE_STATS?: KVNamespace;
}

export const onRequest: PagesFunction<Env> = async (context) => {
  const url = new URL(context.request.url);
  const target = url.searchParams.get('target') || 'mac-dmg';

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
  let latestTag = 'v0.0.4-beta.11';
  let targetDownloadUrl = '';

  try {
    const ghRes = await fetch('https://api.github.com/repos/ldjx7/Polyglance/releases/latest', {
      headers: {
        'User-Agent': 'Polyglance-Cloudflare-Redirector',
        Accept: 'application/vnd.github+json',
      },
    });

    if (ghRes.ok) {
      const release = await ghRes.json();
      latestTag = release.tag_name || latestTag;
      const assets = release.assets || [];

      if (target === 'mac-dmg') {
        const a = assets.find((x: any) => x.name.endsWith('.dmg'));
        if (a) targetDownloadUrl = a.browser_download_url;
      } else if (target === 'mac-zip') {
        const a = assets.find((x: any) => x.name.includes('macOS') && x.name.endsWith('.zip'));
        if (a) targetDownloadUrl = a.browser_download_url;
      } else if (target === 'win-setup') {
        const a = assets.find((x: any) => x.name.endsWith('.exe'));
        if (a) targetDownloadUrl = a.browser_download_url;
      } else if (target === 'win-zip') {
        const a = assets.find((x: any) => x.name.includes('Windows') && x.name.endsWith('.zip'));
        if (a) targetDownloadUrl = a.browser_download_url;
      }
    }
  } catch (e) {
    console.error('Failed to fetch GitHub latest release:', e);
  }

  if (!targetDownloadUrl) {
    const rawVersion = latestTag.replace(/^v/, '');
    if (target === 'mac-dmg') {
      targetDownloadUrl = `https://github.com/ldjx7/Polyglance/releases/download/${latestTag}/Polyglance-${rawVersion}-macOS.dmg`;
    } else if (target === 'mac-zip') {
      targetDownloadUrl = `https://github.com/ldjx7/Polyglance/releases/download/${latestTag}/Polyglance-${rawVersion}-macOS.zip`;
    } else if (target === 'win-setup') {
      targetDownloadUrl = `https://github.com/ldjx7/Polyglance/releases/download/${latestTag}/Polyglance-${rawVersion}-Windows-x64-Setup.exe`;
    } else if (target === 'win-zip') {
      targetDownloadUrl = `https://github.com/ldjx7/Polyglance/releases/download/${latestTag}/Polyglance-${rawVersion}-Windows-x64-Portable.zip`;
    } else {
      targetDownloadUrl = `https://github.com/ldjx7/Polyglance/releases/latest`;
    }
  }

  return Response.redirect(targetDownloadUrl, 302);
};
