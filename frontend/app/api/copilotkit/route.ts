import {
  CopilotRuntime,
  ExperimentalEmptyAdapter,
  copilotRuntimeNextJSAppRouterEndpoint,
} from "@copilotkit/runtime";
import { HttpAgent } from "@ag-ui/client";
import { NextRequest } from "next/server";
 
// 1. You can use any service adapter here for multi-agent support. We use
//    the empty adapter since we're only using one agent.
const serviceAdapter = new ExperimentalEmptyAdapter();
 
// 2. Build a Next.js API route that handles the CopilotKit runtime requests.
//    We create the runtime per request to pass through authentication headers.
//    Telemetry is disabled via COPILOTKIT_TELEMETRY_DISABLED environment variable.
export const POST = async (req: NextRequest) => {
  // Simple request log for observability
  try {
    const ua = req.headers.get("user-agent") || "";
    const xff = req.headers.get("x-forwarded-for") || "";
    console.log(`[api/copilotkit] Request received: method=${req.method}, ua="${ua}", xff="${xff}"`);
  } catch {}
  // Extract the Authorization header from the incoming request
  const authHeader = req.headers.get('Authorization');
  
  // Create a new runtime with the auth header for this request
  const authenticatedRuntime = new CopilotRuntime({
    agents: {
      "chat_agent": new HttpAgent({
        url: process.env.PYDANTIC_AGENT_URL || "http://localhost:8000/",
        headers: authHeader ? { 'Authorization': authHeader } : {},
      }),
    }   
  });

  const { handleRequest } = copilotRuntimeNextJSAppRouterEndpoint({
    runtime: authenticatedRuntime,
    serviceAdapter,
    endpoint: "/api/copilotkit",
  });

  // Intercept the streamed response to log every chunk
  const response = await handleRequest(req);
  if (!response.body) {
    // Not a streamed response, just return as is
    return response;
  }

  // Wrap the ReadableStream to log every chunk
  const loggedStream = new ReadableStream({
    start(controller) {
      if (!response.body) {
        controller.close();
        return;
      }
      const reader = response.body.getReader();
      function push() {
        reader.read().then(({ done, value }) => {
          if (done) {
            controller.close();
            return;
          }
          // Log the chunk (as string, fallback to hex if not UTF-8), with timestamp
          const ts = new Date().toISOString();
          try {
            const text = new TextDecoder("utf-8").decode(value);
            console.log(`[api/copilotkit] [${ts}] Streamed chunk:`, text);
          } catch {
            console.log(`[api/copilotkit] [${ts}] Streamed chunk (binary):`, value);
          }
          controller.enqueue(value);
          push();
        });
      }
      push();
    }
  });

  // Copy headers/status from original response
  const loggedResponse = new Response(loggedStream, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
  return loggedResponse;
};