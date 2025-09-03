import {
  CopilotRuntime,
  ExperimentalEmptyAdapter,
  copilotRuntimeNextJSAppRouterEndpoint,
} from "@copilotkit/runtime";
import { HttpAgent } from "@ag-ui/client";
import { NextRequest } from "next/server";

// Ensure Node runtime for reliable streaming on App Service
export const runtime = "nodejs";
 
// 1. You can use any service adapter here for multi-agent support. We use
//    the empty adapter since we're only using one agent.
const serviceAdapter = new ExperimentalEmptyAdapter();
 
// 2. Build a Next.js API route that handles the CopilotKit runtime requests.
//    We create the runtime per request to pass through authentication headers.
//    Telemetry is disabled via COPILOTKIT_TELEMETRY_DISABLED environment variable.
export const POST = async (req: NextRequest) => {
  // Extract the Authorization and correlation headers from the incoming request
  const authHeader = req.headers.get('Authorization');
  const correlationId =
    req.headers.get('x-request-id') ||
    req.headers.get('x-correlation-id') ||
    undefined;
  
  // Create a new runtime with the auth header for this request
  const authenticatedRuntime = new CopilotRuntime({
    agents: {
    "chat_agent": new HttpAgent({
        url: process.env.PYDANTIC_AGENT_URL || "http://localhost:8000/",
        
        headers: {
          ...(authHeader ? { Authorization: authHeader } : {}),
          Accept: "text/event-stream",
          ...(correlationId ? { "x-correlation-id": correlationId } : {}),
        },

      }),
    }   
  });

  const { handleRequest } = copilotRuntimeNextJSAppRouterEndpoint({
    runtime: authenticatedRuntime, 
    serviceAdapter,
    endpoint: "/api/copilotkit",
  });
 
  return handleRequest(req);
};