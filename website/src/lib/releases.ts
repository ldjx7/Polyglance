import { marked } from 'marked';

export interface ReleaseAsset {
  name: string;
  size: number;
  download_count: number;
  browser_download_url: string;
}

export interface Release {
  tag_name: string;
  name: string;
  body: string;
  body_html: string;
  published_at: string;
  html_url: string;
  prerelease: boolean;
  assets: ReleaseAsset[];
}

interface GitHubReleaseAsset {
  name: string;
  size: number;
  download_count?: number;
  browser_download_url: string;
}

interface GitHubRelease {
  tag_name: string;
  name?: string;
  body?: string;
  published_at?: string;
  html_url: string;
  prerelease: boolean;
  assets?: GitHubReleaseAsset[];
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function parseAsset(value: unknown): GitHubReleaseAsset | null {
  if (!isObject(value)) return null;
  const { name, size, download_count: downloadCount, browser_download_url: downloadUrl } = value;
  if (typeof name !== 'string' || typeof size !== 'number' || typeof downloadUrl !== 'string') {
    return null;
  }
  return {
    name,
    size,
    download_count: typeof downloadCount === 'number' ? downloadCount : 0,
    browser_download_url: downloadUrl,
  };
}

function parseRelease(value: unknown): GitHubRelease | null {
  if (!isObject(value)) return null;
  const { tag_name: tag, html_url: htmlUrl, prerelease } = value;
  if (typeof tag !== 'string' || typeof htmlUrl !== 'string' || typeof prerelease !== 'boolean') {
    return null;
  }
  return {
    tag_name: tag,
    name: typeof value.name === 'string' ? value.name : undefined,
    body: typeof value.body === 'string' ? value.body : undefined,
    published_at: typeof value.published_at === 'string' ? value.published_at : undefined,
    html_url: htmlUrl,
    prerelease,
    assets: Array.isArray(value.assets)
      ? value.assets.flatMap((asset) => parseAsset(asset) ?? [])
      : [],
  };
}

export function isInstallerAsset(name: string): boolean {
  const lower = name.toLowerCase();
  return (
    lower.endsWith('.dmg') ||
    lower.endsWith('.exe') ||
    (lower.endsWith('.zip') && !lower.includes('notarization'))
  );
}

export function getTotalDownloads(releases: Release[]): number {
  return releases.reduce((sum, r) => {
    return sum + (r.assets || []).reduce((aSum, a) => {
      if (isInstallerAsset(a.name)) {
        return aSum + (a.download_count || 0);
      }
      return aSum;
    }, 0);
  }, 0);
}

export async function getReleases(owner = 'ldjx7', repo = 'Polyglance'): Promise<Release[]> {
  try {
    const res = await fetch(`https://api.github.com/repos/${owner}/${repo}/releases?per_page=30`, {
      headers: {
        'User-Agent': 'Polyglance-Website-Builder',
        Accept: 'application/vnd.github+json',
      },
    });

    if (!res.ok) {
      console.warn(`GitHub API returned ${res.status}, falling back to local empty list`);
      return [];
    }

    const raw: unknown = await res.json();
    if (!Array.isArray(raw)) {
      console.warn('GitHub API returned an invalid release list');
      return [];
    }
    const data = raw.flatMap((release) => parseRelease(release) ?? []);
    return Promise.all(
      data.map(async (r) => ({
        tag_name: r.tag_name,
        name: r.name || r.tag_name,
        body: r.body || '',
        body_html: await marked.parse(r.body || ''),
        published_at: r.published_at ? new Date(r.published_at).toLocaleDateString('zh-CN') : '',
        html_url: r.html_url,
        prerelease: r.prerelease,
        assets: (r.assets || []).map((a) => ({
          name: a.name,
          size: a.size,
          download_count: a.download_count || 0,
          browser_download_url: a.browser_download_url,
        })),
      }))
    );
  } catch (e) {
    console.error('Failed to fetch releases:', e);
    return [];
  }
}
