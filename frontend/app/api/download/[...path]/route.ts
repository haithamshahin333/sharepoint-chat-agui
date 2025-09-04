import { NextRequest } from "next/server";

export const runtime = "nodejs"; // Ensure Node runtime for streaming

// Minimal pass-through proxy for blob/PDF downloads.
export async function GET(req: NextRequest) {
  const backendBase = (process.env.PYDANTIC_AGENT_URL || "http://localhost:8000").replace(/\/$/, "");

  // Derive the blob path from the incoming pathname (already URL-encoded)
  // /api/download/<blob_path>
  const pathname = req.nextUrl.pathname; // e.g. /api/download/container/folder/file.pdf
  const blobPath = pathname.replace(/^\/api\/download\//, "");

  // Simple traversal guard (on decoded segments)
  const traversal = blobPath.split('/').some(seg => {
    try { return decodeURIComponent(seg) === '..'; } catch { return true; }
  });
  if (traversal) {
    return new Response("Invalid path", { status: 400 });
  }

  const upstreamUrl = backendBase + pathname + req.nextUrl.search; // paths align, no rewrite

  const auth = req.headers.get("authorization");
  const correlationId = req.headers.get("x-correlation-id") || req.headers.get("x-request-id");

  const upstreamRes = await fetch(upstreamUrl, {
    headers: {
      ...(auth ? { Authorization: auth } : {}),
      ...(correlationId ? { "x-correlation-id": correlationId } : {}),
      ...(req.headers.get("if-none-match") ? { "if-none-match": req.headers.get("if-none-match")! } : {}),
      ...(req.headers.get("if-modified-since") ? { "if-modified-since": req.headers.get("if-modified-since")! } : {}),
    },
  });

  const passthroughHeaders = new Headers();
  ["content-type","content-length","content-disposition","etag","last-modified","cache-control"].forEach(h => {
    const v = upstreamRes.headers.get(h);
    if (v) passthroughHeaders.set(h, v);
  });

  return new Response(upstreamRes.body, { status: upstreamRes.status, headers: passthroughHeaders });
}
