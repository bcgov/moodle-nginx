#!/usr/bin/env python3
"""
versions.py - Manage and query version information for applications and containers
Usage:
  ./versions.py check [--local]
  ./versions.py update [--local]
  ./versions.py populate [--local]
  ./versions.py query [<app_name>]
"""

import argparse
import json
import os
from pathlib import Path

from utilities import (
    check_versions,
    update_versions,
    populate_versions,
    query_versions,
    load_versions_file,
    save_versions_file,
)

def main():
    parser = argparse.ArgumentParser(description="Manage application and container versions")
    parser.add_argument("action", choices=["check", "update", "populate", "query"], help="Action to perform")
    parser.add_argument("app_name", nargs="?", help="Application name for query")
    parser.add_argument("--local", action="store_true", help="Use local Docker images instead of remote registries")

    args = parser.parse_args()

    versions_file = Path("versions.json")
    env_file = Path("example.versions.env")

    if args.action == "check":
        updates, invalid = check_versions(env_file, versions_file, local=args.local)
        print("Updates available:", json.dumps(updates, indent=2))
        print("Invalid or deprecated:", json.dumps(invalid, indent=2))

    elif args.action == "update":
        updated = update_versions(env_file, versions_file, local=args.local)
        print("Updated versions:", json.dumps(updated, indent=2))

    elif args.action == "populate":
        populated = populate_versions(env_file, versions_file, local=args.local)
        print("Populated versions:", json.dumps(populated, indent=2))

    elif args.action == "query":
        query_versions(versions_file, args.app_name)

if __name__ == "__main__":
    main()
