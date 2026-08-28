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

export function getTotalDownloads(releases: Release[]): number {
  return releases.reduce((sum, r) => sum + (r.assets || []).reduce((aSum, a) => aSum + (a.download_count || 0), 0), 0);
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

    const data = await res.json();
    return Promise.all(
      data.map(async (r: any) => ({
        tag_name: r.tag_name,
        name: r.name || r.tag_name,
        body: r.body || '',
        body_html: await marked.parse(r.body || ''),
        published_at: r.published_at ? new Date(r.published_at).toLocaleDateString('zh-CN') : '',
        html_url: r.html_url,
        prerelease: r.prerelease,
        assets: (r.assets || []).map((a: any) => ({
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
