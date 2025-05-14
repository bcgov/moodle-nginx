#!/usr/bin/env python3
"""
versions.py - Query current versions of deployed applications
Usage: ./versions.py [app_name]
"""

import json
import sys
from pathlib import Path

def print_version_info(app_name=None):
    with open('./versions.json') as f:
        data = json.load(f)

    if app_name:
        if app_name in data['applications']:
            info = data['applications'][app_name]
            print(f"{app_name}:")
            print(f"  Version: {info['version']}")
            print(f"  Branch: {info['branch']}")
            print(f"  Last Updated: {info['last_updated']}")
            print(f"  Deployed: {info['deployed_date']}")
        else:
            print(f"Application {app_name} not found")
    else:
        print("Deployed Applications:")
        for app, info in data['applications'].items():
            print(f"{app}: {info['version']} ({info['branch']})")

if __name__ == '__main__':
    app_name = sys.argv[1] if len(sys.argv) > 1 else None
    print_version_info(app_name)
