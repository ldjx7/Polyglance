interface Env {
  POLYGLANCE_STATS?: KVNamespace;
}

export const onRequest: PagesFunction<Env> = async (context) => {
  let total = 0;
  let macos = 0;
  let windows = 0;

  try {
    if (context.env.POLYGLANCE_STATS) {
      const kv = context.env.POLYGLANCE_STATS;
      const [totalStr, macStr, winStr] = await Promise.all([
        kv.get('downloads_total'),
        kv.get('downloads_macos'),
        kv.get('downloads_windows'),
      ]);

      total = parseInt(totalStr || '0', 10);
      macos = parseInt(macStr || '0', 10);
      windows = parseInt(winStr || '0', 10);
    }
  } catch (e) {
    console.error('Failed to get download stats:', e);
  }

  return new Response(
    JSON.stringify({
      total,
      macos,
      windows,
      updated_at: new Date().toISOString(),
    }),
    {
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'no-cache, no-store, must-revalidate',
      },
    }
  );
};
