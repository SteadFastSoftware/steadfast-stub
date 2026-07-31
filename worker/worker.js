// steadfast-stub/worker/worker.js — the Steadfast Loader UPDATE FEED.
//
// PURPOSE: give the universal SteadfastLoader.exe a public, ungated place to
// check for and pull a newer build of ITSELF, so testers never have to be
// re-sent a fresh loader by hand. It serves ONLY the loader manifest and the
// loader binary — nothing else.
//
// WHY UNGATED (and why that is safe): the loader is the pre-license entry point
// — a person runs it BEFORE they have any token — so this feed cannot require a
// license. That is fine because it exposes NO secret and NO private asset:
//   * The private read token (GH_RELEASE_TOKEN) lives ONLY here, server-side,
//     never in the loader. Reverse-engineering the loader (PS2EXE is trivially
//     decompilable) yields only this public URL + the public verify key — nothing
//     that authenticates to anything. (D32 LICENSING-AND-SIGNING-ARE-LOCAL)
//   * The proxy is FAIL-CLOSED + asset-allowlisted: it will only ever return
//     `SteadfastLoader.exe` or `latest.json`. It cannot list the repo, walk paths,
//     or reach the token-gated PRODUCT installers (those stay behind each product
//     worker's license-token /updates gate). The loader binary is already handed
//     to every tester, so serving it here loses nothing.
//   * A per-IP rate limit + a lightweight hit counter keep the open door from
//     being abused or scraped in bulk.
//
// Accountability is unchanged: identity is captured at the LICENSE REQUEST
// (name/email/hwid) and the operator's approve/deny — never at loader download,
// which is unauthenticated today anyway.
//
// KV binding: LOADER_KV (rate-limit + hit counters).
// Secret:     GH_RELEASE_TOKEN — read-only fine-grained PAT scoped to the PRIVATE
//             steadfast-stub-releases repo. Set with `wrangler secret put`, never
//             committed.

const RELEASES_REPO = 'SteadFastSoftware/steadfast-stub-releases';
// The ONLY asset names this feed will ever serve. Fail-closed: anything else 404s.
const ASSET_RE = /^(SteadfastLoader\.exe|latest\.json)$/;
const RATE_LIMIT = { windowSec: 60, max: 30 };     // 30 loader hits / IP / minute
const CACHE_SECONDS = 300;                          // edge-cache manifest + binary briefly

function cors() {
  return {
    'Access-Control-Allow-Origin': '*',            // ungated public feed
    'Access-Control-Allow-Methods': 'GET,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Max-Age': '86400',
  };
}
function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: { 'Content-Type': 'application/json', ...cors() },
  });
}

function clientIp(request) {
  return request.headers.get('CF-Connecting-IP') || request.headers.get('X-Forwarded-For') || 'unknown';
}

// Per-IP fixed-window rate limit. Fail-open on KV error (never block a real
// tester because KV hiccuped) but still cap the common abuse case.
async function rateLimited(env, ip) {
  if (!env.LOADER_KV) return false;
  const key = 'rl:' + ip;
  try {
    const n = parseInt((await env.LOADER_KV.get(key)) || '0', 10) + 1;
    await env.LOADER_KV.put(key, String(n), { expirationTtl: RATE_LIMIT.windowSec });
    return n > RATE_LIMIT.max;
  } catch (e) { return false; }
}

// Lightweight, best-effort hit counter (accountability/observability). Never
// throws into the request path.
async function bumpHits(env, kind) {
  if (!env.LOADER_KV) return;
  try {
    const key = 'hits:' + kind + ':' + new Date().toISOString().slice(0, 10);   // per-day
    const n = parseInt((await env.LOADER_KV.get(key)) || '0', 10) + 1;
    await env.LOADER_KV.put(key, String(n), { expirationTtl: 90 * 86400 });
  } catch (e) { /* ignore */ }
}

// Find an asset by exact name across recent releases of the PRIVATE repo. Scans
// (not just /latest) so a manifest-only or a staggered publish still resolves —
// the same edition-agnostic lesson baked into the product update proxy (GAP-43).
async function findAsset(env, assetName) {
  const gh = {
    'Authorization': 'Bearer ' + env.GH_RELEASE_TOKEN,
    'User-Agent': 'steadfast-loader-feed',
    'Accept': 'application/vnd.github+json',
  };
  const r = await fetch('https://api.github.com/repos/' + RELEASES_REPO + '/releases?per_page=15', { headers: gh });
  if (!r.ok) return { error: 'upstream release lookup failed (' + r.status + ')', status: 502 };
  const rels = await r.json();
  for (const rel of (Array.isArray(rels) ? rels : [])) {
    const a = (rel.assets || []).find(x => x.name === assetName);
    if (a) return { asset: a, tag: rel.tag_name };
  }
  return { error: 'asset not found in recent releases', status: 404 };
}

async function streamAsset(env, assetName, contentType) {
  if (!env.GH_RELEASE_TOKEN) return json({ ok: false, error: 'feed not configured: GH_RELEASE_TOKEN missing' }, 503);
  const found = await findAsset(env, assetName);
  if (found.error) return json({ ok: false, error: found.error }, found.status);
  const dl = await fetch(found.asset.url, {
    headers: {
      'Authorization': 'Bearer ' + env.GH_RELEASE_TOKEN,
      'User-Agent': 'steadfast-loader-feed',
      'Accept': 'application/octet-stream',
    },
  });
  if (!dl.ok || !dl.body) return json({ ok: false, error: 'asset download failed (' + dl.status + ')' }, 502);
  return new Response(dl.body, {
    status: 200,
    headers: {
      'Content-Type': contentType,
      // GAP-9 (2026-07-30): no-store, matching the product update proxies. The old
      // 5-min edge cache meant the loader's self-update manifest and binary could be
      // served from different cache epochs during a staggered publish -> sha256
      // mismatch -> the loader silently fails to self-update. Always serve fresh.
      'Cache-Control': 'no-store',
      ...cors(),
    },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, '') || '/';

    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors() });
    if (request.method !== 'GET') return json({ ok: false, error: 'method not allowed' }, 405);

    if (path === '/' || path === '/health') {
      return json({ ok: true, service: 'steadfast-loader-feed', repo: RELEASES_REPO });
    }

    // Rate limit only the two real endpoints.
    if (path === '/loader/latest' || path.startsWith('/loader/download/')) {
      if (await rateLimited(env, clientIp(request))) {
        return json({ ok: false, error: 'rate limited - slow down' }, 429);
      }
    }

    // Manifest: { version, sha256, asset, notes? } — published alongside the exe.
    if (path === '/loader/latest') {
      await bumpHits(env, 'latest');
      return streamAsset(env, 'latest.json', 'application/json; charset=utf-8');
    }

    // Binary (asset-allowlisted, fail-closed).
    if (path.startsWith('/loader/download/')) {
      const asset = decodeURIComponent(path.slice('/loader/download/'.length));
      if (!ASSET_RE.test(asset)) return json({ ok: false, error: 'unknown asset' }, 404);
      await bumpHits(env, 'download');
      const ct = asset.endsWith('.json') ? 'application/json; charset=utf-8' : 'application/octet-stream';
      return streamAsset(env, asset, ct);
    }

    return json({ ok: false, error: 'not found' }, 404);
  },
};
