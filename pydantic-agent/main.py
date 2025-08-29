from fastapi import FastAPI, HTTPException
import logging
import json
from starlette.requests import Request
from starlette.responses import Response
from fastapi.responses import StreamingResponse
from azure.identity import DefaultAzureCredential
from azure.storage.blob.aio import BlobServiceClient

from ag_ui.core import RunAgentInput
from pydantic_ai.ag_ui import run_ag_ui, SSE_CONTENT_TYPE
from models.request_context import RequestContext
from agents.search_agent import create_search_agent
from config import Config
import logfire

# Configure Logfire for telemetry
logfire.configure(send_to_logfire=False)
logfire.instrument_pydantic_ai()
logfire.instrument_httpx(capture_all=True)

# Use uvicorn's configured logger so messages appear in dev/server logs
logger = logging.getLogger("uvicorn.error")

# Create agent and blob service client
agent = create_search_agent()

blob_service_client = BlobServiceClient(
    account_url=f"https://{Config.AZURE_STORAGE_ACCOUNT_NAME}.blob.core.windows.net",
    credential=DefaultAzureCredential()
) if Config.AZURE_STORAGE_ACCOUNT_NAME else None

app = FastAPI()

@app.post("/")
async def root(request: Request) -> Response:
    # Log inbound request headers (with sensitive values redacted)
    headers = {k: v for k, v in request.headers.items()}
    redacted = {k: ("[REDACTED]" if k.lower() in {"authorization", "cookie"} else v) for k, v in headers.items()}
    logger.info("Inbound request headers: %s", redacted)
    
    body = await request.body()
    run_input = RunAgentInput.model_validate_json(body)
    
    # Extract forwarded_props and create per-request dependencies
    forwarded_props_data = run_input.forwarded_props if hasattr(run_input, 'forwarded_props') and run_input.forwarded_props else {}
    deps = RequestContext(forwarded_props=forwarded_props_data)
    
    accept = request.headers.get('accept', SSE_CONTENT_TYPE)
    event_stream = run_ag_ui(agent, run_input, accept=accept, deps=deps)
    
    return StreamingResponse(event_stream, media_type=accept)

@app.get("/download/{blob_path:path}")
async def download_blob(blob_path: str):
    """Proxy download a blob from Azure Storage for iframe display"""
    if not blob_service_client:
        raise HTTPException(status_code=500, detail="Storage account not configured")
    
    try:
        path_parts = blob_path.split('/', 1)
        if len(path_parts) < 2:
            raise HTTPException(status_code=400, detail="Path must include container name and blob path")
        
        container_name, blob_name = path_parts[0], path_parts[1]
        blob_client = blob_service_client.get_blob_client(container=container_name, blob=blob_name)
        
        blob_properties = await blob_client.get_blob_properties()
        content_type = blob_properties.content_settings.content_type or "application/octet-stream"
        
        stream = await blob_client.download_blob()
        
        async def generate_chunks():
            async for chunk in stream.chunks():
                yield chunk
        
        headers = {
            "Content-Type": content_type,
            "Cache-Control": "public, max-age=3600",
        }
        
        if content_type == "application/pdf":
            headers["Content-Disposition"] = "inline"
        
        return StreamingResponse(generate_chunks(), media_type=content_type, headers=headers)
        
    except Exception as e:
        raise HTTPException(status_code=404, detail=f"Blob not found: {blob_path}")