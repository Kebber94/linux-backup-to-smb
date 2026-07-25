#!/usr/bin/env python3

import fcntl
import json
import os
import sys
import tempfile

STATUS_FILE = os.environ.get(
    "STATUS_FILE",
    os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "data",
        "backup_status.json",
    ),
)
STATUS_DIR = os.path.dirname(STATUS_FILE)
LOCK_FILE = f"{STATUS_FILE}.lock"

# Opret mappen hvis den ikke findes
os.makedirs(STATUS_DIR, exist_ok=True)

# Brug en separat, stabil låsefil, så låsen forbliver gyldig,
# når statusfilen udskiftes atomisk.
with open(LOCK_FILE, "a", encoding="utf-8") as lock_file:
    fcntl.flock(lock_file, fcntl.LOCK_EX)

    # Læs eksisterende status hvis den findes
    try:
        with open(STATUS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}

    # Opdater de felter der er sendt ind
    for argument in sys.argv[1:]:
        if "=" not in argument:
            continue

        key, value = argument.split("=", 1)

        # Tom værdi betyder: slet feltet
        if value == "":
            data.pop(key, None)
        else:
            if value.lower() == "true":
                value = True
            elif value.lower() == "false":
                value = False
            elif value.isdigit():
                value = int(value)

            data[key] = value

    try:
        status_mode = os.stat(STATUS_FILE).st_mode & 0o7777
    except FileNotFoundError:
        current_umask = os.umask(0)
        os.umask(current_umask)
        status_mode = 0o666 & ~current_umask

    file_descriptor, temporary_file = tempfile.mkstemp(
        prefix=".backup_status.",
        suffix=".tmp",
        dir=STATUS_DIR,
        text=True,
    )

    try:
        # Gem status i samme mappe, flush og synkronisér den,
        # før den eksisterende fil udskiftes atomisk.
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as f:
            os.fchmod(f.fileno(), status_mode)
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())

        os.replace(temporary_file, STATUS_FILE)
    finally:
        if os.path.exists(temporary_file):
            os.unlink(temporary_file)
