// app/api/stream/route.ts
export const runtime = "nodejs"; // or "edge" if you want Edge runtime

export async function GET() {
  const encoder = new TextEncoder();

  const stream = new ReadableStream({
    async start(controller) {
      for (let i = 1; i <= 5; i++) {
        const chunk = `data: chunk ${i} at ${new Date().toISOString()}\n\n`;
        controller.enqueue(encoder.encode(chunk));
        await new Promise((r) => setTimeout(r, 1000));
      }
      controller.close();
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
    },
  });
}