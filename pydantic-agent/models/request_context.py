"""Request context models for the Pydantic AI agent."""

from dataclasses import dataclass
from typing import Dict, Any


@dataclass
class RequestContext:
    forwarded_props: Dict[str, Any]
