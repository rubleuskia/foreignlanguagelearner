"""Environment configuration. Values are deployment inputs, never account constants."""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    table_name: str
    bucket_name: str
    state_machine_arn: str
    cluster_arn: str
    backend_tag: str
    accept_new_jobs: bool

    @classmethod
    def from_env(cls) -> "Config":
        required = ("ALIGNMENT_TABLE", "ALIGNMENT_BUCKET", "STATE_MACHINE_ARN", "ECS_CLUSTER_ARN")
        missing = [name for name in required if not os.environ.get(name)]
        if missing:
            raise RuntimeError("Missing configuration: " + ", ".join(missing))
        return cls(
            table_name=os.environ["ALIGNMENT_TABLE"],
            bucket_name=os.environ["ALIGNMENT_BUCKET"],
            state_machine_arn=os.environ["STATE_MACHINE_ARN"],
            cluster_arn=os.environ["ECS_CLUSTER_ARN"],
            backend_tag=os.environ.get("BACKEND_TAG", "alignment-v1"),
            accept_new_jobs=os.environ.get("ACCEPT_NEW_JOBS", "false").lower() == "true",
        )
